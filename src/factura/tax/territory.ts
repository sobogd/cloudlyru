/**
 * Territory classification for Spanish IVA / intra-EU reporting.
 *
 * The single source of truth for "what fiscal territory does this counterparty
 * belong to". Every routing decision in the 303 / 349 engine branches on the
 * class returned here — NOT on the raw ISO country code (that was bug C-2:
 * only the ISO code was stored and the logic never branched on it, so US fell
 * into the intra-EU box and CH fell out of every box).
 *
 * Four classes:
 *   ES_IVA     — Spain, inside the IVA zone (Península, Baleares).
 *   ES_NO_IVA  — Spain, outside the IVA zone (Canarias, Ceuta, Melilla).
 *                Same ISO code `ES`, so it CANNOT be auto-detected from the
 *                country alone — the caller must pass `esNoIva: true`
 *                (driven by an explicit flag on the contact/expense).
 *   EU         — another EU member state, inside the EU VAT area.
 *   THIRD      — third country (US, CH, NO, IS, TR, GB post-Brexit, …).
 *
 * Gotchas baked in (all from the C-2 bug report):
 *   - Norway / Iceland are EEA but NOT EU → THIRD for VAT.
 *   - United Kingdom left the EU on 2021-01-01 → THIRD from that date.
 *   - Northern Ireland (pseudo-code `XI`) stayed in the EU VAT area *for
 *     goods only*; for services it is a third country. So the class depends
 *     on `nature` as well as the code and the date.
 *   - Territory class is time-dependent (Brexit) → `date` is required.
 */

export type TerritoryClass = "ES_IVA" | "ES_NO_IVA" | "EU" | "THIRD";
export type OperationNature = "goods" | "service";

/** EU member states (ISO alpha-2), excluding ES itself. `EL` is the VAT
 *  prefix Greece uses; `GR` is the ISO code — both map to EU. */
export const EU_MEMBER_CODES: ReadonlySet<string> = new Set([
  "AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "FI", "FR",
  "GR", "EL", "HR", "HU", "IE", "IT", "LT", "LU", "LV", "MT",
  "NL", "PL", "PT", "RO", "SE", "SI", "SK",
]);

/** Dates a country left the EU VAT area. Compared as `date >= exit` → THIRD. */
const EU_EXITS: Record<string, string> = {
  GB: "2021-01-01", // Brexit transition ended 2020-12-31; from 2021 UK is third.
};

function isEuMemberAt(code: string, date: Date): boolean {
  if (!EU_MEMBER_CODES.has(code)) return false;
  const exit = EU_EXITS[code];
  if (exit && date >= new Date(exit + "T00:00:00Z")) return false;
  return true;
}

export interface ClassifyOpts {
  /** Only meaningful for ES: set true for Canarias / Ceuta / Melilla, which
   *  share the `ES` ISO code but sit outside the IVA zone. */
  esNoIva?: boolean;
}

/**
 * Classify a counterparty's territory for a given operation nature and date.
 *
 * @param countryCode ISO alpha-2 (or the pseudo-code `XI` for Northern
 *   Ireland). Case-insensitive. Empty/unknown → THIRD (safe default: a
 *   missing country is never treated as domestic or intra-EU).
 * @param nature `goods` | `service` — matters for XI and for downstream
 *   349 clave selection. Defaults to `service` (our typical case: Ads/Cloud).
 * @param date The operation's devengo date. Brexit and future accession
 *   dates make the class time-dependent.
 */
export function classifyTerritory(
  countryCode: string | null | undefined,
  nature: OperationNature = "service",
  date: Date = new Date("2000-01-01T00:00:00Z"),
  opts: ClassifyOpts = {},
): TerritoryClass {
  const cc = (countryCode || "").trim().toUpperCase();
  if (!cc) return "THIRD";

  if (cc === "ES") return opts.esNoIva ? "ES_NO_IVA" : "ES_IVA";

  // Northern Ireland: EU VAT area for goods, third country for services.
  if (cc === "XI") return nature === "goods" ? "EU" : "THIRD";

  if (isEuMemberAt(cc, date)) return "EU";

  return "THIRD";
}

/** True when the counterparty is inside the EU VAT area for this operation
 *  (drives reverse-charge on purchases and clave selection on 349). ES is
 *  domestic, not "intra-EU", so it is excluded here. */
export function isIntraEu(
  countryCode: string | null | undefined,
  nature: OperationNature = "service",
  date?: Date,
): boolean {
  return classifyTerritory(countryCode, nature, date) === "EU";
}
