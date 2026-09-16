// Layout constants for the invoice PDF. Monochrome Inter-based design —
// emitter on left / customer on right, thin grey rules between
// sections, big bold "A PAGAR" total line. No brand colour so the
// invoice prints identically on a B&W printer and stays neutral when
// folded into accounting software / Modelo 130 dossiers.
//
// Coordinates are A4 (595×842 pt) with PAGE_MARGIN gutters.

export const PAGE_MARGIN = 50;

/** Primary text colour. Slightly off-black so it doesn't look
 *  oversaturated against white at 10pt. */
export const TEXT_HEX = "#111111";
/** Muted grey for section sub-labels ("Nº", "Fecha", "IBAN", legal
 *  notes, table-header captions). Body values stay in TEXT_HEX so
 *  the hierarchy reads naturally on print. */
export const MUTED_HEX = "#666666";
/** Light grey used for the thin section dividers. Survives photocopy
 *  but stays out of the way on the page. */
export const RULE_HEX = "#cccccc";

/** Default vertical spacing between body-text rows. Slightly tighter
 *  than the legacy 14pt to make room for the new section dividers. */
export const ROW_HEIGHT = 13;

export const FONT_SIZES = {
  /** Big "FACTURA" / "INVOICE" header. Inter Black. */
  title: 28,
  /** Uppercase tracked section headers ("EMISOR", "CLIENTE", ...). */
  sectionHeader: 9,
  /** Body text — table rows, address blocks, meta. */
  body: 10,
  /** Small print — legal notes, QR legend, free-form notes. */
  note: 8,
  /** Big "A PAGAR" / "TOTAL" total line. Inter Black on body colour. */
  totalEmphasis: 16,
} as const;

/** Column boundaries for the two-column blocks (EMISOR / CLIENTE,
 *  CONTACTO / DATOS DE PAGO). Right column starts halfway across the
 *  printable area so addresses get enough breathing room. */
export const COL_LEFT_X = PAGE_MARGIN;
export const COL_RIGHT_X = 305;

/** Column X-coordinates for the single line-items table. Description
 *  hugs the left margin; numeric columns are right-aligned manually via
 *  shifting the column origin a few points. Widths were tuned for
 *  Inter at 10pt — "1000.00" fits comfortably in the Total cell. */
export const TABLE_COLS = {
  description: 50,
  quantity: 300,
  unitPrice: 360,
  vatRate: 440,
  total: 485,
} as const;

/** Horizontal extent of the divider lines and table rules. */
export const TABLE_RULE = { left: 50, right: 545 } as const;

/** Right edge for right-aligned numbers (totals block, table totals). */
export const RIGHT_EDGE_X = 545;

/** QR + VERI*FACTU mark in the top-right corner. 90 pt ≈ 31.75 mm,
 *  above the 30 mm minimum set by RD 1007/2023 art. 6.5. */
export const QR_SIZE = 90;

/** Date helper. PDFs use ISO YYYY-MM-DD across all three languages so
 *  Spanish tax inspections do not need to interpret regional formats. */
export function formatIsoDate(d: Date): string {
  const year = d.getUTCFullYear();
  const month = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** Money helper. We always render with 2 decimals and a "." separator —
 *  the legacy CLI does the same. The ",00" string the original Spanish
 *  branch used ("0,00 EUR" for the VAT-0 line) is folded back into "0.00"
 *  for consistency; if a customer ever requests Spanish locale numbers it
 *  becomes an i18n flag, not a per-line special case. */
export function fmtMoney(n: number): string {
  return n.toFixed(2);
}
