/** XML payload builder for the AEAT VeriFactu SOAP service.
 *
 *  Builds a `RegFactuSistemaFacturacion` envelope per the official XSDs
 *  (SuministroLR.xsd + SuministroInformacion.xsd, target namespaces:
 *  https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/SuministroLR.xsd
 *  https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd).
 *
 *  Output is an unsigned SOAP envelope. In VeriFactu mode
 *  (TipoUsoPosibleSoloVerifactu = "S") the XAdES signature on each
 *  RegistroAlta is explicitly NOT required — Orden HFP/1177/2024
 *  Anexo III §3.2: "Para sistemas que cumplan exclusivamente con el
 *  modo VERIFACTU, la firma electrónica del propio registro no será
 *  exigible." Integrity is provided by the hash chain + mTLS
 *  authentication + real-time submission. The XSD reflects this with
 *  `<element ref="ds:Signature" minOccurs="0"/>` (RegistroFacturacionAltaType).
 *
 *  This module is pure (no DB / no IO). All inputs are the frozen
 *  per-invoice data already stored in our DB. */

const NS_SOAP = "http://schemas.xmlsoap.org/soap/envelope/";
const NS_LR =
  "https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/SuministroLR.xsd";
const NS_SF =
  "https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd";

/** Cabecera — the issuer block. Same on every record of a batch. */
export interface CabeceraInput {
  /** Legal/trade name of the obligated emitter. AEAT field
   *  ObligadoEmision/NombreRazon (max 120). */
  obligadoNombreRazon: string;
  /** NIF of the obligated emitter (9 chars). */
  obligadoNif: string;
}

/** Identifies our software in the SistemaInformatico block. Same on every
 *  record we emit. Hard-coded constants live in registerSistemaInformatico
 *  (see VERIFACTU_SOFTWARE_* below) — this struct exists so multi-tenant
 *  installs can override per company in the future. */
export interface SistemaInformaticoInput {
  /** Software developer's name (us). max 120. */
  developerNombreRazon: string;
  /** Software developer NIF (us). 9 chars. */
  developerNif: string;
  /** Product name (max 30). */
  nombreSistemaInformatico: string;
  /** 2-char product code chosen by the developer; arbitrary in sandbox. */
  idSistemaInformatico: string;
  /** Version string (max 50). */
  version: string;
  /** Per-deployment installation id (max 100). Use Company.id or similar
   *  so AEAT can distinguish multiple SaaS tenants on one product. */
  numeroInstalacion: string;
  /** "S" if this install can ONLY operate in Verifactu mode (the default
   *  for our SaaS), "N" if it can also issue invoices outside Verifactu. */
  soloVerifactu: "S" | "N";
  /** "S" if the install is shared across multiple obligados tributarios
   *  (multi-tenant SaaS), "N" if single-tenant. */
  multiOT: "S" | "N";
  /** "S" if the install currently processes records for multiple OTs
   *  in the same batch, "N" otherwise. Always "N" today — we batch by
   *  company. */
  indicadorMultiplesOT: "S" | "N";
}

/** Per-invoice payload. One of these turns into ONE `<sf:RegistroAlta>`. */
export interface RegistroAltaInput {
  /** Emitter NIF — repeated here per record because AEAT validates that
   *  it matches the IDEmisorFactura inside the record. */
  idEmisorFactura: string;
  /** Invoice number, max 60. */
  numSerieFactura: string;
  /** Invoice issue date, DD-MM-YYYY. */
  fechaExpedicionFactura: string;
  /** Legal name of the emitter, max 120. */
  nombreRazonEmisor: string;
  /** "F1" for a full invoice. We only emit F1 today. */
  tipoFactura: "F1" | "F2" | "F3" | "R1" | "R2" | "R3" | "R4" | "R5";
  /** Free-form description of the operation, max 500. */
  descripcionOperacion: string;
  /** Counterparty. Mandatory for F1/F3/R1-R4 (AEAT error 1189), but
   *  OMITTED for F2 (factura simplificada) where the recipient is an
   *  unidentified consumer. The union mirrors the XSD: Spanish
   *  recipients use NIF, foreign use IDOtro (CodigoPais + IDType + ID). */
  destinatario?: DestinatarioInput;
  /** Breakdown lines. One per VAT rate / tax classification. AEAT
   *  allows up to 12. */
  desglose: DesgloseLine[];
  /** Sum of CuotaRepercutida across desglose lines, two-decimal string. */
  cuotaTotal: string;
  /** Invoice gross (net + VAT, two-decimal string). */
  importeTotal: string;
  /** Chain link — either "primer registro" (very first invoice of the
   *  emitter) or a reference to the previous registry. */
  encadenamiento:
    | { kind: "primero" }
    | {
        kind: "anterior";
        idEmisorFactura: string;
        numSerieFactura: string;
        fechaExpedicionFactura: string;
        huella: string;
      };
  /** ISO-8601 datetime with explicit offset (no "Z") — e.g.
   *  "2026-05-29T14:25:33+02:00". Same value used in the hash input. */
  fechaHoraHusoGenRegistro: string;
  /** Uppercase hex SHA-256, max 64 chars. */
  huella: string;
}

export interface DestinatarioInput {
  /** Customer name/legal name, max 120. */
  nombreRazon: string;
  /** Identification. NIF for Spanish customers, IDOtro for the rest.
   *  When neither is known (B2C cash sale) we'd use F2 not F1 — F1
   *  requires identification per AEAT business rule 1189. */
  id:
    | { kind: "nif"; nif: string }
    | {
        kind: "otro";
        /** ISO 3166-1 alpha-2. */
        codigoPais: string;
        /** "02"=NIF-IVA, "04"=ID en país residencia, "07"=No censado, … */
        idType: "02" | "03" | "04" | "05" | "06" | "07";
        /** The identifier itself, max 20. */
        idValue: string;
      };
}

export interface DesgloseLine {
  /** "01" = IVA (default), "03" = IGIC, "02" = IPSI, "05" = Otros. */
  impuesto?: "01" | "02" | "03" | "05";
  /** Régimen de IVA/IGIC. Mandatory when impuesto is 01/02/03 (AEAT
   *  business rule 1245). "01" = régimen general (the default for a
   *  Spanish autónomo emitting a standard invoice). Other notable
   *  values: "17" = OSS / intracomunitarias servicios, "20" = recargo
   *  de equivalencia. */
  claveRegimen?:
    | "01" | "02" | "03" | "04" | "05" | "06" | "07" | "08" | "09"
    | "10" | "11" | "14" | "15" | "17" | "18" | "19" | "20" | "21";
  /** Either CalificacionOperacion (S1/S2/N1/N2) or OperacionExenta
   *  (E1..E8). Use S1 for plain Spanish VAT, S2 for reverse charge
   *  (recipient settles VAT in their country), N2 for art. 69 services
   *  with place of supply outside Spain. */
  calificacion:
    | { kind: "sujeta"; code: "S1" | "S2" | "N1" | "N2" }
    | { kind: "exenta"; code: "E1" | "E2" | "E3" | "E4" | "E5" | "E6" | "E7" | "E8" };
  /** VAT rate as a two-decimal "." string ("21.00", "10.00", "0.00"). */
  tipoImpositivo?: string;
  /** Net amount for this line, two-decimal string. The field is named
   *  ImporteNoSujeto when the line is "no sujeta" — AEAT uses the same
   *  XML element with different semantics depending on calificacion. */
  baseImponibleOimporteNoSujeto: string;
  /** Cuota = base * rate / 100, two-decimal string. Omitted on N1/N2
   *  (no VAT) and on exenta lines. */
  cuotaRepercutida?: string;
}

/** Build the full SOAP envelope for a single-invoice batch.
 *  (Multi-invoice batches are a Phase C optimisation — the schema
 *  allows up to 1000 RegistroFactura children per envelope.) */
export function buildSoapEnvelope(input: {
  cabecera: CabeceraInput;
  sistemaInformatico: SistemaInformaticoInput;
  registros: RegistroAltaInput[];
}): string {
  const cabeceraXml = renderCabecera(input.cabecera);
  const registrosXml = input.registros
    .map((r) => renderRegistroFactura(r, input.sistemaInformatico))
    .join("");

  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<soapenv:Envelope xmlns:soapenv="${NS_SOAP}" xmlns:sfLR="${NS_LR}" xmlns:sf="${NS_SF}">` +
    `<soapenv:Header/>` +
    `<soapenv:Body>` +
    `<sfLR:RegFactuSistemaFacturacion>` +
    cabeceraXml +
    registrosXml +
    `</sfLR:RegFactuSistemaFacturacion>` +
    `</soapenv:Body>` +
    `</soapenv:Envelope>`
  );
}

function renderCabecera(c: CabeceraInput): string {
  // Cabecera is declared inside SuministroLR.xsd (targetNamespace sfLR),
  // so the element itself lives in sfLR even though its TYPE
  // (CabeceraType) is from SuministroInformacion.xsd (sf). Children of
  // CabeceraType inherit the sf namespace because complexType definitions
  // belong to their schema's targetNamespace, not the parent element's.
  return (
    `<sfLR:Cabecera>` +
    `<sf:ObligadoEmision>` +
    `<sf:NombreRazon>${esc(c.obligadoNombreRazon)}</sf:NombreRazon>` +
    `<sf:NIF>${esc(c.obligadoNif)}</sf:NIF>` +
    `</sf:ObligadoEmision>` +
    `</sfLR:Cabecera>`
  );
}

function renderRegistroFactura(
  r: RegistroAltaInput,
  sif: SistemaInformaticoInput,
): string {
  return (
    `<sfLR:RegistroFactura>` +
    `<sf:RegistroAlta>` +
    `<sf:IDVersion>1.0</sf:IDVersion>` +
    `<sf:IDFactura>` +
    `<sf:IDEmisorFactura>${esc(r.idEmisorFactura)}</sf:IDEmisorFactura>` +
    `<sf:NumSerieFactura>${esc(r.numSerieFactura)}</sf:NumSerieFactura>` +
    `<sf:FechaExpedicionFactura>${esc(r.fechaExpedicionFactura)}</sf:FechaExpedicionFactura>` +
    `</sf:IDFactura>` +
    `<sf:NombreRazonEmisor>${esc(r.nombreRazonEmisor)}</sf:NombreRazonEmisor>` +
    `<sf:TipoFactura>${r.tipoFactura}</sf:TipoFactura>` +
    `<sf:DescripcionOperacion>${esc(r.descripcionOperacion)}</sf:DescripcionOperacion>` +
    (r.destinatario ? renderDestinatarios(r.destinatario) : "") +
    renderDesglose(r.desglose) +
    `<sf:CuotaTotal>${esc(r.cuotaTotal)}</sf:CuotaTotal>` +
    `<sf:ImporteTotal>${esc(r.importeTotal)}</sf:ImporteTotal>` +
    renderEncadenamiento(r.encadenamiento) +
    renderSistemaInformatico(sif) +
    `<sf:FechaHoraHusoGenRegistro>${esc(r.fechaHoraHusoGenRegistro)}</sf:FechaHoraHusoGenRegistro>` +
    `<sf:TipoHuella>01</sf:TipoHuella>` +
    `<sf:Huella>${esc(r.huella)}</sf:Huella>` +
    `</sf:RegistroAlta>` +
    `</sfLR:RegistroFactura>`
  );
}

function renderDestinatarios(d: DestinatarioInput): string {
  const idXml =
    d.id.kind === "nif"
      ? `<sf:NIF>${esc(d.id.nif)}</sf:NIF>`
      : `<sf:IDOtro>` +
        `<sf:CodigoPais>${esc(d.id.codigoPais)}</sf:CodigoPais>` +
        `<sf:IDType>${d.id.idType}</sf:IDType>` +
        `<sf:ID>${esc(d.id.idValue)}</sf:ID>` +
        `</sf:IDOtro>`;
  return (
    `<sf:Destinatarios>` +
    `<sf:IDDestinatario>` +
    `<sf:NombreRazon>${esc(d.nombreRazon)}</sf:NombreRazon>` +
    idXml +
    `</sf:IDDestinatario>` +
    `</sf:Destinatarios>`
  );
}

function renderDesglose(lines: DesgloseLine[]): string {
  const detalles = lines
    .map((l) => {
      const parts: string[] = [];
      if (l.impuesto) parts.push(`<sf:Impuesto>${l.impuesto}</sf:Impuesto>`);
      if (l.claveRegimen)
        parts.push(`<sf:ClaveRegimen>${l.claveRegimen}</sf:ClaveRegimen>`);
      if (l.calificacion.kind === "sujeta") {
        parts.push(
          `<sf:CalificacionOperacion>${l.calificacion.code}</sf:CalificacionOperacion>`,
        );
      } else {
        parts.push(
          `<sf:OperacionExenta>${l.calificacion.code}</sf:OperacionExenta>`,
        );
      }
      if (l.tipoImpositivo)
        parts.push(`<sf:TipoImpositivo>${esc(l.tipoImpositivo)}</sf:TipoImpositivo>`);
      parts.push(
        `<sf:BaseImponibleOimporteNoSujeto>${esc(
          l.baseImponibleOimporteNoSujeto,
        )}</sf:BaseImponibleOimporteNoSujeto>`,
      );
      if (l.cuotaRepercutida)
        parts.push(
          `<sf:CuotaRepercutida>${esc(l.cuotaRepercutida)}</sf:CuotaRepercutida>`,
        );
      return `<sf:DetalleDesglose>${parts.join("")}</sf:DetalleDesglose>`;
    })
    .join("");
  return `<sf:Desglose>${detalles}</sf:Desglose>`;
}

function renderEncadenamiento(e: RegistroAltaInput["encadenamiento"]): string {
  if (e.kind === "primero") {
    return `<sf:Encadenamiento><sf:PrimerRegistro>S</sf:PrimerRegistro></sf:Encadenamiento>`;
  }
  return (
    `<sf:Encadenamiento>` +
    `<sf:RegistroAnterior>` +
    `<sf:IDEmisorFactura>${esc(e.idEmisorFactura)}</sf:IDEmisorFactura>` +
    `<sf:NumSerieFactura>${esc(e.numSerieFactura)}</sf:NumSerieFactura>` +
    `<sf:FechaExpedicionFactura>${esc(e.fechaExpedicionFactura)}</sf:FechaExpedicionFactura>` +
    `<sf:Huella>${esc(e.huella)}</sf:Huella>` +
    `</sf:RegistroAnterior>` +
    `</sf:Encadenamiento>`
  );
}

function renderSistemaInformatico(s: SistemaInformaticoInput): string {
  return (
    `<sf:SistemaInformatico>` +
    `<sf:NombreRazon>${esc(s.developerNombreRazon)}</sf:NombreRazon>` +
    `<sf:NIF>${esc(s.developerNif)}</sf:NIF>` +
    `<sf:NombreSistemaInformatico>${esc(s.nombreSistemaInformatico)}</sf:NombreSistemaInformatico>` +
    `<sf:IdSistemaInformatico>${esc(s.idSistemaInformatico)}</sf:IdSistemaInformatico>` +
    `<sf:Version>${esc(s.version)}</sf:Version>` +
    `<sf:NumeroInstalacion>${esc(s.numeroInstalacion)}</sf:NumeroInstalacion>` +
    `<sf:TipoUsoPosibleSoloVerifactu>${s.soloVerifactu}</sf:TipoUsoPosibleSoloVerifactu>` +
    `<sf:TipoUsoPosibleMultiOT>${s.multiOT}</sf:TipoUsoPosibleMultiOT>` +
    `<sf:IndicadorMultiplesOT>${s.indicadorMultiplesOT}</sf:IndicadorMultiplesOT>` +
    `</sf:SistemaInformatico>`
  );
}

/** XML attribute/text escaping. AEAT XSDs are strict — & and < in
 *  invoice descriptions would otherwise break the parse. */
function esc(v: string): string {
  return v
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/** Convenience: pick a sensible Desglose for our two supported invoice
 *  shapes (Spanish VAT 21% B2B with optional IRPF, and 0% non-EU /
 *  intra-EU services). Used by the cron when transforming an Invoice
 *  row into a RegistroAltaInput.
 *
 *  IRPF retention has NO place in Verifactu — AEAT models invoice tax
 *  separately from PIT withholding. Only VAT amounts flow here. */
export function deriveDesglose(args: {
  vatRate: number;
  net: string;
  vat: string;
  contactIsEu: boolean;
}): DesgloseLine[] {
  if (args.vatRate > 0) {
    return [
      {
        impuesto: "01",
        claveRegimen: "01",
        calificacion: { kind: "sujeta", code: "S1" },
        tipoImpositivo: args.vatRate.toFixed(2),
        baseImponibleOimporteNoSujeto: args.net,
        cuotaRepercutida: args.vat,
      },
    ];
  }
  // 0% VAT — either EU B2B intracomunitaria (no sujeta por reglas
  // localización) or extra-EU services (also no sujeta art. 69 LIVA).
  // Both map to N2; the distinction is reported via Modelo 349 / 303,
  // not via this field.
  return [
    {
      impuesto: "01",
      claveRegimen: "01",
      calificacion: { kind: "sujeta", code: "N2" },
      baseImponibleOimporteNoSujeto: args.net,
    },
  ];
}
