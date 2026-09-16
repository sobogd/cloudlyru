// PDF copy strings. Two languages now:
//
//   en  — every non-Spanish customer. The footer legal note is picked
//         separately based on legalNoteCode (art69 / reverseCharge),
//         not on the language — so the same English document can
//         carry either the non-EU art.69 boilerplate or the EU
//         intracomunitaria reverse-charge boilerplate.
//   es  — Spanish customer. IVA 21% + IRPF, fully translated.
//
// The dictionary is exhaustive — every label that ever appears on a PDF
// must live here, never as an inline string in the renderer.

export type PdfLanguage = "en" | "es";

export type LegalNoteCode = "art69" | "reverseCharge" | null;

export interface PdfStrings {
  invoice: string;
  invoiceNo: string;
  date: string;
  dueDate: string;
  sentTo: string;
  sentBy: string;
  description: string;
  qty: string;
  unitPrice: string;
  vat: string;
  net: string;
  /** Unit label printed in the Qty column when quantity is exactly 1. */
  pc: string;
  subtotal: string;
  invoiceTotal: string;
  /** Empty string in en — only Spanish invoices show the retention. */
  retention: string;
  toPay: string;
  paymentDetails: string;
  bankAccount: string;
  bankName: string;
  /** Label on the payment block — who the wire transfer is going TO.
   *  Sourced from the emitter snapshot (legal name → display name). */
  beneficiary: string;
  /** Label on the line containing the invoice number — what the
   *  recipient should type in the transfer description so the
   *  payment lands against the right invoice. Localised because
   *  "Concepto" is unreadable for a non-Spanish payer. */
  reference: string;
}

export const PDF_I18N: Record<PdfLanguage, PdfStrings> = {
  en: {
    invoice: "INVOICE",
    invoiceNo: "Invoice No",
    date: "Date",
    dueDate: "Due Date",
    sentTo: "Sent to:",
    sentBy: "Sent by:",
    description: "Description",
    qty: "Qty",
    unitPrice: "Unit Price",
    vat: "VAT",
    net: "Net",
    pc: "1 pc",
    subtotal: "Subtotal without taxes",
    invoiceTotal: "Invoice total",
    retention: "",
    toPay: "",
    paymentDetails: "Payment details:",
    bankAccount: "Bank account:",
    bankName: "Bank name",
    beneficiary: "Beneficiary",
    reference: "Reference",
  },
  es: {
    invoice: "FACTURA",
    invoiceNo: "Factura Nº",
    date: "Fecha",
    dueDate: "Fecha de vencimiento",
    sentTo: "Cliente:",
    sentBy: "Emisor:",
    description: "Descripción",
    qty: "Cant.",
    unitPrice: "Precio Unit.",
    vat: "IVA",
    net: "Neto",
    pc: "1 ud",
    subtotal: "Subtotal sin impuestos",
    invoiceTotal: "Total factura",
    retention: "Retención IRPF",
    toPay: "Total pagado",
    paymentDetails: "Datos de pago:",
    bankAccount: "Cuenta bancaria:",
    bankName: "Banco",
    beneficiary: "Beneficiario",
    reference: "Concepto",
  },
};

/** Footer legal note text, picked by `legalNoteCode` rather than by
 *  the document language. AEAT compliance notes:
 *
 *  - art69: B2B services to a non-EU recipient. Operation is "no
 *    sujeta" (out of scope) — not "exenta" (in-scope-but-exempted).
 *    The latter would put it on Modelo 303 incorrectly. No Modelo 349
 *    mention because Modelo 349 only covers EU operations.
 *  - reverseCharge: intra-EU B2B services. Place of supply is the
 *    recipient's country, so "no sujeta" under art.69 LIVA. Explicit
 *    Modelo 349 marker — issuer must report on Modelo 349
 *    recapitulativa. Art.84 LIVA is NOT cited; it governs the
 *    reverse-charge mechanic for a SPANISH recipient of foreign
 *    services — opposite direction.
 *  - null / unknown: no footer note (Spanish 21% B2B has none). */
export function legalNoteFor(
  lang: PdfLanguage,
  code: LegalNoteCode,
): string {
  if (!code) return "";
  if (lang === "es") {
    return code === "reverseCharge"
      ? "* Operación no sujeta al IVA español por aplicación del art. 69 LIVA. Prestación intracomunitaria de servicios — inversión del sujeto pasivo (Art. 196 Directiva 2006/112/CE) — Modelo 349."
      : "* Operación no sujeta al IVA español (art. 69 LIVA) — servicios prestados a una empresa fuera de la UE, fuera del ámbito territorial del Impuesto.";
  }
  return code === "reverseCharge"
    ? "* Reverse charge — VAT to be accounted for by the recipient (Art. 196 Directive 2006/112/EC). Operación no sujeta al IVA español por aplicación del art. 69 LIVA. Prestación intracomunitaria de servicios — Modelo 349."
    : "* Out-of-scope of Spanish VAT pursuant to art. 69 LIVA (services rendered to a business outside the EU). Operación no sujeta al IVA español — fuera del ámbito territorial del Impuesto.";
}
