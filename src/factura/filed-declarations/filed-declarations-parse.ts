/** Gemini-backed "upload the AEAT return, get the fields" helper for filed
 *  declarations.
 *
 *  Used by /filed-declarations/upload — the dashboard lets the user upload a
 *  PDF / screenshot of an already-filed AEAT return (Modelo 303 / 130 / 349).
 *  We send it to Gemini vision and return a best-effort structured parse for
 *  the form to pre-fill. The user reviews and edits every field before saving.
 *
 *  Mirrors expenses-parse.ts (native fetch, gemini-2.5-flash, GEMINI_API_KEY,
 *  same generationConfig discipline) but extracts the declaration boxes
 *  (casillas) instead of a supplier invoice. */

import { Logger } from "@nestjs/common";
import { env } from "../../config/env";

const logger = new Logger("FiledDeclarationsParse");

export interface ParsedFiledDeclaration {
  model: string; // "303" | "130" | "349" | ""
  year: number; // ejercicio
  quarter: number; // periodo 1T→1 … 4T→4 ; 0 when unknown
  justificante: string; // número de justificante
  submittedAt: string; // YYYY-MM-DD — fecha de presentación
  casillas: Record<string, number>; // box-number → euro value
  resultPaid: number; // 130→box07 ; 303→box71 ; 0 when n/a
  compensarNext: number; // 303→box87 (a compensar) ; 0 when n/a
}

const EMPTY: ParsedFiledDeclaration = {
  model: "",
  year: 0,
  quarter: 0,
  justificante: "",
  submittedAt: "",
  casillas: {},
  resultPaid: 0,
  compensarNext: 0,
};

const PROMPT = [
  "You extract fields from a filed Spanish AEAT tax return — a 'Modelo 303' (IVA), 'Modelo 130' (pago fraccionado IRPF) or 'Modelo 349' (operaciones intracomunitarias). The document is the acuse / justificante or a screenshot of the presented return.",
  "",
  "Output JSON matching the schema. Leave a field empty (\"\" / 0 / {}) when the value isn't present. Do NOT invent or guess.",
  "",
  "Field rules:",
  "- model: which modelo — exactly \"303\", \"130\" or \"349\". Read it from the form header.",
  "- year: the ejercicio (fiscal year) as a 4-digit number.",
  "- quarter: the periodo — map 1T→1, 2T→2, 3T→3, 4T→4. If shown as a month range, infer the quarter (Jan-Mar→1, Apr-Jun→2, Jul-Sep→3, Oct-Dec→4). 0 if unknown.",
  "- justificante: the 'número de justificante' (the long presentation receipt number). Digits only, no spaces.",
  "- submittedAt: the 'fecha de presentación' in YYYY-MM-DD. If only DD/MM/YYYY is shown, convert it.",
  "- casillas: an object mapping each numbered box ('casilla') that appears on the return to its euro value as a number. Use the box number as the key, zero-padded to 2 digits where the form prints it that way (e.g. \"07\", \"71\", \"87\", \"110\"). Value is the amount; negatives allowed. Include only boxes actually printed with a value.",
  "- resultPaid: the amount effectively resulting to pay/deposit — for Modelo 130 this is box 07, for Modelo 303 this is box 71 (resultado de la liquidación). 0 for 349 or when not shown.",
  "- compensarNext: for Modelo 303 only, box 87 ('a compensar' — the amount carried to the next period). 0 for 130 / 349 or when not shown.",
  "",
  "Output ONLY the JSON. No prose, no markdown fences.",
].join("\n");

export async function parseFiledDeclarationFile(
  base64: string,
  mimeType: string,
): Promise<ParsedFiledDeclaration> {
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
            // A full AEAT declaration has many boxes; 4096 truncated the JSON
            // mid-string ("Unterminated string in JSON"). Raise the ceiling and
            // disable gemini-2.5-flash "thinking" (it drains the same output
            // budget), so the structured JSON always fits.
            maxOutputTokens: 16384,
            thinkingConfig: { thinkingBudget: 0 },
            responseMimeType: "application/json",
            responseSchema: {
              type: "object",
              properties: {
                model: { type: "string" },
                year: { type: "number" },
                quarter: { type: "number" },
                justificante: { type: "string" },
                submittedAt: { type: "string" },
                // Gemini's response schema can't express an open-keyed map, so
                // we take the casillas back as an array of {box,value} pairs and
                // fold it into a Record below.
                casillas: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      box: { type: "string" },
                      value: { type: "number" },
                    },
                    required: ["box", "value"],
                  },
                },
                resultPaid: { type: "number" },
                compensarNext: { type: "number" },
              },
              required: [
                "model",
                "year",
                "quarter",
                "justificante",
                "submittedAt",
                "casillas",
                "resultPaid",
                "compensarNext",
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
    const p = JSON.parse(raw) as {
      model?: unknown;
      year?: unknown;
      quarter?: unknown;
      justificante?: unknown;
      submittedAt?: unknown;
      casillas?: { box?: unknown; value?: unknown }[];
      resultPaid?: unknown;
      compensarNext?: unknown;
    };

    const casillas: Record<string, number> = {};
    if (Array.isArray(p.casillas)) {
      for (const c of p.casillas) {
        const box = str(c?.box);
        if (!box) continue;
        casillas[box] = round2(num(c?.value));
      }
    }

    const model = normalizeModel(p.model);

    return {
      model,
      year: Math.trunc(num(p.year)),
      quarter: Math.trunc(num(p.quarter)),
      justificante: str(p.justificante).replace(/\s+/g, ""),
      submittedAt: str(p.submittedAt).slice(0, 10),
      casillas,
      resultPaid: round2(num(p.resultPaid)),
      compensarNext: round2(num(p.compensarNext)),
    };
  } catch (err) {
    logger.warn(
      `parseFiledDeclarationFile fell through to empty: ${(err as Error).message}`,
    );
    return EMPTY;
  }
}

function normalizeModel(v: unknown): string {
  const s = str(v).replace(/\D/g, "");
  return s === "303" || s === "130" || s === "349" ? s : "";
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
