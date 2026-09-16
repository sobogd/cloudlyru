/** Gemini-backed "paste anything, get structured fields" helper.
 *
 *  Used by /contacts/parse — the dashboard's recipient form has a
 *  button that opens a textarea, the user dumps whatever they have
 *  (email signature, business card OCR, hand-typed notes), and we
 *  return a best-effort structured parse for the form to pre-fill.
 *  The user can still edit every field after.
 *
 *  This is purely an input convenience — the contact itself stores
 *  the exact strings the user kept after the parse. No Gemini call
 *  happens during invoice issuance. */

import { Logger } from "@nestjs/common";
import { env } from "../../config/env";

const logger = new Logger("ContactsParse");

export interface ParsedContact {
  name: string;
  taxId: string;
  countryCode: string;
  email: string;
  addressLine1: string;
  addressLine2: string;
  postalCode: string;
  city: string;
  region: string;
  notes: string;
}

const EMPTY: ParsedContact = {
  name: "",
  taxId: "",
  countryCode: "",
  email: "",
  addressLine1: "",
  addressLine2: "",
  postalCode: "",
  city: "",
  region: "",
  notes: "",
};

const PROMPT = [
  "You are a contact-extraction helper. The user pastes raw text — could be an email signature, a business card scan, a sequence of notes, anything. Extract structured fields for a contact record.",
  "",
  "Output JSON matching the schema. Leave a field empty (\"\") when the value isn't in the text. Do NOT invent or guess.",
  "",
  "Field rules:",
  "- name: company name OR person's full name. Prefer company name when both are present (most invoices are B2B).",
  "- taxId: VAT / NIF / Reg. No — uppercase, no spaces. Include the country prefix when present (\"ES12345678X\", \"DE123456789\", \"BG208701910\").",
  "- countryCode: ISO 3166-1 alpha-2 — \"ES\", \"DE\", \"GB\", \"FR\", etc. Infer from the address if not stated explicitly.",
  "- email: a single email address. If multiple are present pick the most business-looking one.",
  "- addressLine1: street + number.",
  "- addressLine2: floor / suite / building / company-of, etc. — secondary address line.",
  "- postalCode: 4-7 chars depending on country. Keep just the digits / letters, no \"CP\" prefix.",
  "- city: locality only, no postal code.",
  "- region: state / province / autonomous community / county.",
  "- notes: anything that didn't fit the fields above. Keep it short, one or two lines max. Phone numbers, website URLs, free-form descriptions, etc.",
  "",
  "Output ONLY the JSON. No prose, no markdown fences.",
].join("\n");

export async function parseContactText(text: string): Promise<ParsedContact> {
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
              parts: [{ text: `${PROMPT}\n\nSource:\n${text.trim()}` }],
            },
          ],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 512,
            responseMimeType: "application/json",
            responseSchema: {
              type: "object",
              properties: {
                name: { type: "string" },
                taxId: { type: "string" },
                countryCode: { type: "string" },
                email: { type: "string" },
                addressLine1: { type: "string" },
                addressLine2: { type: "string" },
                postalCode: { type: "string" },
                city: { type: "string" },
                region: { type: "string" },
                notes: { type: "string" },
              },
              required: [
                "name",
                "taxId",
                "countryCode",
                "email",
                "addressLine1",
                "addressLine2",
                "postalCode",
                "city",
                "region",
                "notes",
              ],
            },
            thinkingConfig: { thinkingBudget: 0 },
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
    const parsed = JSON.parse(raw) as Partial<ParsedContact>;
    return {
      name: clean(parsed.name),
      taxId: clean(parsed.taxId).toUpperCase().replace(/\s+/g, ""),
      countryCode: clean(parsed.countryCode).toUpperCase().slice(0, 2),
      email: clean(parsed.email),
      addressLine1: clean(parsed.addressLine1),
      addressLine2: clean(parsed.addressLine2),
      postalCode: clean(parsed.postalCode),
      city: clean(parsed.city),
      region: clean(parsed.region),
      notes: clean(parsed.notes),
    };
  } catch (err) {
    logger.warn(
      `parseContactText fell through to empty: ${(err as Error).message}`,
    );
    return EMPTY;
  }
}

function clean(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}
