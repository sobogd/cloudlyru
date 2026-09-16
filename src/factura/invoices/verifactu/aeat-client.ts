import https from "node:https";
import { DOMParser, type Document, type Element } from "@xmldom/xmldom";

import type { VerifactuCert } from "./cert-reader";
import type { VerifactuEnv } from "./qr-url";

/** AEAT VeriFactu SOAP endpoints. The two hosts (www1/www10 and
 *  prewww1/prewww10) are load-balanced equivalents — we pick one
 *  arbitrarily per env. */
const ENDPOINTS: Record<VerifactuEnv, string> = {
  sandbox: "https://prewww1.aeat.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP",
  production: "https://www1.agenciatributaria.gob.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP",
};

const NS_SF =
  "https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd";
const NS_SFR =
  "https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/RespuestaSuministro.xsd";

/** AEAT's overall verdict on a batch. Mirrors EstadoEnvioType in
 *  RespuestaSuministro.xsd. */
export type EstadoEnvio =
  | "Correcto"
  | "ParcialmenteCorrecto"
  | "Incorrecto";

/** AEAT's verdict on a single record. Mirrors EstadoRegistroType. */
export type EstadoRegistro =
  | "Correcto"
  | "AceptadoConErrores"
  | "Incorrecto";

export interface AeatLineResult {
  /** Echo of the invoice serial from the request — use this to match
   *  back to the VerifactuRegistry row. */
  numSerieFactura: string;
  fechaExpedicionFactura: string;
  estado: EstadoRegistro;
  /** AEAT's numeric error code (e.g. 1115 = NIF emisor no existe). */
  codigoError: number | null;
  /** Human-readable error description in Spanish. */
  descripcionError: string | null;
}

export interface AeatSubmitResult {
  /** AEAT receipt id ("Código Seguro de Verificación"). Set only when
   *  the batch is at least partially accepted. */
  csv: string | null;
  estadoEnvio: EstadoEnvio;
  /** Per-record results, in the same order as our request. */
  lineas: AeatLineResult[];
  /** Raw response XML — persisted for forensic / audit purposes when
   *  AEAT rejects something with a code we don't yet recognise. */
  rawResponseXml: string;
  httpStatus: number;
}

export interface AeatSubmitError {
  /** When AEAT returns a SOAP Fault (XML schema rejection, etc.) we
   *  bubble it up as an error so the cron can retry / mark FAILED. */
  kind: "soap_fault" | "http_error" | "network_error" | "parse_error";
  message: string;
  httpStatus?: number;
  rawResponseXml?: string;
}

/** POST a SOAP envelope to AEAT with mutual-TLS authentication and
 *  parse the response into a structured result.
 *
 *  Connection details:
 *   • mTLS via the tenant's FNMT cert (decrypted in cert-reader).
 *   • TLS 1.2+ enforced by the Node default (AEAT's frontend rejects
 *     SSLv3 / weak ciphers).
 *   • 30s socket timeout — AEAT publishes a TiempoEsperaEnvio field in
 *     the response which we mostly ignore today (it's a hint about
 *     how long to wait before the next batch when rate-limited).
 *
 *  This function does NOT retry on its own. The cron caller decides
 *  whether to retry based on the error kind. */
export async function submitToAeat(
  env: VerifactuEnv,
  soapEnvelope: string,
  /** Per-tenant signing material. Required — the env-cert fallback was
   *  removed once the upload flow shipped; every submit now signs with
   *  the obligado tributario's own FNMT cert. */
  cert: VerifactuCert,
): Promise<AeatSubmitResult> {
  const url = ENDPOINTS[env];

  const { hostname, pathname } = new URL(url);
  const body = Buffer.from(soapEnvelope, "utf-8");

  // Use the PEM-extracted key+cert rather than the raw .p12. Node 20's
  // OpenSSL 3 refuses the legacy RC2-40-CBC cipher that FNMT uses to
  // encrypt its .p12, so `https.Agent({ pfx })` throws
  // `Unsupported PKCS12 PFX data`. node-forge decrypts it in pure JS
  // (legacy-cipher safe) and we feed Node the resulting PEMs.
  const agent = new https.Agent({
    key: cert.privateKeyPem,
    cert: cert.certificatePem,
    keepAlive: false,
    minVersion: "TLSv1.2",
  });

  const { statusCode, body: respBody } = await postSoap({
    hostname,
    path: pathname,
    body,
    agent,
  });
  const rawResponseXml = respBody.toString("utf-8");

  if (statusCode < 200 || statusCode >= 300) {
    // Even on HTTP 500 AEAT often returns a SOAP Fault with a useful
    // error code — try to parse anyway, but fall back to a generic
    // error if parsing fails.
    const parsed = tryParse(rawResponseXml);
    if (parsed) {
      return { ...parsed, httpStatus: statusCode, rawResponseXml };
    }
    throw {
      kind: "http_error",
      message: `AEAT returned HTTP ${statusCode}`,
      httpStatus: statusCode,
      rawResponseXml,
    } satisfies AeatSubmitError;
  }

  const parsed = tryParse(rawResponseXml);
  if (!parsed) {
    throw {
      kind: "parse_error",
      message: "Could not parse AEAT response",
      httpStatus: statusCode,
      rawResponseXml,
    } satisfies AeatSubmitError;
  }
  return { ...parsed, httpStatus: statusCode, rawResponseXml };
}

function postSoap(args: {
  hostname: string;
  path: string;
  body: Buffer;
  agent: https.Agent;
}): Promise<{ statusCode: number; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: args.hostname,
        port: 443,
        path: args.path,
        method: "POST",
        agent: args.agent,
        headers: {
          "Content-Type": "text/xml; charset=utf-8",
          // AEAT's WSDL uses an empty SOAPAction. Some toolchains send
          // the operation URI; we mirror the WSDL.
          SOAPAction: '""',
          "Content-Length": args.body.length.toString(),
          "User-Agent": "iq-factura/1.0 (+verifactu)",
        },
        timeout: 30_000,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () =>
          resolve({
            statusCode: res.statusCode ?? 0,
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on("timeout", () => {
      req.destroy(
        Object.assign(new Error("AEAT request timed out after 30s"), {
          kind: "network_error",
        }),
      );
    });
    req.on("error", (err) => {
      reject({
        kind: "network_error",
        message: err.message,
      } satisfies AeatSubmitError);
    });
    req.write(args.body);
    req.end();
  });
}

/** Parse a SOAP response into our flat result shape. Returns null if
 *  the document isn't recognisable as a VeriFactu response — caller
 *  surfaces that as a parse_error. */
function tryParse(
  xml: string,
):
  | Omit<AeatSubmitResult, "httpStatus" | "rawResponseXml">
  | null {
  let doc: Document;
  try {
    // v0.9 dropped the per-level handler in favour of a single function.
    // Silence everything — AEAT XML is always well-formed and any
    // warning would just be noise in the cron log.
    doc = new DOMParser({ onError: () => undefined }).parseFromString(
      xml,
      "text/xml",
    );
  } catch {
    return null;
  }
  if (!doc) return null;

  // Look for either RespuestaRegFactuSistemaFacturacion (the happy
  // path) or a soap:Fault (error path).
  const respuesta = firstByLocalName(doc, "RespuestaRegFactuSistemaFacturacion");
  if (!respuesta) {
    // Could be a SOAP fault — render its message rather than null so
    // the caller's error log is useful.
    const faultString = firstText(doc, "faultstring") ?? firstText(doc, "Reason");
    if (faultString) {
      throw {
        kind: "soap_fault",
        message: faultString,
        rawResponseXml: xml,
      } satisfies AeatSubmitError;
    }
    return null;
  }

  const csv = firstTextNs(respuesta, NS_SFR, "CSV") ?? null;
  const estadoEnvio = (firstTextNs(respuesta, NS_SFR, "EstadoEnvio") ?? "Incorrecto") as EstadoEnvio;

  const lineas: AeatLineResult[] = [];
  const lineNodes = allByLocalName(respuesta, "RespuestaLinea");
  for (const ln of lineNodes) {
    const id = firstByLocalName(ln, "IDFactura");
    const numSerie = (id && firstTextNs(id, NS_SF, "NumSerieFactura")) ?? "";
    const fecha = (id && firstTextNs(id, NS_SF, "FechaExpedicionFactura")) ?? "";
    const estado =
      (firstTextNs(ln, NS_SFR, "EstadoRegistro") as EstadoRegistro | null) ??
      "Incorrecto";
    const codigoStr = firstTextNs(ln, NS_SFR, "CodigoErrorRegistro");
    const desc = firstTextNs(ln, NS_SFR, "DescripcionErrorRegistro");
    lineas.push({
      numSerieFactura: numSerie,
      fechaExpedicionFactura: fecha,
      estado,
      codigoError: codigoStr ? Number(codigoStr) : null,
      descripcionError: desc ?? null,
    });
  }

  return { csv, estadoEnvio, lineas };
}

function firstByLocalName(
  root: Document | Element,
  local: string,
): Element | null {
  const docOrRoot =
    "documentElement" in root
      ? root.documentElement
      : (root as unknown as Element);
  if (!docOrRoot) return null;
  return findByLocal(docOrRoot, local);
}

function findByLocal(node: Element, local: string): Element | null {
  if (node.localName === local) return node;
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i];
    if (c.nodeType === 1) {
      const found = findByLocal(c as Element, local);
      if (found) return found;
    }
  }
  return null;
}

function allByLocalName(root: Element, local: string): Element[] {
  const out: Element[] = [];
  walk(root, (n) => {
    if (n.localName === local) out.push(n);
  });
  return out;
}

function walk(node: Element, visit: (n: Element) => void): void {
  visit(node);
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i];
    if (c.nodeType === 1) walk(c as Element, visit);
  }
}

function firstText(doc: Document, local: string): string | null {
  const el = firstByLocalName(doc, local);
  return el?.textContent?.trim() || null;
}

function firstTextNs(
  root: Document | Element,
  ns: string,
  local: string,
): string | null {
  const docOrRoot =
    "documentElement" in root
      ? root.documentElement
      : (root as unknown as Element);
  if (!docOrRoot) return null;
  return findTextNs(docOrRoot, ns, local);
}

function findTextNs(
  node: Element,
  ns: string,
  local: string,
): string | null {
  if (node.localName === local && node.namespaceURI === ns) {
    return node.textContent?.trim() || null;
  }
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i];
    if (c.nodeType === 1) {
      const found = findTextNs(c as Element, ns, local);
      if (found != null) return found;
    }
  }
  return null;
}
