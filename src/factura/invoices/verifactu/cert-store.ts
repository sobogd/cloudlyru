/** Encrypts FNMT signing material with AES-256-GCM and stores the
 *  ciphertext in the Company row. The user's .p12 password is
 *  consumed once at upload time (used to decrypt the PKCS#12
 *  container into PEMs) and then thrown away — the master key alone
 *  is enough to recover the PEMs at submit time.
 *
 *  Why GCM: it's the AEAD cipher Node ships out of the box, the
 *  auth tag detects tampering, and the 12-byte nonce is small
 *  enough to live next to the ciphertext without bloat. Rotating
 *  the master key is a future concern; today we trust that the env
 *  is only readable by the deployer user. */

import crypto from "node:crypto";
import forge from "node-forge";
import { env } from "../../../config/env";

const ALG = "aes-256-gcm";
const NONCE_LEN = 12;

export interface ParsedCert {
  /** Combined PEM blob: private key first, then signer cert, then
   *  intermediates if any. Submit-time https.Agent splits it back
   *  via `key:` + `cert:` when feeding TLS. */
  pemBlob: string;
  /** NIF as written in the cert's subject DN (FNMT puts it in
   *  serialNumber as "IDCES-XXXXXXXXX" — we strip the prefix). */
  nif: string;
  subject: string;
  issuer: string;
  /** notAfter from the X.509 cert. */
  expiry: Date;
}

export interface EncryptedCert {
  cipher: Buffer;
  nonce: Buffer;
  tag: Buffer;
  nif: string;
  subject: string;
  issuer: string;
  expiry: Date;
}

function masterKey(): Buffer {
  const raw = env.VERIFACTU_MASTER_KEY;
  if (!raw) {
    throw new Error(
      "VERIFACTU_MASTER_KEY is not set — cannot encrypt or decrypt tenant signing certs",
    );
  }
  const buf = Buffer.from(raw.trim(), "base64");
  if (buf.length !== 32) {
    throw new Error(
      `VERIFACTU_MASTER_KEY must be 32 bytes base64 (256 bits) — got ${buf.length}`,
    );
  }
  return buf;
}

/** Open a .p12 with the user's password and pull out everything we
 *  need to submit Verifactu. Throws on a wrong password (forge raises
 *  a descriptive error), missing key material, or expired cert. */
export function parseP12(pfx: Buffer, password: string): ParsedCert {
  const der = pfx.toString("binary");
  const asn1 = forge.asn1.fromDer(der);
  const p12 = forge.pkcs12.pkcs12FromAsn1(asn1, password);

  const shrouded =
    p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[
      forge.pki.oids.pkcs8ShroudedKeyBag
    ] ?? [];
  const plain =
    p12.getBags({ bagType: forge.pki.oids.keyBag })[forge.pki.oids.keyBag] ??
    [];
  const keyBag = shrouded[0] ?? plain[0];
  if (!keyBag?.key) {
    throw new Error("The .p12 file does not contain a private key");
  }
  const privateKeyPem = forge.pki.privateKeyToPem(keyBag.key);

  const certBags =
    p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] ??
    [];
  const certs = certBags
    .map((b) => b.cert)
    .filter((c): c is forge.pki.Certificate => !!c);
  if (certs.length === 0) {
    throw new Error("The .p12 file does not contain any certificates");
  }

  const rsaKey = keyBag.key as forge.pki.rsa.PrivateKey;
  let signer = certs[0];
  if (rsaKey.n) {
    const keyN = rsaKey.n.toString(16);
    const match = certs.find((c) => {
      const pub = c.publicKey as forge.pki.rsa.PublicKey;
      return pub.n && pub.n.toString(16) === keyN;
    });
    if (match) signer = match;
  }

  const subject = nameToRfc2253(signer.subject.attributes);
  const issuer = nameToRfc2253(signer.issuer.attributes);
  const nif = extractNif(signer.subject.attributes);
  if (!nif) {
    throw new Error(
      "Could not read the NIF from the certificate subject (expected an FNMT serialNumber of the form IDCES-...)",
    );
  }
  const expiry = signer.validity.notAfter;
  if (expiry.getTime() < Date.now()) {
    throw new Error(
      `The certificate expired on ${expiry.toISOString().slice(0, 10)}`,
    );
  }

  const otherCertsPem = certs
    .filter((c) => c !== signer)
    .map((c) => forge.pki.certificateToPem(c));
  const signerCertPem = forge.pki.certificateToPem(signer);
  const pemBlob = [privateKeyPem, signerCertPem, ...otherCertsPem].join("\n");

  return { pemBlob, nif, subject, issuer, expiry };
}

export function encryptPem(pemBlob: string): EncryptedCert {
  const key = masterKey();
  const nonce = crypto.randomBytes(NONCE_LEN);
  const cipher = crypto.createCipheriv(ALG, key, nonce);
  const enc = Buffer.concat([
    cipher.update(pemBlob, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return {
    cipher: enc,
    nonce,
    tag,
    // Defaults — caller fills NIF/subject/issuer/expiry from the parsed
    // cert when it has them. We export this combined helper as a
    // convenience for the upload path; submit path uses decryptPem
    // alone.
    nif: "",
    subject: "",
    issuer: "",
    expiry: new Date(0),
  };
}

export function decryptPem(
  cipherBuf: Buffer,
  nonceBuf: Buffer,
  tagBuf: Buffer,
): string {
  const key = masterKey();
  const decipher = crypto.createDecipheriv(ALG, key, nonceBuf);
  decipher.setAuthTag(tagBuf);
  const plain = Buffer.concat([decipher.update(cipherBuf), decipher.final()]);
  return plain.toString("utf8");
}

/** Convenience: parse + encrypt in one shot. The DB row gets the
 *  resulting fields plus the NIF/subject/issuer/expiry from
 *  parseP12. */
export function parseAndEncrypt(
  pfx: Buffer,
  password: string,
): EncryptedCert {
  const parsed = parseP12(pfx, password);
  const enc = encryptPem(parsed.pemBlob);
  return {
    ...enc,
    nif: parsed.nif,
    subject: parsed.subject,
    issuer: parsed.issuer,
    expiry: parsed.expiry,
  };
}

function nameToRfc2253(attrs: forge.pki.CertificateField[]): string {
  return attrs
    .map((a) => {
      const k = (a.shortName ?? a.name ?? "").toUpperCase();
      const v = typeof a.value === "string" ? a.value : "";
      return `${k}=${v.replace(/([,+"\\<>;=])/g, "\\$1")}`;
    })
    .join(",");
}

/** FNMT puts the NIF inside the subject `serialNumber` attribute as
 *  "IDCES-XXXXXXXXX". Some issuance years instead populate it inside
 *  the CN ("SOKOLOV BOGDAN - Z1894474S"). Try both. */
function extractNif(attrs: forge.pki.CertificateField[]): string | null {
  for (const a of attrs) {
    const key = (a.shortName ?? a.name ?? "").toLowerCase();
    const val = typeof a.value === "string" ? a.value : "";
    if (key === "serialnumber") {
      const m = val.match(/IDCES-([A-Z0-9]+)/i);
      if (m) return m[1].toUpperCase();
      // Some implementations strip the prefix.
      if (/^[A-Z0-9]{9}$/i.test(val)) return val.toUpperCase();
    }
  }
  // Fallback: trailing token after a dash in CN.
  for (const a of attrs) {
    const key = (a.shortName ?? a.name ?? "").toLowerCase();
    const val = typeof a.value === "string" ? a.value : "";
    if (key === "cn") {
      const m = val.match(/([A-Z0-9]{9})\s*$/i);
      if (m) return m[1].toUpperCase();
    }
  }
  return null;
}
