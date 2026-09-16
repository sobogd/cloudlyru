import crypto from "node:crypto";

/** Inputs to the per-invoice Verifactu hash, in the exact AEAT order.
 *  Order MUST match the spec (RD 1007/2023 Anexo, "Huella o hash" §) —
 *  changing it would invalidate the chain for every subsequent invoice
 *  even if the algorithm is unchanged. */
export interface HashInputFields {
  /** Emitter NIF (issuer's tax id). e.g. "Z1894474S". */
  idEmisorFactura: string;
  /** Invoice serial+number. e.g. "FACT-2026-00007". */
  numSerieFactura: string;
  /** Invoice issue date as DD-MM-YYYY (AEAT format, NOT ISO). */
  fechaExpedicionFactura: string;
  /** AEAT invoice type code. We only emit F1 (factura completa). */
  tipoFactura: string;
  /** Sum of VAT amounts on the invoice, two-decimal string. */
  cuotaTotal: string;
  /** Invoice total (net + VAT), two-decimal string. */
  importeTotal: string;
  /** Previous registry row's `currentHash`. Empty string for the chain
   *  seed (the very first invoice the company ever issues under Verifactu). */
  huella: string;
  /** ISO-8601 timestamp with timezone (e.g. "2026-05-29T12:50:04+02:00")
   *  at which the registry row was generated. NOT the invoice issue date
   *  — this one is per-record, not per-invoice. */
  fechaHoraHusoGenRegistro: string;
}

/** Canonical key-value serialisation used as the SHA-256 input. AEAT pins
 *  the exact form: ampersand-separated, equals-paired, no URL-encoding,
 *  fields in the published order. */
export function canonicaliseHashInput(f: HashInputFields): string {
  return (
    `IDEmisorFactura=${f.idEmisorFactura}` +
    `&NumSerieFactura=${f.numSerieFactura}` +
    `&FechaExpedicionFactura=${f.fechaExpedicionFactura}` +
    `&TipoFactura=${f.tipoFactura}` +
    `&CuotaTotal=${f.cuotaTotal}` +
    `&ImporteTotal=${f.importeTotal}` +
    `&Huella=${f.huella}` +
    `&FechaHoraHusoGenRegistro=${f.fechaHoraHusoGenRegistro}`
  );
}

/** Decide the AEAT invoice type from what we know about the customer.
 *  A customer with no tax id is an unidentified consumer → F2 (factura
 *  simplificada, which omits the Destinatario block). Otherwise F1
 *  (factura completa).
 *
 *  This MUST be computed identically everywhere the invoice is
 *  materialised: TipoFactura feeds BOTH the Huella (canonicaliseHashInput
 *  above) AND the XML Destinatario decision. If the hash is built with one
 *  type and the XML with another, AEAT rejects the record (huella
 *  mismatch) and the chain forks. Single source of truth on purpose. */
export function deriveTipoFactura(contactSnapshot: unknown): "F1" | "F2" {
  const c = (contactSnapshot ?? {}) as { taxId?: string | null };
  return (c.taxId || "").trim() ? "F1" : "F2";
}

/** SHA-256, hex-encoded UPPER CASE. AEAT wants uppercase in both the
 *  XML payload and any QR validation reference. */
export function sha256Hex(input: string): string {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex").toUpperCase();
}

/** Convenience: build the canonical string and hash it. */
export function computeHuella(f: HashInputFields): {
  input: string;
  hash: string;
} {
  const input = canonicaliseHashInput(f);
  return { input, hash: sha256Hex(input) };
}

/** Format the per-invoice date in DD-MM-YYYY (the format the hash input
 *  expects). The Invoice schema stores `issueDate` as `@db.Date` so we
 *  treat the Date object as UTC midnight of the issue day and emit the
 *  three components without timezone conversion. */
export function formatDateForHash(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${day}-${m}-${y}`;
}

/** Format the per-record generation timestamp in the AEAT-specific
 *  ISO-8601 variant: seconds precision, explicit offset (no Z). */
export function formatTimestampForHash(d: Date, tzOffsetMinutes?: number): string {
  // We default to Spain peninsular time (UTC+1 winter, UTC+2 summer)
  // since iq-factura is a Spain-targeted product. The caller can pass
  // a specific offset if a future multi-region deployment needs it.
  const offset = tzOffsetMinutes ?? defaultSpainTzOffsetMinutes(d);
  const local = new Date(d.getTime() + offset * 60_000);
  const y = local.getUTCFullYear();
  const mo = String(local.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(local.getUTCDate()).padStart(2, "0");
  const hh = String(local.getUTCHours()).padStart(2, "0");
  const mm = String(local.getUTCMinutes()).padStart(2, "0");
  const ss = String(local.getUTCSeconds()).padStart(2, "0");
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  const oh = String(Math.floor(abs / 60)).padStart(2, "0");
  const om = String(abs % 60).padStart(2, "0");
  return `${y}-${mo}-${dd}T${hh}:${mm}:${ss}${sign}${oh}:${om}`;
}

/** Quick-and-dirty DST detector for Europe/Madrid: between the last
 *  Sunday of March and the last Sunday of October, the offset is +2;
 *  otherwise +1. Good enough for invoice records — we never need
 *  sub-minute precision and the exact transition moment matters only
 *  for invoices issued during the 1-hour spring-forward window, which
 *  is vanishingly rare in B2B. */
function defaultSpainTzOffsetMinutes(d: Date): number {
  const y = d.getUTCFullYear();
  const lastSundayOfMarch = lastSundayUtc(y, 2);
  const lastSundayOfOctober = lastSundayUtc(y, 9);
  const t = d.getTime();
  const inDst =
    t >= lastSundayOfMarch.setUTCHours(1, 0, 0, 0) &&
    t < lastSundayOfOctober.setUTCHours(1, 0, 0, 0);
  return inDst ? 120 : 60;
}

function lastSundayUtc(year: number, monthIndex: number): Date {
  const d = new Date(Date.UTC(year, monthIndex + 1, 0));
  d.setUTCDate(d.getUTCDate() - d.getUTCDay());
  return d;
}

/** Format a Decimal-shaped value (number, string, or Prisma Decimal)
 *  as a two-decimal "." string. The AEAT hash spec is locale-agnostic
 *  here: dot separator, two decimals, no thousand separator. */
export function formatAmountForHash(v: number | string | { toString(): string }): string {
  const n = typeof v === "number" ? v : Number(v.toString());
  if (!Number.isFinite(n)) return "0.00";
  return n.toFixed(2);
}
