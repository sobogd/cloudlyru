/** Build the QR-code URL printed on every Verifactu PDF. Scanning it
 *  drops the customer onto the AEAT validation page that looks the
 *  invoice up by (NIF + serie + fecha + importe).
 *
 *  AEAT hosts two separate validators: a pre-production sandbox for
 *  testing against records that were sent to the sandbox endpoint, and
 *  the production validator for real records. The URL host is the only
 *  difference between the two environments. */

export type VerifactuEnv = "sandbox" | "production";

// Same hosts AEAT publishes for the SOAP endpoint (see aeat-client.ts).
// Earlier we had `www1.aeat.es` for production — that host doesn't serve
// the ValidarQR path. Per Orden HAC/1177/2024 Anexo VI the canonical
// production URL lives under the agenciatributaria.gob.es domain.
const HOSTS: Record<VerifactuEnv, string> = {
  sandbox: "https://prewww1.aeat.es",
  production: "https://www1.agenciatributaria.gob.es",
};

const PATH = "/wlpl/TIKE-CONT/ValidarQR";

export interface QrUrlInputs {
  /** Emitter NIF. */
  nif: string;
  /** Invoice number — same string that lives on the PDF. */
  numSerie: string;
  /** Invoice issue date as DD-MM-YYYY. */
  fecha: string;
  /** Invoice total with two decimals, "." separator. */
  importe: string;
}

export function buildQrUrl(env: VerifactuEnv, inputs: QrUrlInputs): string {
  const params = new URLSearchParams({
    nif: inputs.nif,
    numserie: inputs.numSerie,
    fecha: inputs.fecha,
    importe: inputs.importe,
  });
  return `${HOSTS[env]}${PATH}?${params.toString()}`;
}
