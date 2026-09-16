/**
 * Pure tax engine for Modelos 303 / 349 / 130.
 *
 * No Prisma, no NestJS — plain functions over plain rows so the whole thing
 * is unit-testable against the AEAT regression fixtures (see the .spec file).
 * `DeclarationsService` fetches the rows and calls `computeDeclarations`.
 *
 * Routing table (from the C-* bug report — this is the corrected model):
 *
 *   Operation                    | Devengado | Deducible | Info
 *   -----------------------------|-----------|-----------|------
 *   Sale ES_IVA                  | 01/03     | —         | —
 *   Sale EU B2B (goods/services) | —         | —         | 59   (349 clave E/S)
 *   Sale THIRD services          | —         | —         | 120
 *   Sale THIRD goods (export)    | —         | —         | 60
 *   Purchase ES_IVA              | —         | 28/29     | —
 *   Purchase EU (reverse charge) | 10/11     | 36/37     | 349 clave A/I
 *   Purchase THIRD (ISP)         | 12/13     | 28/29     | —   (NOT in 349)
 *
 * Key rules the old engine got wrong:
 *   - Reverse-charge / ISP VAT is SELF-ASSESSED at the Spanish 21% rate from
 *     the base (C-3): it was recorded as 0 before. Cuota appears on BOTH the
 *     devengado and deducible side (net zero when fully deductible).
 *   - THIRD-country purchases route to 12/13 → 28/29, NEVER 10/11 and never
 *     349 (C-2, 303-2/3/4).
 *   - THIRD-country sales are declared (120/60), not dropped (C-4, 303-6).
 *   - 349 clave depends on direction × nature: A/I/E/S (349-1), aggregated by
 *     NIF (349-2).
 *   - 130 box 05 is READ from the filed archive, not recomputed (130-2); box
 *     05/06 semantics are the official ones (130-3); TGSS flows in as an
 *     expense (130-4).
 */

import {
  classifyTerritory,
  type OperationNature,
  type TerritoryClass,
} from "../tax/territory";
import { validateNifIva } from "../tax/nif-validation";

/** The Spanish general VAT rate used to self-assess reverse-charge / ISP. */
const ES_VAT_RATE = 21;

export interface Casilla {
  code: string;
  labelEs: string;
  labelEn: string;
  value: number;
}

export type Clave349 = "A" | "E" | "I" | "S";

/** A pre-flight validation issue. `blocking` errors should stop a filing;
 *  warnings are advisory. */
export interface DeclarationIssue {
  code: string;
  severity: "error" | "warning";
  messageEs: string;
  messageEn: string;
}

// ---- Engine input rows (currency already normalised to EUR) ----

export interface SaleRow {
  issueDate: Date;
  countryCode: string | null;
  taxId: string | null;
  name: string;
  esNoIva?: boolean;
  nature: OperationNature;
  vatRate: number;
  netEur: number;
  vatEur: number;
  irpfEur: number;
  /** True when the row is in a foreign currency but has NO stored EUR mirror —
   *  its "EUR" figures are face-value and the declaration would be wrong. */
  eurUnreliable?: boolean;
}

export interface PurchaseRow {
  issueDate: Date;
  countryCode: string | null;
  taxId: string | null;
  name: string;
  esNoIva?: boolean;
  nature: OperationNature;
  kind: "invoice" | "recurring_no_invoice";
  vatEur: number;
  netEur: number;
  deductiblePct: number; // 0..100
  deductibleForIrpf: boolean;
  /** See SaleRow.eurUnreliable. */
  eurUnreliable?: boolean;
}

export interface FiledRow {
  model: string; // "303" | "130" | "349"
  year: number;
  quarter: number;
  resultPaid: number | null;
  compensarNext: number | null;
  /** Full box map as filed (e.g. { "01": 30673.4, "02": 1672.84 }). Lets a
   *  filed 130 "close" prior quarters: its cumulative boxes 01/02/06 replace
   *  summing the raw rows of those quarters. */
  casillas: Record<string, number>;
}

export interface Model303 {
  required: boolean;
  reason: string;
  deadline: string;
  ivaDevengado: number;
  ivaDeducible: number;
  resultado: number;
  casillas: Casilla[];
}

export interface Model130 {
  required: boolean;
  reason: string;
  deadline: string;
  ingresosTrim: number;
  gastosTrim: number;
  rendimientoTrim: number;
  ingresosAcum: number;
  gastosAcum: number;
  rendimiento: number;
  resultado: number;
  aIngresar: number;
  casillas: Casilla[];
}

export interface Op349 {
  taxId: string;
  country: string;
  name: string;
  clave: Clave349;
  base: number;
}

export interface Model349 {
  required: boolean;
  reason: string;
  deadline: string;
  operaciones: Op349[];
  operadores: number;
  importeTotal: number;
}

export interface DeclarationsResult {
  period: {
    year: number;
    quarter: 1 | 2 | 3 | 4;
    label: string;
    start: string;
    endExclusive: string;
  };
  profile: { activityType: string; estimacionDirecta: boolean };
  counts: { invoices: number; expenses: number };
  modelo303: Model303;
  modelo130: Model130;
  modelo349: Model349;
  /** Blocking + advisory validation issues (V-1 / V-2 / NIF checks). */
  issues: DeclarationIssue[];
  /** Legacy non-blocking caveats string list the UI already renders. */
  notes: string[];
}

export interface EngineInput {
  year: number;
  quarter: 1 | 2 | 3 | 4;
  activityType: string;
  /** All SENT invoices from Jan 1 to the end of the quarter (YTD). */
  salesYtd: SaleRow[];
  /** All expenses from Jan 1 to the end of the quarter (YTD). */
  purchasesYtd: PurchaseRow[];
  /** Filed declarations for the same year (any model). */
  filed: FiledRow[];
}

// ---- classification helper ----

interface Routed {
  territory: TerritoryClass;
}

function routeSale(s: SaleRow): Routed {
  return {
    territory: classifyTerritory(s.countryCode, s.nature, s.issueDate, {
      esNoIva: s.esNoIva,
    }),
  };
}
function routePurchase(p: PurchaseRow): Routed {
  return {
    territory: classifyTerritory(p.countryCode, p.nature, p.issueDate, {
      esNoIva: p.esNoIva,
    }),
  };
}

// ================= main =================

export function computeDeclarations(input: EngineInput): DeclarationsResult {
  const { year, quarter, activityType } = input;
  const qStart = new Date(Date.UTC(year, (quarter - 1) * 3, 1));
  const qEnd = new Date(Date.UTC(year, quarter * 3, 1));

  const inQuarter = (d: Date) => d >= qStart && d < qEnd;
  const salesQ = input.salesYtd.filter((s) => inQuarter(s.issueDate));
  const purchasesQ = input.purchasesYtd.filter((p) => inQuarter(p.issueDate));

  const estimacionDirecta =
    activityType === "profesional" || activityType === "empresarial";

  const notes: string[] = [];
  const issues: DeclarationIssue[] = [];

  // Foreign-currency rows without a stored EUR mirror would flow into the
  // boxes at face value (e.g. NOK 109 counted as €109) — block the filing.
  // YTD scope because the 130 cumulative uses the whole year.
  const unreliable =
    input.salesYtd.filter((s) => s.eurUnreliable).length +
    input.purchasesYtd.filter((p) => p.eurUnreliable).length;
  if (unreliable > 0) {
    issues.push({
      code: "fx-missing-eur",
      severity: "error",
      messageEs: `${unreliable} operación(es) en divisa sin importe EUR: añade el equivalente EUR (tipo BCE en la fecha de devengo) antes de presentar.`,
      messageEn: `${unreliable} foreign-currency row(s) with no EUR amount: add the EUR equivalent (ECB rate at the accrual date) before filing.`,
    });
  }

  if (!estimacionDirecta) {
    notes.push(
      "Tu régimen es por módulos (estimación objetiva): el pago fraccionado va en el Modelo 131, no en el 130. Aquí se calcula el 130 solo como referencia.",
    );
  }

  const m303 = compute303(salesQ, purchasesQ, input.filed, year, quarter, issues);
  const m349 = build349(salesQ, purchasesQ, year, quarter, issues);
  const m130 = compute130(
    input.salesYtd,
    input.purchasesYtd,
    salesQ,
    purchasesQ,
    input.filed,
    year,
    quarter,
    estimacionDirecta,
    issues,
  );

  reconcile349vs303(m303, m349, issues);

  return {
    period: {
      year,
      quarter,
      label: `Q${quarter} ${year}`,
      start: qStart.toISOString().slice(0, 10),
      endExclusive: qEnd.toISOString().slice(0, 10),
    },
    profile: { activityType, estimacionDirecta },
    counts: { invoices: salesQ.length, expenses: purchasesQ.length },
    modelo303: m303,
    modelo130: m130,
    modelo349: m349,
    issues,
    notes,
  };
}

// ---------------- Modelo 303 ----------------

function compute303(
  salesQ: SaleRow[],
  purchasesQ: PurchaseRow[],
  filed: FiledRow[],
  year: number,
  quarter: number,
  issues: DeclarationIssue[],
): Model303 {
  // Devengado — domestic sales, split by rate into the AEAT box pairs.
  // The régimen-general grid is printed by ASCENDING rate, NOT 21% first:
  //   4%  (superreducido) → base 01 / tipo 02 / cuota 03
  //   10% (reducido)      → base 04 / tipo 05 / cuota 06
  //   21% (general)       → base 07 / tipo 08 / cuota 09
  // Putting a 21% base in box 01 would file it as 4% (bug 303-8).
  let dom4Base = 0, dom4Cuota = 0;
  let dom10Base = 0, dom10Cuota = 0;
  let dom21Base = 0, dom21Cuota = 0;
  // Informative sale boxes.
  let base59 = 0; // intra-EU deliveries of goods & services (exempt)
  let base60 = 0; // exports (THIRD goods)
  let base120 = 0; // not-subject by localisation rules (THIRD services)

  for (const s of salesQ) {
    const { territory } = routeSale(s);
    switch (territory) {
      case "ES_IVA": {
        const r = rate(s.vatRate);
        if (r === 21) {
          dom21Base += s.netEur;
          dom21Cuota += s.vatEur;
        } else if (r === 10) {
          dom10Base += s.netEur;
          dom10Cuota += s.vatEur;
        } else if (r === 4) {
          dom4Base += s.netEur;
          dom4Cuota += s.vatEur;
        }
        // 0% domestic (exento) carries no devengado box here.
        break;
      }
      case "EU":
        // B2B intra-EU delivery (goods or services) — exempt, informative 59.
        base59 += s.netEur;
        break;
      case "THIRD":
        if (s.nature === "goods") base60 += s.netEur;
        else base120 += s.netEur;
        break;
      case "ES_NO_IVA":
        // Canarias/Ceuta/Melilla: outside the IVA zone. Goods shipped there
        // are operaciones asimiladas a exportaciones (box 60); B2B services
        // are not subject by localisation rules (box 120). Dropping them
        // entirely was the same class of bug as C-4.
        if (s.nature === "goods") base60 += s.netEur;
        else base120 += s.netEur;
        break;
    }
  }

  // Purchases. Self-assessed VAT (reverse charge / ISP) is computed on the
  // AGGREGATE base and rounded once — AEAT rounds the box, not each line
  // (per-line rounding drifts a cent: 1446.94*21% = 303.86, not the 303.85
  // you get summing rounded rows). Deducible amounts use a base weighted by
  // each row's deductible %, so mixed-% cases stay correct.
  const rate01 = ES_VAT_RATE / 100;
  let euBase = 0; // intra-EU acquisitions base (10/36)
  let euBaseDeduc = 0; // ...weighted by deductible %
  let thirdBase = 0; // THIRD-country ISP base (12)
  let thirdBaseDeduc = 0; // ...weighted by deductible %
  let interiorBase = 0; // ES domestic deductible base (part of 28)
  let interiorCuotaDeduc = 0; // ES domestic deductible VAT (real soportado × %)

  for (const p of purchasesQ) {
    // Recurring-no-invoice rows (TGSS/RETA) carry no IVA — 130 only.
    if (p.kind === "recurring_no_invoice") continue;

    const { territory } = routePurchase(p);
    const pct = clampPct(p.deductiblePct);
    switch (territory) {
      case "ES_IVA":
        interiorBase += p.netEur;
        interiorCuotaDeduc += (p.vatEur * pct) / 100;
        break;
      case "EU":
        // Reverse charge: self-assess at the Spanish rate (C-3).
        euBase += p.netEur;
        euBaseDeduc += (p.netEur * pct) / 100;
        break;
      case "THIRD":
        // Inversión del sujeto pasivo: devengado 12/13, deducible 28/29.
        thirdBase += p.netEur;
        thirdBaseDeduc += (p.netEur * pct) / 100;
        break;
      case "ES_NO_IVA":
        // Canarias/Ceuta/Melilla supplier. Services received by a mainland
        // business are subject here via ISP — same treatment as THIRD
        // (12/13 devengado, 28/29 deducible). Goods are an IMPORT: the IVA
        // is paid at customs and goes in boxes 32/33 from the DUA — that
        // can't be derived from the expense row, so flag it instead.
        if (p.nature === "service") {
          thirdBase += p.netEur;
          thirdBaseDeduc += (p.netEur * pct) / 100;
        } else {
          issues.push({
            code: "303-import-dua",
            severity: "warning",
            messageEs: `Compra de bienes a ${p.name} (Canarias/Ceuta/Melilla): es una importación — el IVA del DUA va en las casillas 32/33, añádelo a mano.`,
            messageEn: `Goods purchase from ${p.name} (Canarias/Ceuta/Melilla): that's an import — the customs (DUA) VAT goes in boxes 32/33, add it manually.`,
          });
        }
        break;
    }
  }

  dom4Base = round2(dom4Base);
  dom4Cuota = round2(dom4Cuota);
  dom10Base = round2(dom10Base);
  dom10Cuota = round2(dom10Cuota);
  dom21Base = round2(dom21Base);
  dom21Cuota = round2(dom21Cuota);
  const base10 = round2(euBase);
  const cuota11 = round2(euBase * rate01);
  const base12 = round2(thirdBase);
  const cuota13 = round2(thirdBase * rate01);
  const base28 = round2(interiorBase + thirdBase);
  const cuota29 = round2(interiorCuotaDeduc + thirdBaseDeduc * rate01);
  const base36 = base10;
  const cuota37 = round2(euBaseDeduc * rate01);
  base59 = round2(base59);
  base60 = round2(base60);
  base120 = round2(base120);

  const cuota27 = round2(
    dom4Cuota + dom10Cuota + dom21Cuota + cuota11 + cuota13,
  ); // total devengado
  const cuota45 = round2(cuota29 + cuota37); // total a deducir
  const casilla46 = round2(cuota27 - cuota45); // resultado régimen general

  // V-2: any non-zero acquisition base with a zero self-assessed cuota is an
  // impossible combination (the old cuota=0 bug).
  if (base10 > 0 && cuota11 === 0)
    issues.push(issueBaseNoCuota("10/11"));
  if (base12 > 0 && cuota13 === 0)
    issues.push(issueBaseNoCuota("12/13"));

  // a-compensar carry (303-7). Pending from the prior filed 303 of the year.
  const prior = filed
    .filter((f) => f.model === "303" && f.year === year && f.quarter < quarter)
    .sort((a, b) => b.quarter - a.quarter)[0];
  const casilla110 = round2(Math.max(0, prior?.compensarNext ?? 0));

  let casilla78 = 0;
  let casilla87 = 0;
  let casilla71 = casilla46;
  if (casilla46 >= 0) {
    casilla78 = round2(Math.min(casilla110, casilla46));
    casilla71 = round2(casilla46 - casilla78);
    casilla87 = round2(casilla110 - casilla78);
  } else {
    casilla71 = casilla46; // negative → a compensar this period
    casilla87 = round2(casilla110 - casilla46); // grows the pending balance
  }

  // The AEAT form does NOT auto-apply the pending balance, and box 78 itself
  // is read-only there: it's filled from the per-period breakdown behind the
  // PENCIL icon next to box 110. We auto-apply the maximum — tell the user
  // exactly where to type it.
  if (casilla78 > 0) {
    issues.push({
      code: "303-78-manual",
      severity: "warning",
      messageEs: `Hemos aplicado ${casilla78.toFixed(2).replace(".", ",")} € de cuotas pendientes. En el formulario, pulsa el LÁPIZ de la casilla 110 y pon ese importe como «aplicado en este periodo» (la 78 es de solo lectura). Así la 87 queda en ${casilla87.toFixed(2).replace(".", ",")} y el resultado (71) en ${casilla71.toFixed(2).replace(".", ",")}.`,
      messageEn: `We applied ${casilla78.toFixed(2)} € of pending offset. On the AEAT form, click the PENCIL next to box 110 and enter that amount as "applied in this period" (box 78 itself is read-only). Box 87 then becomes ${casilla87.toFixed(2)} and the result (71) ${casilla71.toFixed(2)}.`,
    });
  }

  if (casilla110 === 0 && !prior && quarter > 1) {
    issues.push({
      code: "303-no-prior-filed",
      severity: "warning",
      messageEs:
        "No hay un 303 presentado del trimestre anterior en el archivo: si tenías cuotas a compensar (casilla 87), añádelo para arrastrarlas.",
      messageEn:
        "No prior-quarter 303 in the filed archive: if you had amounts to offset (box 87), add it so they carry over.",
    });
  }

  const casillas: Casilla[] = [
    c("01", "Base imponible 4%", "Taxable base 4%", dom4Base),
    c("03", "Cuota devengada 4%", "Output VAT 4%", dom4Cuota),
    c("04", "Base imponible 10%", "Taxable base 10%", dom10Base),
    c("06", "Cuota devengada 10%", "Output VAT 10%", dom10Cuota),
    c("07", "Base imponible 21%", "Taxable base 21%", dom21Base),
    c("09", "Cuota devengada 21%", "Output VAT 21%", dom21Cuota),
    c("10", "Base adquisiciones intracomunitarias", "Intra-EU acquisitions base", base10),
    c("11", "Cuota adquisiciones intracomunitarias", "Intra-EU acquisitions VAT", cuota11),
    c("12", "Base otras op. con inversión del sujeto pasivo", "Other reverse-charge base (non-EU)", base12),
    c("13", "Cuota otras op. con inversión del sujeto pasivo", "Other reverse-charge VAT (non-EU)", cuota13),
    c("27", "Total cuota devengada", "Total output VAT", cuota27),
    c("28", "Base op. interiores corrientes deducibles", "Deductible domestic + ISP base", base28),
    c("29", "Cuota deducible op. interiores", "Deductible domestic + ISP VAT", cuota29),
    c("36", "Base adq. intracom. deducibles", "Deductible intra-EU base", base36),
    c("37", "Cuota deducible adq. intracom.", "Deductible intra-EU VAT", cuota37),
    c("45", "Total a deducir", "Total deductible VAT", cuota45),
    c("46", "Resultado régimen general", "General-regime result", casilla46),
    c("59", "Entregas intracom. de bienes y servicios", "Intra-EU deliveries (goods & services)", base59),
    c("60", "Exportaciones y op. asimiladas", "Exports and similar", base60),
    c("110", "Cuotas a compensar de periodos anteriores", "Prior-period amounts to offset", casilla110),
    c("78", "Cuotas a compensar aplicadas", "Applied offset", casilla78),
    c("120", "Op. no sujetas por reglas de localización", "Not subject by localisation rules", base120),
    c("87", "Cuotas a compensar en periodos posteriores", "Carried offset to future periods", casilla87),
    c("71", "Resultado de la liquidación", "Return result", casilla71),
  ];

  return {
    required: true,
    reason: "El 303 es obligatorio cada trimestre aunque no haya actividad.",
    deadline: deadline(year, quarter),
    ivaDevengado: cuota27,
    ivaDeducible: cuota45,
    resultado: casilla71,
    casillas,
  };
}

// ---------------- Modelo 349 ----------------

function build349(
  salesQ: SaleRow[],
  purchasesQ: PurchaseRow[],
  year: number,
  quarter: number,
  issues: DeclarationIssue[],
): Model349 {
  // key = `${clave}:${nif}` — aggregate by NIF per clave (349-2).
  const map = new Map<string, Op349>();
  const nameByNif = new Map<string, Set<string>>();

  const add = (clave: Clave349, taxId: string, country: string, name: string, base: number) => {
    const nif = taxId.toUpperCase();
    const key = `${clave}:${nif}`;
    const prev = map.get(key);
    if (prev) prev.base = round2(prev.base + base);
    else map.set(key, { taxId: nif, country, name, clave, base: round2(base) });
    // Track distinct names per NIF to catch merge mistakes (349-2).
    if (!nameByNif.has(nif)) nameByNif.set(nif, new Set());
    nameByNif.get(nif)!.add(name.trim().toLowerCase());
  };

  for (const s of salesQ) {
    const { territory } = routeSale(s);
    if (territory !== "EU") continue;
    const nif = (s.taxId || "").toUpperCase();
    if (!nif) {
      // EU sale without a VAT number is likely B2C (OSS / Modelo 369), not 349.
      issues.push({
        code: "349-b2c-sale",
        severity: "warning",
        messageEs: `Venta intracom. a ${s.name} sin NIF-IVA: si es B2C va por OSS (Modelo 369), no en el 349.`,
        messageEn: `Intra-EU sale to ${s.name} without a VAT id: if B2C it goes via OSS (Modelo 369), not the 349.`,
      });
      continue;
    }
    // sale + goods → E, sale + service → S.
    add(s.nature === "goods" ? "E" : "S", nif, (s.countryCode || "").toUpperCase(), s.name, s.netEur);
  }

  for (const p of purchasesQ) {
    if (p.kind === "recurring_no_invoice") continue;
    const { territory } = routePurchase(p);
    if (territory !== "EU") continue;
    const nif = (p.taxId || "").toUpperCase();
    if (!nif) {
      issues.push({
        code: "349-purchase-no-nif",
        severity: "error",
        messageEs: `Compra intracom. a ${p.name} sin NIF-IVA: obligatorio para el 349 y el reverse charge.`,
        messageEn: `Intra-EU purchase from ${p.name} without a VAT id: required for the 349 and reverse charge.`,
      });
      continue;
    }
    // purchase + goods → A, purchase + service → I.
    add(p.nature === "goods" ? "A" : "I", nif, (p.countryCode || "").toUpperCase(), p.name, p.netEur);
  }

  const operaciones = [...map.values()].sort((a, b) => b.base - a.base);

  // NIF-IVA checksum validation (349-3).
  for (const op of operaciones) {
    const r = validateNifIva(op.taxId);
    if (!r.valid) {
      issues.push({
        code: "349-nif-checksum",
        severity: "error",
        messageEs: `NIF-IVA inválido para ${op.name}: ${op.taxId} (${r.reason ?? "checksum"}).`,
        messageEn: `Invalid VAT id for ${op.name}: ${op.taxId} (${r.reason ?? "checksum"}).`,
      });
    }
  }
  // Same NIF, different names → likely a merge/typo error (349-2).
  for (const [nif, names] of nameByNif) {
    if (names.size > 1) {
      issues.push({
        code: "349-nif-name-mismatch",
        severity: "warning",
        messageEs: `El NIF ${nif} aparece con varios nombres distintos: revisa posibles duplicados.`,
        messageEn: `VAT id ${nif} appears under several different names: check for duplicates.`,
      });
    }
  }

  const importeTotal = round2(operaciones.reduce((a, o) => a + o.base, 0));

  // Quarterly filing is only allowed while intra-EU deliveries (E+S) stay
  // under €50,000 in the current and the four preceding quarters; above that
  // the 349 turns MONTHLY. We only see the current quarter here — warn.
  const deliveriesTotal = round2(
    operaciones.filter((o) => o.clave === "E" || o.clave === "S").reduce((a, o) => a + o.base, 0),
  );
  if (deliveriesTotal > 50_000) {
    issues.push({
      code: "349-monthly-threshold",
      severity: "warning",
      messageEs:
        "Las entregas intracomunitarias superan 50.000 € en el trimestre: el 349 pasa a ser MENSUAL. Consulta con tu gestor la periodicidad.",
      messageEn:
        "Intra-EU deliveries exceed €50,000 this quarter: the 349 becomes MONTHLY. Check the filing frequency with your gestor.",
    });
  }

  return {
    required: operaciones.length > 0,
    reason:
      operaciones.length > 0
        ? "Hay operaciones intracomunitarias este trimestre."
        : "Sin operaciones intracomunitarias — no procede.",
    deadline: deadline(year, quarter),
    operaciones,
    operadores: operaciones.length,
    importeTotal,
  };
}

// ---------------- Modelo 130 ----------------

function compute130(
  salesYtd: SaleRow[],
  purchasesYtd: PurchaseRow[],
  salesQ: SaleRow[],
  purchasesQ: PurchaseRow[],
  filed: FiledRow[],
  year: number,
  quarter: number,
  estimacionDirecta: boolean,
  issues: DeclarationIssue[],
): Model130 {
  const irpfGasto = (p: PurchaseRow) => (p.deductibleForIrpf ? p.netEur : 0);

  const ingresosTrim = round2(sum(salesQ.map((s) => s.netEur)));
  const gastosTrim = round2(sum(purchasesQ.map(irpfGasto)));
  const rendimientoTrim = round2(ingresosTrim - gastosTrim);

  // Prior-quarter filed 130s of this year, newest first.
  const priorFiled = filed
    .filter((f) => f.model === "130" && f.year === year && f.quarter < quarter)
    .sort((a, b) => b.quarter - a.quarter);

  // Box 05 (De los trimestres anteriores) — READ from the filed archive,
  // never recomputed (130-2). Sum of box-07 actually paid in prior quarters.
  const box05 = round2(sum(priorFiled.map((f) => Math.max(0, f.resultPaid ?? 0))));

  // Boxes 01/02/06 are cumulative from Jan 1 (130-1). A filed 130 whose own
  // 01/02 boxes are known "closes" everything up to its quarter: we take its
  // cumulative figures and add ONLY the rows dated after that quarter. So a
  // mid-year migrant needs no prior rows, and a filed period is locked to what
  // was actually declared rather than re-summed from the lists.
  const hasBox = (f: FiledRow, k: string) =>
    f.casillas != null && typeof f.casillas[k] === "number";
  // Only "close" prior quarters from a filed 130 when we DON'T hold their rows
  // (mid-year migrant). When the prior rows exist they are authoritative:
  // using them avoids double-rounding drift against the filed cumulative and
  // keeps retenciones (box 06) sourced from the actual invoices — a filed
  // box 06 of e.g. 0.01 must not be added on top of the invoice withholdings.
  const qStart = new Date(Date.UTC(year, (quarter - 1) * 3, 1));
  const hasPriorRows =
    salesYtd.some((s) => s.issueDate < qStart) ||
    purchasesYtd.some((p) => p.issueDate < qStart);
  const closer = hasPriorRows
    ? undefined
    : priorFiled.find((f) => hasBox(f, "01") && hasBox(f, "02"));
  const boundaryQuarter = closer ? closer.quarter : 0; // 0 → from Jan 1
  const boundary = new Date(Date.UTC(year, boundaryQuarter * 3, 1));
  const afterBoundary = (d: Date) => d >= boundary;

  const priorIngresos = closer ? closer.casillas["01"] ?? 0 : 0;
  const priorGastos = closer ? closer.casillas["02"] ?? 0 : 0;
  const priorRet = closer ? closer.casillas["06"] ?? 0 : 0;

  const ingresosAcum = round2(
    priorIngresos + sum(salesYtd.filter((s) => afterBoundary(s.issueDate)).map((s) => s.netEur)),
  );
  const gastosAcum = round2(
    priorGastos + sum(purchasesYtd.filter((p) => afterBoundary(p.issueDate)).map(irpfGasto)),
  );
  const rendimiento = round2(ingresosAcum - gastosAcum);
  const box04 = round2(0.2 * Math.max(0, rendimiento));

  // Box 06 (Retenciones e ingresos a cuenta) — cumulative withholdings.
  const box06 = round2(
    priorRet + sum(salesYtd.filter((s) => afterBoundary(s.issueDate)).map((s) => s.irpfEur)),
  );

  if (quarter > 1 && priorFiled.length < quarter - 1) {
    issues.push({
      code: "130-missing-filed",
      severity: "warning",
      messageEs:
        "Faltan Modelos 130 presentados de trimestres anteriores: las casillas 05 y el acumulado pueden estar incompletos. Añádelos en el archivo de declaraciones.",
      messageEn:
        "Some prior-quarter Modelo 130 filings are missing: box 05 and the cumulative figures may be incomplete. Add them in the filed-declarations archive.",
    });
  } else if (closer && (boundaryQuarter as number) < quarter - 1 && !hasBox(priorFiled[0], "01")) {
    // A later filed quarter exists but without cumulative boxes — we closed at
    // an earlier one and summed rows since; flag that we couldn't use it.
    issues.push({
      code: "130-filed-no-cumulative",
      severity: "warning",
      messageEs:
        "Una 130 presentada no trae las casillas 01/02: el acumulado se ha completado con las listas. Revisa que estén cargadas.",
      messageEn:
        "A filed 130 has no boxes 01/02: the cumulative was completed from the lists. Check they are loaded.",
    });
  }

  const box07 = round2(box04 - box05 - box06);

  // Official total section (AEAT compares the boxes, not just the result):
  //   12 = 07 + 11 (no agricultural section here → 12 = 07)
  //   13 = minoración art. 110.3.c) LIRPF — only when prior-year net income
  //        ≤ €12,000; prior-year data isn't modelled, so 0.
  //   14 = 12 − 13
  //   15 = negative results of PRIOR quarters of the same year, not yet
  //        applied — deductible only against a positive 14.
  //   16 = deducción por vivienda habitual (2%, capped) — not modelled, 0.
  //   17 = 14 − 15 − 16 ;  19 = 17 (18 = complementarias, not modelled).
  const box12 = box07;
  const box13 = 0;
  const box14 = round2(box12 - box13);
  // Unapplied negative balance: |sum of negative prior results| minus what
  // prior filed 130s already applied in their own box 15.
  const negPrior = Math.abs(sum(priorFiled.map((f) => Math.min(0, f.resultPaid ?? 0))));
  const negApplied = sum(priorFiled.map((f) => Math.max(0, f.casillas?.["15"] ?? 0)));
  const negAvailable = round2(Math.max(0, negPrior - negApplied));
  const box15 = round2(Math.min(negAvailable, Math.max(0, box14)));
  const box16 = 0;
  const box17 = round2(box14 - box15 - box16);
  const box19 = box17;

  const casillas: Casilla[] = [
    c("01", "Ingresos computables (acumulado)", "Cumulative income", ingresosAcum),
    c("02", "Gastos deducibles (acumulado)", "Cumulative deductible expenses", gastosAcum),
    c("03", "Rendimiento (01 − 02)", "Net profit (01 − 02)", rendimiento),
    c("04", "20% del rendimiento", "20% of profit", box04),
    c("05", "Pagos fraccionados de trimestres anteriores", "Prior-quarter fractioned payments", box05),
    c("06", "Retenciones e ingresos a cuenta", "Withholdings & payments on account", box06),
    c("07", "Pago fraccionado previo (04 − 05 − 06)", "Prior fractioned payment (04 − 05 − 06)", box07),
    c("12", "Suma de resultados (07 + 11)", "Sum of results (07 + 11)", box12),
    c("13", "Minoración art. 110.3.c)", "Reduction art. 110.3.c)", box13),
    c("14", "Diferencia (12 − 13)", "Difference (12 − 13)", box14),
    c("15", "Resultados negativos de trimestres anteriores", "Prior-quarter negative results applied", box15),
    c("16", "Deducción vivienda habitual", "Main-home deduction", box16),
    c("17", "Total (14 − 15 − 16)", "Total (14 − 15 − 16)", box17),
    c("19", "Resultado de la declaración", "Return result", box19),
  ];

  return {
    required: estimacionDirecta,
    reason: estimacionDirecta
      ? "Autónomo en estimación directa: pago fraccionado trimestral del IRPF."
      : "En módulos se presenta el 131 en lugar del 130.",
    deadline: deadline(year, quarter),
    ingresosTrim,
    gastosTrim,
    rendimientoTrim,
    ingresosAcum,
    gastosAcum,
    rendimiento,
    resultado: box19,
    aIngresar: box17,
    casillas,
  };
}

// ---------------- validation ----------------

/** V-1: the 349 totals must reconcile with the 303 informative boxes. This is
 *  the invariant that would have caught the US supplier leaking into box 10. */
function reconcile349vs303(
  m303: Model303,
  m349: Model349,
  issues: DeclarationIssue[],
) {
  const box = (code: string) => m303.casillas.find((x) => x.code === code)?.value ?? 0;
  const claveSum = (claves: Clave349[]) =>
    round2(
      m349.operaciones
        .filter((o) => claves.includes(o.clave))
        .reduce((a, o) => a + o.base, 0),
    );

  const acquisitions = claveSum(["A", "I"]); // purchases
  if (Math.abs(acquisitions - box("10")) > 0.01) {
    issues.push({
      code: "V1-349-303-acq",
      severity: "error",
      messageEs: `Descuadre 349↔303: adquisiciones 349 (${acquisitions}) ≠ casilla 10 (${box("10")}). Suele indicar un proveedor de fuera de la UE colado en intracom.`,
      messageEn: `349↔303 mismatch: 349 acquisitions (${acquisitions}) ≠ box 10 (${box("10")}). Usually a non-EU supplier leaking into the intra-EU box.`,
    });
  }

  const deliveries = claveSum(["E", "S"]); // sales
  if (Math.abs(deliveries - box("59")) > 0.01) {
    issues.push({
      code: "V1-349-303-del",
      severity: "error",
      messageEs: `Descuadre 349↔303: entregas 349 (${deliveries}) ≠ casilla 59 (${box("59")}).`,
      messageEn: `349↔303 mismatch: 349 deliveries (${deliveries}) ≠ box 59 (${box("59")}).`,
    });
  }
}

function issueBaseNoCuota(boxes: string): DeclarationIssue {
  return {
    code: "V2-base-no-cuota",
    severity: "error",
    messageEs: `Casilla ${boxes}: hay base pero la cuota es 0 — combinación imposible en reverse charge.`,
    messageEn: `Box ${boxes}: base present but VAT is 0 — impossible under reverse charge.`,
  };
}

// ---- money helpers ----

function sum(xs: number[]): number {
  return xs.reduce((a, b) => a + b, 0);
}
function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}
function rate(v: number): number {
  return Math.round(v);
}
function clampPct(n: number): number {
  if (!Number.isFinite(n)) return 100;
  return Math.min(100, Math.max(0, n));
}
function c(code: string, labelEs: string, labelEn: string, value: number): Casilla {
  return { code, labelEs, labelEn, value: round2(value) };
}

/** Filing deadline: Q1→Apr 20, Q2→Jul 20, Q3→Oct 20, Q4→Jan 30 next year. */
function deadline(year: number, quarter: number): string {
  if (quarter === 4) return `${year + 1}-01-30`;
  const month = ["04", "07", "10"][quarter - 1];
  return `${year}-${month}-20`;
}
