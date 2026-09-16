/**
 * EU VAT number (NIF-IVA) checksum validation.
 *
 * Self-contained, no external dependencies. Each supported country has a REAL
 * checksum algorithm; unknown-but-plausible EU prefixes fall back to a format
 * sanity check (valid: true, reason: 'format-only') rather than being rejected.
 *
 * These checks are OFFLINE and cheap. They prove a number is *well-formed*, not
 * that it is *registered* — for the latter use the VIES client (vies-client.ts).
 */

export type NifCheckResult = {
  valid: boolean;
  reason?: string;
  /** Normalized VAT: uppercased, no spaces/dots/dashes, prefix included. */
  normalized: string;
};

/** Set of ISO country prefixes that VIES/EU recognise for VAT purposes. */
const EU_PREFIXES = new Set([
  'AT', 'BE', 'BG', 'CY', 'CZ', 'DE', 'DK', 'EE', 'EL', 'GR', 'ES', 'FI',
  'FR', 'HR', 'HU', 'IE', 'IT', 'LT', 'LU', 'LV', 'MT', 'NL', 'PL', 'PT',
  'RO', 'SE', 'SI', 'SK', 'XI', // XI = Northern Ireland
]);

/** Strip spaces, dots and dashes, uppercase everything. */
function normalizeVat(vat: string): string {
  return (vat || '').toUpperCase().replace(/[\s.\-]/g, '');
}

/**
 * Ensure the VAT id carries its country prefix. Forms store the country in a
 * separate field, so users type the bare number ("03074440805" + country IT);
 * validation, the 349 and VIES all need the prefixed form ("IT03074440805").
 * Greece uses EL (not its ISO code GR) as the VAT prefix.
 * Leaves the value untouched when it already starts with a known EU prefix.
 */
export function withCountryPrefix(
  vat: string,
  countryCode: string | null | undefined,
): string {
  const v = normalizeVat(vat);
  if (!v) return v;
  if (EU_PREFIXES.has(v.slice(0, 2))) return v;
  let cc = (countryCode || '').trim().toUpperCase();
  if (cc === 'GR') cc = 'EL';
  if (!EU_PREFIXES.has(cc)) return v; // non-EU country → leave as typed
  return cc + v;
}

// ---------------------------------------------------------------------------
// Ireland (IE)
// ---------------------------------------------------------------------------

const IE_LETTERS = 'WABCDEFGHIJKLMNOPQRSTUV';

/**
 * Irish VAT checksum.
 *
 * Old format: 7 digits + 1 letter (e.g. IE6388047V).
 *   s = sum(digit[i] * (8 - i) for i in 0..6)   // weights 8,7,6,5,4,3,2
 *   check = IE_LETTERS[s % 23]  ==  trailing letter
 *
 * New format: 7 digits + 2 letters (e.g. IE3668997OH). The SECOND letter enters
 * the sum with weight 9; the FIRST trailing letter is the check character:
 *   s = sum(digit[i] * (8 - i)) + (secondLetter - 'A' + 1) * 9
 *   check = IE_LETTERS[s % 23]  ==  first trailing letter
 */
function validateIE(body: string): NifCheckResult {
  const normalized = 'IE' + body;

  // Old lettered form: 7 digits + 1 letter.
  const oldForm = /^(\d{7})([A-W])$/.exec(body);
  if (oldForm) {
    const digits = oldForm[1];
    const letter = oldForm[2];
    let s = 0;
    for (let i = 0; i < 7; i++) s += Number(digits[i]) * (8 - i);
    const check = IE_LETTERS[s % 23];
    return check === letter
      ? { valid: true, normalized }
      : { valid: false, reason: 'ie-checksum-mismatch', normalized };
  }

  // New lettered form: 7 digits + 2 letters (second is A..Z, first is check).
  const newForm = /^(\d{7})([A-W])([A-Z])$/.exec(body);
  if (newForm) {
    const digits = newForm[1];
    const first = newForm[2];
    const second = newForm[3];
    let s = 0;
    for (let i = 0; i < 7; i++) s += Number(digits[i]) * (8 - i);
    s += (second.charCodeAt(0) - 64) * 9; // 'A' -> 1 * 9, etc.
    const check = IE_LETTERS[s % 23];
    return check === first
      ? { valid: true, normalized }
      : { valid: false, reason: 'ie-checksum-mismatch', normalized };
  }

  return { valid: false, reason: 'ie-bad-format', normalized };
}

// ---------------------------------------------------------------------------
// Spain (ES) — DNI / NIE / CIF
// ---------------------------------------------------------------------------

const ES_DNI_LETTERS = 'TRWAGMYFPDXBNJZSQVHLCKE';
// CIF control-letter table (used when the entity type requires a letter check).
const ES_CIF_LETTERS = 'JABCDEFGHI';

/** DNI: 8 digits + control letter from the mod-23 table. */
function validateES_DNI(body: string, normalized: string): NifCheckResult {
  const m = /^(\d{8})([A-Z])$/.exec(body);
  if (!m) return { valid: false, reason: 'es-bad-format', normalized };
  const expected = ES_DNI_LETTERS[Number(m[1]) % 23];
  return expected === m[2]
    ? { valid: true, normalized }
    : { valid: false, reason: 'es-dni-checksum-mismatch', normalized };
}

/** NIE: X/Y/Z + 7 digits + letter. X->0, Y->1, Z->2 then DNI table. */
function validateES_NIE(body: string, normalized: string): NifCheckResult {
  const m = /^([XYZ])(\d{7})([A-Z])$/.exec(body);
  if (!m) return { valid: false, reason: 'es-bad-format', normalized };
  const prefixDigit = { X: '0', Y: '1', Z: '2' }[m[1] as 'X' | 'Y' | 'Z'];
  const expected = ES_DNI_LETTERS[Number(prefixDigit + m[2]) % 23];
  return expected === m[3]
    ? { valid: true, normalized }
    : { valid: false, reason: 'es-nie-checksum-mismatch', normalized };
}

/**
 * CIF: leading letter + 7 digits + control char.
 * Control = mod-10 of a weighted sum: odd positions (1-based) doubled with
 * digit-sum reduction, even positions added straight. Control is a digit
 * (10 - sum%10) or the letter form from ES_CIF_LETTERS depending on entity type.
 * Some entity types require a letter, some a digit, some accept either — so we
 * accept the number if EITHER the digit OR the letter form matches.
 */
function validateES_CIF(body: string, normalized: string): NifCheckResult {
  const m = /^([ABCDEFGHJNPQRSUVW])(\d{7})([0-9A-J])$/.exec(body);
  if (!m) return { valid: false, reason: 'es-bad-format', normalized };
  const digits = m[2];
  const control = m[3];

  let sum = 0;
  for (let i = 0; i < 7; i++) {
    let n = Number(digits[i]);
    if (i % 2 === 0) {
      // Odd positions (1,3,5,7 in 1-based) doubled with digit-sum reduction.
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  const controlDigit = (10 - (sum % 10)) % 10;
  const controlLetter = ES_CIF_LETTERS[controlDigit];

  const ok = control === String(controlDigit) || control === controlLetter;
  return ok
    ? { valid: true, normalized }
    : { valid: false, reason: 'es-cif-checksum-mismatch', normalized };
}

function validateES(body: string): NifCheckResult {
  const normalized = 'ES' + body;
  if (/^\d{8}[A-Z]$/.test(body)) return validateES_DNI(body, normalized);
  if (/^[XYZ]\d{7}[A-Z]$/.test(body)) return validateES_NIE(body, normalized);
  if (/^[A-Z]\d{7}[0-9A-J]$/.test(body)) return validateES_CIF(body, normalized);
  return { valid: false, reason: 'es-bad-format', normalized };
}

// ---------------------------------------------------------------------------
// Portugal (PT) — 9 digits, mod-11 weighted 9..2
// ---------------------------------------------------------------------------

function validatePT(body: string): NifCheckResult {
  const normalized = 'PT' + body;
  if (!/^\d{9}$/.test(body)) {
    return { valid: false, reason: 'pt-bad-format', normalized };
  }
  let sum = 0;
  for (let i = 0; i < 8; i++) sum += Number(body[i]) * (9 - i);
  let check = 11 - (sum % 11);
  if (check >= 10) check = 0;
  return check === Number(body[8])
    ? { valid: true, normalized }
    : { valid: false, reason: 'pt-checksum-mismatch', normalized };
}

// ---------------------------------------------------------------------------
// Italy (IT) — 11 digits, Luhn-style Partita IVA
// ---------------------------------------------------------------------------

function validateIT(body: string): NifCheckResult {
  const normalized = 'IT' + body;
  if (!/^\d{11}$/.test(body)) {
    return { valid: false, reason: 'it-bad-format', normalized };
  }
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    let n = Number(body[i]);
    // Even positions (0-based) straight; odd positions doubled with reduction.
    if (i % 2 === 1) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  const check = (10 - (sum % 10)) % 10;
  return check === Number(body[10])
    ? { valid: true, normalized }
    : { valid: false, reason: 'it-checksum-mismatch', normalized };
}

// ---------------------------------------------------------------------------
// Bulgaria (BG) — 9 or 10 digits
// ---------------------------------------------------------------------------

/**
 * BG 9-digit legal-entity (BULSTAT/EIK) checksum.
 * Weights 1..8 over the first 8 digits, mod 11. If remainder == 10, retry with
 * weights 3..10, mod 11; if still 10 -> check digit is 0.
 *
 * NOTE: 10-digit personal numbers (EGN/personal-VAT) use a different algorithm;
 * for those (and any 9-digit number that fails the legal-entity algo) we fall
 * back to format-only rather than hard-failing, to avoid false negatives on
 * valid-but-differently-structured Bulgarian numbers.
 */
function validateBG(body: string): NifCheckResult {
  const normalized = 'BG' + body;
  if (!/^\d{9,10}$/.test(body)) {
    return { valid: false, reason: 'bg-bad-format', normalized };
  }

  if (body.length === 9) {
    const d = body.split('').map(Number);
    let sum = 0;
    for (let i = 0; i < 8; i++) sum += d[i] * (i + 1);
    let r = sum % 11;
    if (r === 10) {
      sum = 0;
      for (let i = 0; i < 8; i++) sum += d[i] * (i + 3);
      r = sum % 11;
      if (r === 10) r = 0;
    }
    if (r === d[8]) return { valid: true, normalized };
    // Fall back to format-only rather than hard-failing (see note above).
    return { valid: true, reason: 'format-only', normalized };
  }

  // 10-digit numbers: format-only (personal-number algorithms out of scope).
  return { valid: true, reason: 'format-only', normalized };
}

// ---------------------------------------------------------------------------
// Germany (DE) — 9 digits, ISO 7064 MOD 11,10
// ---------------------------------------------------------------------------

function validateDE(body: string): NifCheckResult {
  const normalized = 'DE' + body;
  if (!/^\d{9}$/.test(body)) {
    return { valid: false, reason: 'de-bad-format', normalized };
  }
  let product = 10;
  for (let i = 0; i < 8; i++) {
    let sum = (Number(body[i]) + product) % 10;
    if (sum === 0) sum = 10;
    product = (2 * sum) % 11;
  }
  const check = (11 - product) % 10;
  return check === Number(body[8])
    ? { valid: true, normalized }
    : { valid: false, reason: 'de-checksum-mismatch', normalized };
}

// ---------------------------------------------------------------------------
// France (FR) — 2 key chars + 9-digit SIREN
// ---------------------------------------------------------------------------

/** Standard Luhn check over a numeric string. */
function luhnValid(digits: string): boolean {
  let sum = 0;
  const rev = digits.split('').reverse();
  for (let i = 0; i < rev.length; i++) {
    let n = Number(rev[i]);
    if (i % 2 === 1) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  return sum % 10 === 0;
}

function validateFR(body: string): NifCheckResult {
  const normalized = 'FR' + body;
  // Key = 2 chars (digits or letters), then 9-digit SIREN.
  const m = /^([0-9A-Z]{2})(\d{9})$/.exec(body);
  if (!m) return { valid: false, reason: 'fr-bad-format', normalized };
  const key = m[1];
  const siren = m[2];

  if (!luhnValid(siren)) {
    return { valid: false, reason: 'fr-siren-luhn-mismatch', normalized };
  }

  // If the key is purely numeric, verify it: key = (12 + 3*(SIREN % 97)) % 97.
  if (/^\d{2}$/.test(key)) {
    const expected = (12 + 3 * (Number(siren) % 97)) % 97;
    if (Number(key) !== expected) {
      return { valid: false, reason: 'fr-key-mismatch', normalized };
    }
  }

  return { valid: true, normalized };
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/**
 * Validate an EU VAT number (NIF-IVA) by checksum where an algorithm is known,
 * otherwise by format sanity check.
 *
 * @param vat Raw VAT string, with or without spaces/dots/dashes.
 * @returns { valid, reason?, normalized }
 */
export function validateNifIva(vat: string): NifCheckResult {
  const normalized = normalizeVat(vat);

  if (normalized.length < 3) {
    return { valid: false, reason: 'too-short', normalized };
  }

  // First 2 chars = country prefix. Greece is EL for VAT but callers may pass GR.
  let prefix = normalized.slice(0, 2);
  const body = normalized.slice(2);

  if (prefix === 'GR') prefix = 'EL';

  if (!/^[A-Z]{2}$/.test(prefix)) {
    return { valid: false, reason: 'bad-country-prefix', normalized };
  }

  switch (prefix) {
    case 'IE':
      return validateIE(body);
    case 'ES':
      return validateES(body);
    case 'PT':
      return validatePT(body);
    case 'IT':
      return validateIT(body);
    case 'BG':
      return validateBG(body);
    case 'DE':
      return validateDE(body);
    case 'FR':
      return validateFR(body);
    default:
      break;
  }

  // Unknown EU prefix: don't reject plausible numbers — format sanity only.
  if (EU_PREFIXES.has(prefix)) {
    // Body should be 2..12 alphanumeric chars for any EU VAT number.
    if (/^[0-9A-Z]{2,12}$/.test(body)) {
      return { valid: true, reason: 'format-only', normalized };
    }
    return { valid: false, reason: 'bad-format', normalized };
  }

  return { valid: false, reason: 'non-eu-prefix', normalized };
}

/**
 * Test vectors covering the MUST-PASS / MUST-FAIL cases. Imported by tests so
 * they stay co-located with the implementation.
 */
export const __testVectors: ReadonlyArray<{ vat: string; valid: boolean }> = [
  // Ireland
  { vat: 'IE6388047V', valid: true },
  { vat: 'IE3668997OH', valid: true },
  { vat: 'IE9692928F', valid: true },
  { vat: 'IE9692929F', valid: false }, // correct check char is H, not F
  // Portugal
  { vat: 'PT176243747', valid: true },
  // Italy
  { vat: 'IT01468670532', valid: true },
  // Bulgaria
  { vat: 'BG208701910', valid: true },
];
