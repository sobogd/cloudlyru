import { Injectable } from "@nestjs/common";
import PDFDocument from "pdfkit";
import QRCode from "qrcode";
import path from "node:path";

import {
  legalNoteFor,
  type LegalNoteCode,
  PdfLanguage,
  PDF_I18N,
  type PdfStrings,
} from "./i18n";
import {
  COL_LEFT_X,
  COL_RIGHT_X,
  FONT_SIZES,
  MUTED_HEX,
  PAGE_MARGIN,
  QR_SIZE,
  RIGHT_EDGE_X,
  ROW_HEIGHT,
  RULE_HEX,
  TABLE_COLS,
  TABLE_RULE,
  TEXT_HEX,
  fmtMoney,
  formatIsoDate,
} from "./pdf-layout";

// The TTF files are bundled next to the compiled service via nest-cli.json
// `assets`. In dev (ts-node) they are read from src/invoices/pdf/fonts; in
// prod from dist/invoices/pdf/fonts. __dirname resolves both.
const FONT_REGULAR = path.join(__dirname, "fonts", "Inter-Regular.ttf");
const FONT_BOLD = path.join(__dirname, "fonts", "Inter-Bold.ttf");
const FONT_BLACK = path.join(__dirname, "fonts", "Inter-Black.ttf");

/** Frozen snapshot of the counterparty as printed on the invoice.
 *  Matches the JSON stored in Invoice.contactSnapshot. Structured
 *  fields are the new shape (typed by user directly); `lines` is a
 *  legacy Gemini-cleaned array that older rows may still carry —
 *  the renderer falls back to it when no structured address is set. */
export interface ContactSnapshot {
  name: string;
  taxId: string | null;
  countryCode: string | null;
  isEu: boolean;
  email?: string | null;
  addressLine1?: string | null;
  addressLine2?: string | null;
  postalCode?: string | null;
  city?: string | null;
  region?: string | null;
  /** Legacy: pre-composed printable lines. */
  lines?: string[];
}

/** Frozen snapshot of the emitter (Company) as printed on the invoice.
 *  Matches the JSON stored in Invoice.emitterSnapshot. All fields are
 *  optional in DB but the PDF gracefully skips missing ones. */
export interface EmitterSnapshot {
  name: string;
  legalName: string | null;
  taxId: string | null;
  vatId: string | null;
  addressLine1: string | null;
  addressLine2: string | null;
  city: string | null;
  postalCode: string | null;
  region: string | null;
  country: string | null;
  bankName: string | null;
  iban: string | null;
  swift: string | null;
}

export interface InvoiceLineForPdf {
  description: string;
  quantity: number;
  unit: string | null;
  unitPrice: number;
  total: number;
}

export interface InvoiceForPdf {
  number: string;
  issueDate: Date;
  dueDate: Date | null;
  language: PdfLanguage;
  /** ISO 4217 currency label printed after every money figure. */
  currency: string;
  vatRate: number;
  irpfRate: number;
  netAmount: number;
  vatAmount: number;
  irpfAmount: number;
  totalAmount: number;
  toPayAmount: number;
  notes: string | null;
  legalNoteCode: string | null;
  contactSnapshot: ContactSnapshot;
  emitterSnapshot: EmitterSnapshot;
  /** Optional per-invoice bank account picked on the wizard's bank
   *  step. When present, the payment block uses this; otherwise the
   *  block is omitted (no fallback to the emitter's legacy IBAN). */
  bankAccount?: {
    bankName: string | null;
    iban: string | null;
    swift: string | null;
  } | null;
  lines: InvoiceLineForPdf[];
  /** Verifactu artefact — when present, a QR code + verification text
   *  is rendered in the top-right corner. Absent when VERIFACTU_MODE=
   *  disabled on the deploy (pre-2026-07-01 non-Spanish issuers). */
  verifactu?: {
    qrUrl: string;
    /** Last 8 characters of the SHA-256 chain hash — printed next to
     *  the QR as a human-readable corroboration aid. */
    chainHashTail: string;
  };
}

/** Modern invoice renderer in Inter. Single page, no overflow handling
 *  yet — the typical autónomo invoice fits comfortably; multi-page
 *  comes when the line-items grow past ~25 rows. */
@Injectable()
export class PdfRendererService {
  async render(inv: InvoiceForPdf): Promise<Buffer> {
    // Pre-generate the QR-code bitmap when Verifactu is enabled — pdfkit
    // wants a Buffer at draw time and the QR encoder is async. Doing it
    // before the doc starts also surfaces encoder errors as a rejection
    // of the renderer call instead of an unhandled "data"-stream error.
    const qrPng = inv.verifactu
      ? await QRCode.toBuffer(inv.verifactu.qrUrl, {
          type: "png",
          margin: 1,
          width: 240,
          errorCorrectionLevel: "M",
        })
      : null;

    return new Promise<Buffer>((resolve, reject) => {
      const t = PDF_I18N[inv.language];
      const isEs = inv.language === "es";

      // CreationDate pinned to the invoice's issueDate keeps the PDF
      // bytewise-stable across regenerations — important for SHA-256
      // tamper checks and the Verifactu chain audit. Without this,
      // PDFKit stamps `new Date()` on every render.
      const creationDate = inv.issueDate;
      const doc = new PDFDocument({
        margin: PAGE_MARGIN,
        info: {
          Title: `Invoice ${inv.number}`,
          Author: inv.emitterSnapshot.legalName ?? inv.emitterSnapshot.name,
          Subject: `Invoice ${inv.number}`,
          CreationDate: creationDate,
          ModDate: creationDate,
        },
      });
      doc.registerFont("Regular", FONT_REGULAR);
      doc.registerFont("Bold", FONT_BOLD);
      doc.registerFont("Black", FONT_BLACK);
      doc.font("Regular").fillColor(TEXT_HEX);

      const chunks: Buffer[] = [];
      doc.on("data", (c: Buffer) => chunks.push(c));
      doc.on("end", () => resolve(Buffer.concat(chunks)));
      doc.on("error", reject);

      // ── Header band (FACTURA title + meta on left, VERI*FACTU + QR right)
      const headerTop = PAGE_MARGIN;

      // Big "FACTURA" title, left aligned, Inter Black 28pt.
      doc
        .font("Black")
        .fontSize(FONT_SIZES.title)
        .fillColor(TEXT_HEX)
        .text(t.invoice, COL_LEFT_X, headerTop, { lineBreak: false });

      // Meta: Nº, Fecha, Vencimiento — small labels in muted grey,
      // values in regular black. Right under the FACTURA title.
      const metaTop = headerTop + 38;
      drawMetaRow(doc, metaTop, isEs ? "Nº" : "No", inv.number);
      drawMetaRow(doc, metaTop + 14, isEs ? "Fecha" : "Date", formatIsoDate(inv.issueDate));
      const due = inv.dueDate ?? defaultDueDate(inv.issueDate);
      drawMetaRow(doc, metaTop + 28, isEs ? "Vence" : "Due", formatIsoDate(due));

      // VERI*FACTU mark + QR + legend, top-right corner.
      let verifactuBlockBottom = headerTop;
      if (qrPng && inv.verifactu) {
        const qrX = doc.page.width - PAGE_MARGIN - QR_SIZE;
        const markY = headerTop;
        const markWidth = QR_SIZE + 60;
        const markX = qrX - 60;
        // "VERI*FACTU" inscription per RD 1007/2023 art. 6.5 — Inter
        // Black, body colour. The weight + uppercase form is the badge.
        doc
          .font("Black")
          .fontSize(11)
          .fillColor(TEXT_HEX)
          .text("VERI*FACTU", markX, markY, {
            width: markWidth,
            align: "right",
            lineBreak: false,
          });
        const qrY = markY + 16;
        doc.image(qrPng, qrX, qrY, { width: QR_SIZE });
        const legendY = qrY + QR_SIZE + 4;
        doc
          .font("Regular")
          .fontSize(FONT_SIZES.note)
          .fillColor(MUTED_HEX)
          .text(
            "Factura verificable en la sede electrónica de la AEAT",
            markX,
            legendY,
            { width: markWidth, align: "right" },
          )
          .text(`Huella …${inv.verifactu.chainHashTail}`, markX, legendY + 22, {
            width: markWidth,
            align: "right",
            lineBreak: false,
          })
          .fillColor(TEXT_HEX);
        verifactuBlockBottom = legendY + 32;
      }

      // ── Divider (accent line) under the header band ─────────
      const dividerY = Math.max(metaTop + 50, verifactuBlockBottom) + 6;
      drawAccentRule(doc, dividerY);

      // ── EMISOR | CLIENTE two-column block ───────────────────
      const partyTop = dividerY + 14;
      drawSectionHeader(doc, isEs ? "EMISOR" : "FROM", COL_LEFT_X, partyTop);
      drawSectionHeader(doc, isEs ? "CLIENTE" : "BILL TO", COL_RIGHT_X, partyTop);

      const partyLinesTop = partyTop + 14;
      // Cross-border invoices print both tax IDs in VAT-IVA format
      // (country prefix + bare local number, e.g. "ESZ1894474S",
      // "IT01486670532") so the foreign recipient's accountant can
      // file their reverse-charge / Intrastat declaration without
      // having to guess the supplier's country. Domestic Spanish
      // B2B keeps bare NIFs — the conventional format inside Spain.
      const recipientCountry = (inv.contactSnapshot.countryCode || "")
        .trim()
        .toUpperCase();
      const crossBorder = !!recipientCountry && recipientCountry !== "ES";
      const emitterLines = buildEmitterLines(
        inv.emitterSnapshot,
        inv.language,
        crossBorder,
      );
      const clientLines = buildContactLines(
        inv.contactSnapshot,
        inv.language,
        crossBorder,
      );
      doc.font("Regular").fontSize(FONT_SIZES.body).fillColor(TEXT_HEX);
      const emitterColWidth = COL_RIGHT_X - COL_LEFT_X - 10;
      const clientColWidth = RIGHT_EDGE_X - COL_RIGHT_X;
      // Render each column independently — when a long line in one
      // column wraps to two visual rows, the next line of that column
      // continues from the actual cursor position (doc.y) instead of
      // the fixed grid `top + i * ROW_HEIGHT`, which would otherwise
      // print over the wrapped tail. The two columns no longer line
      // up by row index (e.g. emitter line 2 may sit alongside client
      // line 3) — that's the right tradeoff: column readability beats
      // strict horizontal alignment for variable-length addresses.
      let emitterY = partyLinesTop;
      for (let i = 0; i < emitterLines.length; i++) {
        if (i === 0) doc.font("Bold");
        doc.text(emitterLines[i], COL_LEFT_X, emitterY, {
          width: emitterColWidth,
        });
        // doc.y is the cursor position after the wrap-aware text
        // render — covers both single-line and wrapped cases.
        emitterY = doc.y;
        if (i === 0) doc.font("Regular");
      }
      let clientY = partyLinesTop;
      for (let i = 0; i < clientLines.length; i++) {
        if (i === 0) doc.font("Bold");
        doc.text(clientLines[i], COL_RIGHT_X, clientY, {
          width: clientColWidth,
        });
        clientY = doc.y;
        if (i === 0) doc.font("Regular");
      }
      const partyBottom = Math.max(emitterY, clientY);

      // ── Divider before the items table ──────────────────────
      const tableDividerY = partyBottom + 12;
      drawAccentRule(doc, tableDividerY);

      // ── Line items table ────────────────────────────────────
      const tableTop = tableDividerY + 14;
      doc
        .font("Bold")
        .fontSize(FONT_SIZES.sectionHeader)
        .fillColor(MUTED_HEX);
      // Right-align numeric columns so the column origin is the right
      // edge of the cell, then nudge text into place via `width`.
      doc.text(t.description.toUpperCase(), TABLE_COLS.description, tableTop);
      drawRightAlignedHeader(doc, t.qty, TABLE_COLS.quantity, tableTop, 50);
      drawRightAlignedHeader(doc, t.unitPrice, TABLE_COLS.unitPrice, tableTop, 70);
      drawRightAlignedHeader(doc, t.vat, TABLE_COLS.vatRate, tableTop, 35);
      drawRightAlignedHeader(doc, t.net, TABLE_COLS.total, tableTop, RIGHT_EDGE_X - TABLE_COLS.total);

      // Thin underline beneath header.
      doc
        .moveTo(TABLE_RULE.left, tableTop + 14)
        .lineTo(TABLE_RULE.right, tableTop + 14)
        .lineWidth(0.5)
        .strokeColor(MUTED_HEX)
        .stroke();

      doc
        .font("Regular")
        .fontSize(FONT_SIZES.body)
        .fillColor(TEXT_HEX);

      const vatLabel = inv.vatRate === 0 ? "0%*" : `${stripZeros(inv.vatRate)}%`;
      let lineY = tableTop + 22;
      for (const line of inv.lines) {
        const qtyLabel =
          line.quantity === 1
            ? t.pc
            : `${stripZeros(line.quantity)} ${line.unit ?? ""}`.trim();
        doc.text(line.description, TABLE_COLS.description, lineY, {
          width: TABLE_COLS.quantity - TABLE_COLS.description - 10,
        });
        // Track how far the wrapped description pushed the cursor so a
        // long description never gets clipped by the next row.
        const descBottom = doc.y;
        drawRightAlignedCell(doc, qtyLabel, TABLE_COLS.quantity, lineY, 50);
        drawRightAlignedCell(
          doc,
          fmtMoney(line.unitPrice),
          TABLE_COLS.unitPrice,
          lineY,
          70,
        );
        drawRightAlignedCell(doc, vatLabel, TABLE_COLS.vatRate, lineY, 35);
        drawRightAlignedCell(
          doc,
          fmtMoney(line.total),
          TABLE_COLS.total,
          lineY,
          RIGHT_EDGE_X - TABLE_COLS.total,
        );
        lineY = Math.max(lineY + ROW_HEIGHT + 2, descBottom + 4);
      }

      // ── VAT 0% legal note (only when vatRate === 0) ─────────
      let notesY = lineY + 10;
      const note =
        inv.vatRate === 0
          ? legalNoteFor(inv.language, inv.legalNoteCode as LegalNoteCode)
          : "";
      if (note) {
        doc
          .fontSize(FONT_SIZES.note)
          .fillColor(MUTED_HEX)
          .text(note, COL_LEFT_X, notesY, {
            width: RIGHT_EDGE_X - COL_LEFT_X,
          })
          .fillColor(TEXT_HEX);
        notesY = doc.y;
      }

      // ── Totals block (right-aligned) ────────────────────────
      const totalsTop = notesY + 16;
      const totalsRowH = 16;
      let totalsY = totalsTop;
      drawTotalRow(
        doc,
        totalsY,
        isEs ? "Base imponible" : "Subtotal",
        `${fmtMoney(inv.netAmount)} ${inv.currency}`,
      );
      totalsY += totalsRowH;
      if (inv.vatRate === 0) {
        drawTotalRow(
          doc,
          totalsY,
          `${t.vat} 0%*`,
          `${fmtMoney(0)} ${inv.currency}`,
        );
      } else {
        drawTotalRow(
          doc,
          totalsY,
          `${t.vat} ${stripZeros(inv.vatRate)}%`,
          `${fmtMoney(inv.vatAmount)} ${inv.currency}`,
        );
      }
      totalsY += totalsRowH;
      // "Total factura" line (net + VAT) shown only when IRPF is also
      // present — otherwise the emphasised line below IS the total.
      if (inv.irpfRate > 0) {
        drawTotalRow(
          doc,
          totalsY,
          isEs ? "Total factura" : "Invoice total",
          `${fmtMoney(inv.totalAmount)} ${inv.currency}`,
        );
        totalsY += totalsRowH;
        drawTotalRow(
          doc,
          totalsY,
          `${isEs ? "Retención IRPF" : "Withholding IRPF"} ${stripZeros(inv.irpfRate)}%`,
          `-${fmtMoney(inv.irpfAmount)} ${inv.currency}`,
        );
        totalsY += totalsRowH;
      }

      // Emphasized final line — A PAGAR (with IRPF) or TOTAL (without).
      // Solid black rule above + Inter Black so the total reads as the
      // page's centre of gravity even without colour.
      const emphasizedTop = totalsY + 6;
      doc
        .moveTo(RIGHT_EDGE_X - 220, emphasizedTop)
        .lineTo(RIGHT_EDGE_X, emphasizedTop)
        .lineWidth(1)
        .strokeColor(TEXT_HEX)
        .stroke();
      const totalLabel = inv.irpfRate > 0
        ? (isEs ? "A PAGAR" : "TO PAY")
        : (isEs ? "TOTAL" : "TOTAL");
      const totalValue =
        inv.irpfRate > 0 ? inv.toPayAmount : inv.totalAmount;
      doc
        .font("Black")
        .fontSize(FONT_SIZES.totalEmphasis)
        .fillColor(TEXT_HEX)
        .text(totalLabel, RIGHT_EDGE_X - 220, emphasizedTop + 6, {
          width: 110,
          align: "left",
          lineBreak: false,
        })
        .text(
          `${fmtMoney(totalValue)} ${inv.currency}`,
          RIGHT_EDGE_X - 110,
          emphasizedTop + 6,
          { width: 110, align: "right", lineBreak: false },
        )
        .fillColor(TEXT_HEX)
        .font("Regular");

      const totalsBottom = emphasizedTop + 6 + FONT_SIZES.totalEmphasis + 8;

      // ── Divider before the footer ────────────────────────────
      const footerDividerY = totalsBottom + 16;
      drawAccentRule(doc, footerDividerY);

      // ── DATOS DE PAGO single-column footer ───────────────────
      const footerTop = footerDividerY + 14;
      const beneficiary =
        inv.emitterSnapshot.legalName ?? inv.emitterSnapshot.name ?? "";
      const payLines = buildPaymentBlock(
        inv.bankAccount ?? null,
        inv.number,
        beneficiary,
        t,
      );
      let footerBottom = footerTop;
      if (payLines.length > 0) {
        drawSectionHeader(
          doc,
          isEs ? "DATOS DE PAGO" : "PAYMENT DETAILS",
          COL_LEFT_X,
          footerTop,
        );
        const linesTop = footerTop + 14;
        doc.font("Regular").fontSize(FONT_SIZES.body).fillColor(TEXT_HEX);
        for (let i = 0; i < payLines.length; i++) {
          doc.text(payLines[i], COL_LEFT_X, linesTop + i * ROW_HEIGHT, {
            width: RIGHT_EDGE_X - COL_LEFT_X,
          });
        }
        footerBottom = linesTop + payLines.length * ROW_HEIGHT;
      }

      // ── Free-form notes (only if present) ───────────────────
      if (inv.notes && inv.notes.trim()) {
        const notesHeaderY = footerBottom + 14;
        drawSectionHeader(
          doc,
          isEs ? "NOTAS" : "NOTES",
          COL_LEFT_X,
          notesHeaderY,
        );
        doc
          .font("Regular")
          .fontSize(FONT_SIZES.body)
          .fillColor(TEXT_HEX)
          .text(inv.notes.trim(), COL_LEFT_X, notesHeaderY + 14, {
            width: RIGHT_EDGE_X - COL_LEFT_X,
          });
      }

      doc.end();
    });
  }
}

/** Small label in muted grey, value in body weight black, on one row. */
function drawMetaRow(
  doc: PDFKit.PDFDocument,
  y: number,
  label: string,
  value: string,
  valueBold = false,
): void {
  doc
    .font("Regular")
    .fontSize(FONT_SIZES.note)
    .fillColor(MUTED_HEX)
    .text(label.toUpperCase(), COL_LEFT_X, y, {
      width: 70,
      lineBreak: false,
    });
  doc
    .font(valueBold ? "Bold" : "Regular")
    .fontSize(FONT_SIZES.body)
    .fillColor(TEXT_HEX)
    .text(value, COL_LEFT_X + 70, y - 1, {
      width: 220,
      lineBreak: false,
    });
}

/** Uppercase, letter-spaced section header — Inter Bold, muted grey
 *  so the body text below the header stands out. */
function drawSectionHeader(
  doc: PDFKit.PDFDocument,
  text: string,
  x: number,
  y: number,
): void {
  doc
    .font("Bold")
    .fontSize(FONT_SIZES.sectionHeader)
    .fillColor(MUTED_HEX)
    .text(text.toUpperCase(), x, y, {
      characterSpacing: 0.5,
      lineBreak: false,
    })
    .fillColor(TEXT_HEX)
    .font("Regular");
}

/** Thin light-grey horizontal divider across the printable width. */
function drawAccentRule(doc: PDFKit.PDFDocument, y: number): void {
  doc
    .moveTo(TABLE_RULE.left, y)
    .lineTo(TABLE_RULE.right, y)
    .lineWidth(0.5)
    .strokeColor(RULE_HEX)
    .stroke();
}

/** Right-align a table header cell whose origin x is the LEFT side of
 *  the cell. We compute the cell width as (RIGHT_EDGE - x) clamped to
 *  the next column. */
function drawRightAlignedHeader(
  doc: PDFKit.PDFDocument,
  text: string,
  x: number,
  y: number,
  width: number,
): void {
  doc.text(text.toUpperCase(), x, y, { width, align: "right", lineBreak: false });
}

function drawRightAlignedCell(
  doc: PDFKit.PDFDocument,
  text: string,
  x: number,
  y: number,
  width: number,
): void {
  doc.text(text, x, y, { width, align: "right", lineBreak: false });
}

/** One row of the totals block — muted grey label on the left, body
 *  black value on the right. Both right-aligned within their halves of
 *  the totals block (which occupies the right ~220 pt of the page). */
function drawTotalRow(
  doc: PDFKit.PDFDocument,
  y: number,
  label: string,
  value: string,
): void {
  const blockX = RIGHT_EDGE_X - 220;
  doc
    .font("Regular")
    .fontSize(FONT_SIZES.body)
    .fillColor(MUTED_HEX)
    .text(label, blockX, y, { width: 110, align: "left", lineBreak: false });
  doc
    .fillColor(TEXT_HEX)
    .text(value, blockX + 110, y, {
      width: 110,
      align: "right",
      lineBreak: false,
    });
}

/** Build the EMISOR column lines from the frozen emitter snapshot. Order
 *  matches what most Spanish-issued invoices use: name → NIF → VAT ID →
 *  address → city → country.
 *
 *  Country is stored as ISO-2 (required for the AEAT XML CodigoPais
 *  field + NIF-IVA prefix derivation) and is expanded to the full
 *  localised country name at render time, e.g. "ES" → "España" on a
 *  Spanish-language invoice, "Spain" on an English one. */
/** Build the printable recipient block from the invoice snapshot.
 *  New invoices carry structured fields (addressLine1/2, postalCode,
 *  city, region, countryCode); legacy invoices only had `lines[]`
 *  (Gemini-cleaned). We prefer the structured path and fall back to
 *  the legacy lines when no structured fields are present. */
function buildContactLines(
  c: ContactSnapshot,
  language: PdfLanguage,
  crossBorder: boolean,
): string[] {
  const hasStructured =
    !!(c.addressLine1 || c.addressLine2 || c.postalCode || c.city || c.region);
  if (!hasStructured && c.lines && c.lines.length > 0) {
    return c.lines.filter((l) => l && l.trim() !== "");
  }
  const out: string[] = [];
  if (c.name) out.push(c.name);
  if (c.taxId) {
    out.push(crossBorder ? withCountryPrefix(c.taxId, c.countryCode) : c.taxId);
  }
  if (c.addressLine1) out.push(c.addressLine1);
  if (c.addressLine2) out.push(c.addressLine2);
  const cityLine = [c.postalCode, c.city, c.region]
    .filter(Boolean)
    .join(", ");
  if (cityLine) out.push(cityLine);
  const countryName = localizedCountryName(c.countryCode, language);
  if (countryName) out.push(countryName);
  if (c.email) out.push(c.email);
  return out;
}

function buildEmitterLines(
  e: EmitterSnapshot,
  language: PdfLanguage,
  crossBorder: boolean,
): string[] {
  const out: string[] = [];
  out.push(e.legalName ?? e.name);
  if (e.taxId) {
    out.push(crossBorder ? withCountryPrefix(e.taxId, e.country) : e.taxId);
  }
  if (e.vatId && e.vatId !== e.taxId) out.push(e.vatId);
  if (e.addressLine1) out.push(e.addressLine1);
  if (e.addressLine2) out.push(e.addressLine2);
  const cityLine = [e.postalCode, e.city, e.region]
    .filter(Boolean)
    .join(", ");
  if (cityLine) out.push(cityLine);
  const countryName = localizedCountryName(e.country, language);
  if (countryName) out.push(countryName);
  return out;
}

/** Prepend the ISO-2 country code to a tax ID when it's missing, so
 *  the result reads as the EU VAT-IVA / NIF-IVA convention
 *  ("IT01486670532", "ESZ1894474S"). Idempotent — if the user already
 *  typed the prefix, we keep what they typed (case-insensitive).
 *  Mirrors the helper inside submit.service.ts which does the same
 *  for the AEAT XML payload, kept separate here to avoid coupling
 *  the renderer to the Verifactu module. */
function withCountryPrefix(
  taxId: string,
  countryCode: string | null | undefined,
): string {
  const cc = (countryCode || "").trim().toUpperCase();
  if (!cc || cc.length !== 2) return taxId;
  const upperId = taxId.toUpperCase();
  return upperId.startsWith(cc) ? taxId : `${cc}${taxId}`;
}

/** ISO-2 → full localised country name via Intl.DisplayNames (Node ≥16
 *  ships ICU data for all regions). Falls back to the input unchanged
 *  when it's already a full name (>2 chars) or when the ICU lookup
 *  yields nothing (private-use codes etc.). */
function localizedCountryName(
  raw: string | null | undefined,
  language: PdfLanguage,
): string {
  if (!raw) return "";
  const trimmed = raw.trim();
  // Already a full name — print as-is. The Settings form enforces
  // 2-char ISO codes, but legacy data and pasted snapshots may carry
  // "España" / "Germany" verbatim.
  if (trimmed.length !== 2) return trimmed;
  const locale = language === "es" ? "es" : "en";
  try {
    const display = new Intl.DisplayNames([locale], { type: "region" });
    return display.of(trimmed.toUpperCase()) ?? trimmed.toUpperCase();
  } catch {
    return trimmed.toUpperCase();
  }
}

/** Build the DATOS DE PAGO column. Empty when no IBAN / bank info on
 *  file. The invoice number ("Concepto") is always last so the
 *  recipient knows what reference to put on the transfer. */
function buildPaymentBlock(
  acc: { bankName: string | null; iban: string | null; swift: string | null } | null,
  invoiceNumber: string,
  beneficiary: string,
  t: PdfStrings,
): string[] {
  if (!acc || (!acc.iban && !acc.bankName)) return [];
  const out: string[] = [];
  // Beneficiary first — recipient of a wire needs to know WHO the
  // money is going to before they read the bank or IBAN. Sourced
  // from the emitter snapshot's legal name (falls back to display
  // name) so changes in Settings don't rewrite already-sent invoices.
  if (beneficiary.trim()) out.push(`${t.beneficiary}: ${beneficiary}`);
  // Labelled bank name — without the prefix it reads like the
  // beneficiary on a glance, especially when the bank's brand is a
  // person-like word (Sabadell, BBVA, "Caja Rural de Granada"…).
  if (acc.bankName) out.push(`${t.bankName}: ${acc.bankName}`);
  const iban = formatIban(acc.iban);
  if (iban) out.push(`IBAN: ${iban}`);
  if (acc.swift) out.push(`SWIFT: ${acc.swift}`);
  // Reference / Concepto — localised so a non-Spanish payer reading
  // an English invoice doesn't have to guess what "Concepto" means.
  out.push(`${t.reference}: ${invoiceNumber}`);
  return out;
}

/** Strip trailing ".00" from a number, otherwise keep two decimals.
 *  Renders 21 as "21" and 7.5 as "7.50" — matches the legacy CLI's
 *  numeric VAT/IRPF rate labels. */
function stripZeros(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

/** 14 days out — fallback when the invoice has no explicit dueDate. */
function defaultDueDate(issueDate: Date): Date {
  const d = new Date(issueDate);
  d.setDate(d.getDate() + 14);
  return d;
}

/** Format an IBAN in canonical 4-character groups separated by spaces.
 *  Accepts any input (with or without spaces, mixed case) — strips
 *  whitespace, uppercases, then regroups. The print form is the one a
 *  Spanish bank slip / SEPA reference expects. */
function formatIban(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const clean = raw.replace(/\s+/g, "").toUpperCase();
  if (clean.length < 4) return clean;
  return clean.match(/.{1,4}/g)!.join(" ");
}
