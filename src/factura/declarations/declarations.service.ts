import { Injectable } from "@nestjs/common";
import { PrismaService } from "../../prisma/prisma.service";
import {
  computeDeclarations,
  type DeclarationsResult,
  type FiledRow,
  type PurchaseRow,
  type SaleRow,
} from "./declarations.engine";
import type { OperationNature } from "../tax/territory";

export type { DeclarationsResult } from "./declarations.engine";

type ContactSnapshot = {
  name?: string;
  taxId?: string | null;
  countryCode?: string | null;
  isEu?: boolean;
  nature?: string;
  esNoIva?: boolean;
};

/** Thin DB adapter: fetch the rows a quarter needs and hand them to the pure
 *  engine (declarations.engine.ts), which owns all the tax logic. */
@Injectable()
export class DeclarationsService {
  constructor(private readonly prisma: PrismaService) {}

  async compute(
    companyId: string,
    year: number,
    quarter: 1 | 2 | 3 | 4,
  ): Promise<DeclarationsResult> {
    const yearStart = new Date(Date.UTC(year, 0, 1));
    const qEnd = new Date(Date.UTC(year, quarter * 3, 1)); // exclusive

    const [company, invoices, expenses, filed] = await Promise.all([
      this.prisma.company.findUnique({
        where: { id: companyId },
        select: { activityType: true },
      }),
      // Issued invoices only (SENT) — drafts aren't real fiscal events.
      // Annulled invoices (annulledAt != null) are excluded: the AEAT
      // anulación cancels the operation, so it must not enter the tax base
      // of Modelos 303/130/349. Their ALTA record stays in the VeriFactu
      // chain, but the declarations engine skips them.
      this.prisma.invoice.findMany({
        where: {
          companyId,
          status: "SENT",
          annulledAt: null,
          issueDate: { gte: yearStart, lt: qEnd },
        },
        select: {
          issueDate: true,
          nature: true,
          currency: true,
          vatRate: true,
          netAmount: true,
          vatAmount: true,
          irpfAmount: true,
          netAmountEur: true,
          vatAmountEur: true,
          contactSnapshot: true,
        },
      }),
      this.prisma.expense.findMany({
        where: { companyId, issueDate: { gte: yearStart, lt: qEnd } },
        select: {
          issueDate: true,
          nature: true,
          kind: true,
          currency: true,
          netAmount: true,
          vatAmount: true,
          netAmountEur: true,
          vatAmountEur: true,
          deductibleVatPct: true,
          deductibleForIrpf: true,
          supplierName: true,
          supplierTaxId: true,
          supplierCountryCode: true,
          supplierEsNoIva: true,
        },
      }),
      this.prisma.filedDeclaration.findMany({
        where: { companyId, year },
        select: {
          model: true,
          year: true,
          quarter: true,
          resultPaid: true,
          compensarNext: true,
          casillas: true,
        },
      }),
    ]);

    const activityType = company?.activityType ?? "profesional";

    const salesYtd: SaleRow[] = invoices.map((i) => {
      const s = (i.contactSnapshot ?? {}) as ContactSnapshot;
      return {
        issueDate: i.issueDate,
        countryCode: s.countryCode ?? null,
        taxId: s.taxId ?? null,
        name: s.name ?? s.taxId ?? "—",
        esNoIva: s.esNoIva === true,
        // Prefer the frozen snapshot nature (always set at issue time) and
        // fall back to the column, so older create paths stay correct.
        nature: nature(s.nature ?? i.nature),
        vatRate: num(i.vatRate),
        netEur: eur(i.netAmountEur, i.netAmount),
        vatEur: eur(i.vatAmountEur, i.vatAmount),
        irpfEur: num(i.irpfAmount),
        // Foreign currency with no EUR mirror → the fallback above used the
        // face value; the engine raises a blocking issue.
        eurUnreliable: i.currency !== "EUR" && i.netAmountEur == null,
      };
    });

    const purchasesYtd: PurchaseRow[] = expenses.map((e) => ({
      issueDate: e.issueDate,
      countryCode: e.supplierCountryCode ?? null,
      taxId: e.supplierTaxId ?? null,
      name: e.supplierName,
      esNoIva: e.supplierEsNoIva === true,
      nature: nature(e.nature),
      kind: e.kind === "recurring_no_invoice" ? "recurring_no_invoice" : "invoice",
      netEur: eur(e.netAmountEur, e.netAmount),
      vatEur: eur(e.vatAmountEur, e.vatAmount),
      deductiblePct: num(e.deductibleVatPct),
      deductibleForIrpf: e.deductibleForIrpf !== false,
      eurUnreliable: e.currency !== "EUR" && e.netAmountEur == null,
    }));

    const filedRows: FiledRow[] = filed.map((f) => ({
      model: f.model,
      year: f.year,
      quarter: f.quarter,
      resultPaid: f.resultPaid == null ? null : num(f.resultPaid),
      compensarNext: f.compensarNext == null ? null : num(f.compensarNext),
      casillas: toNumberMap(f.casillas),
    }));

    return computeDeclarations({
      year,
      quarter,
      activityType,
      salesYtd,
      purchasesYtd,
      filed: filedRows,
    });
  }
}

// ---- decimal helpers ----

type Decimalish = { toString(): string } | number | null;

function num(v: Decimalish): number {
  if (v == null) return 0;
  const n = typeof v === "number" ? v : Number(v.toString());
  return Number.isFinite(n) ? n : 0;
}
/** EUR base — prefer the *Eur mirror, fall back to the plain amount (legacy
 *  EUR rows had no mirror), the same rule VeriFactu uses. */
function eur(mirror: Decimalish, plain: Decimalish): number {
  return mirror != null ? num(mirror) : num(plain);
}
function nature(v: string | null | undefined): OperationNature {
  return v === "goods" ? "goods" : "service";
}
/** Coerce a stored casillas JSON ({ "01": 30673.4, … }) to a number map,
 *  dropping any non-numeric entries. */
function toNumberMap(v: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (v && typeof v === "object") {
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      const n = typeof val === "number" ? val : Number(val);
      if (Number.isFinite(n)) out[k] = n;
    }
  }
  return out;
}
