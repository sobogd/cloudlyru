import { createHash } from "node:crypto";
import forge from "node-forge";

import { decryptPem } from "./cert-store";

/** Loaded Verifactu signing material — PEM strings ready to feed into
 *  XAdES signer (privateKey) and the AEAT mTLS HTTPS agent. */
export interface VerifactuCert {
  /** Signer private key in PEM (PKCS#8). */
  privateKeyPem: string;
  /** Signer (end-entity) X.509 cert in PEM. */
  certificatePem: string;
  /** Full chain — signer first, then intermediates / root. PEM each. */
  chainPems: string[];
  /** SHA-256 of the DER-encoded signer cert. Used as the
   *  CertDigest inside XAdES <SigningCertificateV2>. Base64. */
  certificateSha256Base64: string;
  /** Issuer DN as a single RFC 2253 string — XAdES IssuerSerialV2 needs it. */
  issuerName: string;
  /** Hex serial number (uppercase, no leading zeros) — also for IssuerSerialV2. */
  serialNumberHex: string;
}

const tenantCache = new Map<string, VerifactuCert>();

/** Build a `VerifactuCert` directly from PEM signer material — used by
 *  the per-tenant DB path where the cert has already been unwrapped
 *  + decrypted via the master key. Re-derives the cert hash + DN
 *  metadata so downstream code (e.g. XAdES SigningCertificateV2)
 *  works the same way it would for an env-loaded cert. */
export function buildVerifactuCertFromPem(pemBlob: string): VerifactuCert {
  const blocks = pemBlob.match(/-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/g) ?? [];
  const keyPem = blocks.find((b) => /BEGIN ([A-Z]+ )?PRIVATE KEY/.test(b));
  const certPems = blocks.filter((b) => /BEGIN CERTIFICATE/.test(b));
  if (!keyPem || certPems.length === 0) {
    throw new Error("PEM blob is missing key or cert material");
  }
  const certs = certPems.map((p) => forge.pki.certificateFromPem(p));
  // The key blob is RSA, so we can pick the matching cert by modulus.
  const keyForge = forge.pki.privateKeyFromPem(keyPem) as forge.pki.rsa.PrivateKey;
  const keyN = keyForge.n ? keyForge.n.toString(16) : "";
  const signer =
    certs.find((c) => {
      const pub = c.publicKey as forge.pki.rsa.PublicKey;
      return pub.n && pub.n.toString(16) === keyN;
    }) ?? certs[0];
  const certDer = forge.asn1.toDer(forge.pki.certificateToAsn1(signer)).getBytes();
  const certificateSha256Base64 = createHash("sha256")
    .update(Buffer.from(certDer, "binary"))
    .digest("base64");
  const ordered = orderChain(signer, certs);
  return {
    privateKeyPem: keyPem,
    certificatePem: forge.pki.certificateToPem(signer),
    chainPems: ordered.map((c) => forge.pki.certificateToPem(c)),
    certificateSha256Base64,
    issuerName: forgeNameToRfc2253(signer.issuer.attributes),
    serialNumberHex: signer.serialNumber.toUpperCase(),
  };
}

/** Per-tenant cert load. Reads the encrypted blob off the Company row,
 *  decrypts with the service master key, returns the standard
 *  VerifactuCert shape. Cached by companyId for the process lifetime
 *  — the cert only changes when the user uploads a new one, at which
 *  point cache miss on the next id is fine. */
export function loadVerifactuCertForCompany(args: {
  companyId: string;
  cipher: Buffer;
  nonce: Buffer;
  tag: Buffer;
}): VerifactuCert {
  const hit = tenantCache.get(args.companyId);
  if (hit) return hit;
  const pem = decryptPem(args.cipher, args.nonce, args.tag);
  const cert = buildVerifactuCertFromPem(pem);
  tenantCache.set(args.companyId, cert);
  return cert;
}

/** Drop a tenant from the cache (called when they upload a new cert
 *  or delete the existing one). */
export function evictTenantCertCache(companyId: string): void {
  tenantCache.delete(companyId);
}

/** Build the issuance chain starting with the signer, walking each
 *  cert's issuer DN until we hit a self-signed root or run out. Order
 *  matters for some XAdES validators — signer first, intermediates,
 *  root last. */
function orderChain(
  signer: forge.pki.Certificate,
  pool: forge.pki.Certificate[],
): forge.pki.Certificate[] {
  const chain: forge.pki.Certificate[] = [signer];
  const used = new Set([signer]);
  let current = signer;
  while (true) {
    const issuerDn = forgeNameToRfc2253(current.issuer.attributes);
    const next = pool.find(
      (c) =>
        !used.has(c) && forgeNameToRfc2253(c.subject.attributes) === issuerDn,
    );
    if (!next) break;
    chain.push(next);
    used.add(next);
    if (
      forgeNameToRfc2253(next.subject.attributes) ===
      forgeNameToRfc2253(next.issuer.attributes)
    ) {
      // self-signed root, stop
      break;
    }
    current = next;
  }
  return chain;
}

/** Render a forge cert name as an RFC 2253 distinguished-name string.
 *  AEAT's XAdES validator accepts the standard `CN=…,O=…,C=ES` form. */
function forgeNameToRfc2253(attrs: forge.pki.CertificateField[]): string {
  return attrs
    .map((a) => {
      const key = (a.shortName ?? a.name ?? "").toUpperCase();
      const raw = typeof a.value === "string" ? a.value : "";
      return `${key}=${escapeRfc2253(raw)}`;
    })
    .join(",");
}

function escapeRfc2253(v: string): string {
  return v.replace(/([,+"\\<>;=])/g, "\\$1");
}
