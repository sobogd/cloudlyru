/** Gemini-backed "upload a bill, get the fields" helper for expenses.
 *
 *  Used by /expenses/parse — the dashboard's expense form has a button
 *  that lets the user upload a photo / PDF of a received invoice (factura
 *  recibida). We send it to Gemini vision and return a best-effort
 *  structured parse for the form to pre-fill. The user reviews and edits
 *  every field before saving.
 *
 *  Mirrors contacts-parse.ts (native fetch, gemini-2.5-flash,
 *  GEMINI_API_KEY) but feeds the document as inlineData (image/PDF) rather
 *  than text, and extracts the SUPPLIER side (the seller), not the buyer. */

import { Logger } from "@nestjs/common";
import { env } from "../../config/env";

const logger = new Logger("ExpensesParse");

export interface ParsedExpense {
  supplierName: string;
  supplierTaxId: string;
  supplierCountryCode: string;
  issueDate: string; // YYYY-MM-DD
  currency: string; // ISO 4217
  netAmount: number; // base imponible
  vatRate: number; // 0 / 4 / 10 / 21
  irpfRate: number; // retención practicada, usually 0
  reverseCharge: boolean; // intra-EU acquisition (self-assessed VAT)
  nature: "goods" | "service"; // distinguishes 349 clave A (goods) / I (services)
  kind: "invoice" | "recurring_no_invoice"; // TGSS/RETA receipt vs real invoice
  description: string;
}

const EMPTY: ParsedExpense = {
  supplierName: "",
  supplierTaxId: "",
  supplierCountryCode: "",
  issueDate: "",
  currency: "",
  netAmount: 0,
  vatRate: 0,
  irpfRate: 0,
  reverseCharge: false,
  nature: "service",
  kind: "invoice",
  description: "",
};

const PROMPT = [
  "You extract fields from a RECEIVED invoice, bill, ticket or receipt — a purchase the user (a Spanish self-employed autónomo) paid. Return structured fields for an expense record.",
  "",
  "The document has two parties. Extract the SUPPLIER / SELLER / ISSUER (who charged the user), NOT the customer/recipient (the user themself). The supplier is usually in the header / logo / 'from' block.",
  "",
  "Output JSON matching the schema. Leave a field empty (\"\" or 0) when the value isn't present. Do NOT invent or guess.",
  "",
  "Field rules:",
  "- supplierName: the seller's company or trade name.",
  "- supplierTaxId: seller's VAT / NIF / CIF — uppercase, no spaces, with country prefix when present (\"ESB12345678\", \"DE123456789\").",
  "- supplierCountryCode: ISO 3166-1 alpha-2 of the seller (\"ES\", \"DE\", \"IE\"…). Infer from the address or the VAT prefix.",
  "- issueDate: the invoice date in YYYY-MM-DD. If only DD/MM/YYYY is shown, convert it.",
  "- currency: ISO 4217 (\"EUR\", \"USD\"). Default \"EUR\" if a € sign or no currency is shown.",
  "- netAmount: the taxable base (base imponible / subtotal BEFORE VAT). If only the gross total and a VAT rate are shown, compute the base = total / (1 + rate/100).",
  "- vatRate: the VAT/IVA percentage as a number (0, 4, 10 or 21). 0 for reverse-charge or exempt.",
  "- irpfRate: IRPF retención percentage withheld, as a number. Usually 0 — only professional-services invoices show it (7 or 15).",
  "- reverseCharge: true ONLY if this is an EU cross-border purchase with 0% VAT and a reverse-charge / 'inversión del sujeto pasivo' note. Otherwise false.",
  "- nature: \"goods\" if the purchase is physical/tangible products (materials, equipment, stock); \"service\" for anything intangible — advertising (Google/Meta Ads), cloud/hosting, SaaS, software, consulting, subscriptions. When unsure, \"service\".",
  "- kind: \"recurring_no_invoice\" ONLY for a Spanish social-security (TGSS / Seguridad Social / cuota de autónomos / RETA) receipt with no supplier VAT invoice; \"invoice\" for everything else.",
  "- description: a short line describing what was bought.",
  "",
  "Output ONLY the JSON. No prose, no markdown fences.",
].join("\n");

export async function parseExpenseFile(
  base64: string,
  mimeType: string,
): Promise<ParsedExpense> {
  const apiKey = env.GEMINI_API_KEY;
  if (!apiKey) {
    logger.warn("GEMINI_API_KEY missing — returning empty parse");
    return EMPTY;
  }

  try {
    const res = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
        },
        body: JSON.stringify({
          contents: [
            {
              role: "user",
              parts: [
                { text: PROMPT },
                { inlineData: { mimeType, data: base64 } },
              ],
            },
          ],
          generationConfig: {
            temperature: 0.1,
            // Headroom so the JSON isn't truncated on busy invoices, and no
            // "thinking" tokens draining the output budget on gemini-2.5-flash.
            maxOutputTokens: 16384,
            thinkingConfig: { thinkingBudget: 0 },
            responseMimeType: "application/json",
            responseSchema: {
              type: "object",
              properties: {
                supplierName: { type: "string" },
                supplierTaxId: { type: "string" },
                supplierCountryCode: { type: "string" },
                issueDate: { type: "string" },
                currency: { type: "string" },
                netAmount: { type: "number" },
                vatRate: { type: "number" },
                irpfRate: { type: "number" },
                reverseCharge: { type: "boolean" },
                nature: { type: "string", enum: ["goods", "service"] },
                kind: { type: "string", enum: ["invoice", "recurring_no_invoice"] },
                description: { type: "string" },
              },
              required: [
                "supplierName",
                "supplierTaxId",
                "supplierCountryCode",
                "issueDate",
                "currency",
                "netAmount",
                "vatRate",
                "irpfRate",
                "reverseCharge",
                "nature",
                "kind",
                "description",
              ],
            },
          },
        }),
      },
    );

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      logger.warn(`Gemini ${res.status}: ${body.slice(0, 200)}`);
      return EMPTY;
    }

    const data = (await res.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[];
    };
    const raw = data.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!raw) return EMPTY;
    const p = JSON.parse(raw) as Partial<ParsedExpense>;
    return {
      supplierName: str(p.supplierName),
      supplierTaxId: str(p.supplierTaxId).toUpperCase().replace(/\s+/g, ""),
      supplierCountryCode: str(p.supplierCountryCode).toUpperCase().slice(0, 2),
      issueDate: str(p.issueDate).slice(0, 10),
      currency: str(p.currency).toUpperCase().slice(0, 3),
      netAmount: round2(num(p.netAmount)),
      vatRate: num(p.vatRate),
      irpfRate: num(p.irpfRate),
      reverseCharge: p.reverseCharge === true,
      nature: p.nature === "goods" ? "goods" : "service",
      kind: p.kind === "recurring_no_invoice" ? "recurring_no_invoice" : "invoice",
      description: str(p.description),
    };
  } catch (err) {
    logger.warn(
      `parseExpenseFile fell through to empty: ${(err as Error).message}`,
    );
    return EMPTY;
  }
}

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}
function num(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}
function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}
