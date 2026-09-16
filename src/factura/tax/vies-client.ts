/**
 * VIES SOAP client for the EU checkVatService (checkVatApprox operation).
 *
 * Hand-built SOAP 1.1 envelope, POSTed via the global `fetch` (Node 18+), and a
 * response parsed with plain string/regex extraction — no soap/xml2js deps.
 *
 * ⚠️ IMPORTANT: VIES is frequently down, rate-limited, or slow. Any network
 * failure, timeout, or SOAP fault returns `{ valid: false, error: 'vies-unreachable' }`
 * — this function NEVER throws. Callers MUST treat a set `error` as a SOFT
 * "could not verify online" signal (non-blocking) and NOT as proof the VAT is
 * invalid. Only `valid: false` with NO `error` means "definitively not
 * registered". Use nif-validation.ts for the offline checksum gate.
 */

/** VIES checkVatApprox SOAP endpoint. HTTPS is honoured by the service. */
const VIES_ENDPOINT =
  'https://ec.europa.eu/taxation_customs/vies/services/checkVatService';

const VIES_NS = 'urn:ec.europa.eu:taxud:vies:services:checkVat:types';

export interface ViesResult {
  /** `<valid>` from the response. */
  valid: boolean;
  /**
   * `<requestIdentifier>` — the proof-of-consultation token returned only when
   * a valid requester VAT is supplied. STORE THIS as legal evidence of the
   * consultation.
   */
  requestIdentifier?: string;
  /** Trader name (may be masked as '---' by VIES). */
  name?: string;
  /** Trader address (may be masked as '---' by VIES). */
  address?: string;
  /** Country code actually queried (EL for Greece). */
  countryCode: string;
  /** VAT number (without country prefix) actually queried. */
  vatNumber: string;
  /** ISO timestamp supplied by the caller (we never call Date.now ourselves). */
  checkedAt: string;
  /** Set when VIES was unreachable / returned a SOAP fault (soft failure). */
  error?: string;
}

/** XML-escape a value going into the SOAP body. */
function xmlEscape(v: string): string {
  return v
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * Extract the text content of the first `<...:tag>` element, ignoring any
 * namespace prefix. Returns undefined when the tag is absent.
 */
function extractTag(xml: string, tag: string): string | undefined {
  // Matches <ns:tag ...>value</ns:tag> or <tag>value</tag>.
  const re = new RegExp(
    `<(?:[a-zA-Z0-9]+:)?${tag}[^>]*>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?${tag}>`,
    'i',
  );
  const m = re.exec(xml);
  return m ? m[1].trim() : undefined;
}

/** Build the SOAP 1.1 envelope for checkVatApprox. */
function buildEnvelope(
  countryCode: string,
  vatNumber: string,
  requesterCountryCode?: string,
  requesterVatNumber?: string,
): string {
  const requesterFields =
    requesterCountryCode && requesterVatNumber
      ? `
      <urn:requesterCountryCode>${xmlEscape(requesterCountryCode)}</urn:requesterCountryCode>
      <urn:requesterVatNumber>${xmlEscape(requesterVatNumber)}</urn:requesterVatNumber>`
      : '';

  return `<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="${VIES_NS}">
  <soapenv:Header/>
  <soapenv:Body>
    <urn:checkVatApprox>
      <urn:countryCode>${xmlEscape(countryCode)}</urn:countryCode>
      <urn:vatNumber>${xmlEscape(vatNumber)}</urn:vatNumber>${requesterFields}
    </urn:checkVatApprox>
  </soapenv:Body>
</soapenv:Envelope>`;
}

/**
 * Query VIES for a VAT number using the checkVatApprox operation.
 *
 * @param fullVat       Full VAT incl. country prefix, e.g. "IE6388047V".
 * @param checkedAtIso  ISO timestamp supplied by the caller (recorded verbatim).
 * @param requesterVat  Our own NIF-IVA (full, incl. prefix). When present, VIES
 *                      returns a `requestIdentifier` proof-of-consultation token.
 * @param timeoutMs     Abort after this many ms (default 8000).
 * @returns             A ViesResult. NEVER throws; on any failure `error` is set.
 */
export async function checkViesApprox(
  fullVat: string,
  checkedAtIso: string,
  requesterVat?: string,
  timeoutMs = 8000,
): Promise<ViesResult> {
  const clean = (fullVat || '').toUpperCase().replace(/[\s.\-]/g, '');
  let countryCode = clean.slice(0, 2);
  const vatNumber = clean.slice(2);

  // Greece uses EL for VAT purposes even though its ISO country code is GR.
  if (countryCode === 'GR') countryCode = 'EL';

  // Base result echoed back on every path (success or soft failure).
  const base: ViesResult = {
    valid: false,
    countryCode,
    vatNumber,
    checkedAt: checkedAtIso,
  };

  // Prepare requester fields (also map GR->EL for the requester).
  let requesterCountryCode: string | undefined;
  let requesterVatNumber: string | undefined;
  if (requesterVat) {
    const rc = requesterVat.toUpperCase().replace(/[\s.\-]/g, '');
    requesterCountryCode = rc.slice(0, 2);
    requesterVatNumber = rc.slice(2);
    if (requesterCountryCode === 'GR') requesterCountryCode = 'EL';
  }

  const envelope = buildEnvelope(
    countryCode,
    vatNumber,
    requesterCountryCode,
    requesterVatNumber,
  );

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(VIES_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        // SOAPAction is empty-quoted for this service.
        SOAPAction: '',
      },
      body: envelope,
      signal: controller.signal,
    });

    const text = await res.text();

    // A SOAP fault or non-2xx HTTP status is a soft failure.
    if (!res.ok || /<(?:[a-zA-Z0-9]+:)?Fault[\s>]/i.test(text)) {
      return { ...base, error: 'vies-unreachable' };
    }

    const validText = extractTag(text, 'valid');
    if (validText === undefined) {
      // Response we can't parse — treat as soft failure, not "not registered".
      return { ...base, error: 'vies-unreachable' };
    }

    const name = extractTag(text, 'name');
    const address = extractTag(text, 'address');
    const requestIdentifier = extractTag(text, 'requestIdentifier');

    return {
      valid: validText.toLowerCase() === 'true',
      countryCode,
      vatNumber,
      checkedAt: checkedAtIso,
      // Only surface real values; VIES may return masked '---' or empty strings.
      name: name && name !== '---' ? name : undefined,
      address: address && address !== '---' ? address : undefined,
      requestIdentifier: requestIdentifier || undefined,
    };
  } catch {
    // Network error, DNS failure, or AbortController timeout — all soft.
    return { ...base, error: 'vies-unreachable' };
  } finally {
    clearTimeout(timer);
  }
}
