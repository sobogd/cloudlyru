import { Injectable, Logger } from "@nestjs/common";
import { Prisma, type Invoice, type VerifactuRegistry } from "@prisma/client";

import { PrismaService } from "../../../prisma/prisma.service";
import {
  computeHuella,
  deriveTipoFactura,
  formatAmountForHash,
  formatDateForHash,
  formatTimestampForHash,
} from "./hash-chain";
import { buildQrUrl, type VerifactuEnv } from "./qr-url";
import { env } from "../../../config/env";

export type VerifactuMode = "disabled" | "local" | "submit";

/** Читает активную конфигурацию VeriFactu из конфига процесса: один переключатель
 *  (disabled → local → submit) управляет всем потоком — записями, QR и отправкой в AEAT.
 *
 *  Раньше значения разбирались из `process.env` прямо здесь, с ручной проверкой строк.
 *  Теперь их валидирует схема окружения облака (`src/config/env.ts`), поэтому типы уже
 *  сужены, а опечатка в значении роняет старт, а не молча выключает отправку. */
export function getVerifactuConfig(): {
  mode: VerifactuMode;
  env: VerifactuEnv;
} {
  return { mode: env.VERIFACTU_MODE, env: env.VERIFACTU_ENV };
}

/** Decides whether Verifactu artefacts (registry rows, QR, PDF marker)
 *  should be produced for a given invoice. Today this just reads env —
 *  in the future we may opt-in per company. */
export function verifactuEnabled(): boolean {
  return getVerifactuConfig().mode !== "disabled";
}

@Injectable()
export class VerifactuService {
  private readonly logger = new Logger(VerifactuService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** Create the VerifactuRegistry row for a freshly-inserted Invoice.
   *  MUST be called inside the same Prisma transaction that created the
   *  Invoice — otherwise a power failure between the two writes would
   *  break the chain (an unregistered invoice that no future record can
   *  reference back to).
   *
   *  The previous-hash lookup uses `FOR UPDATE` semantics implicit in
   *  Prisma's serialisable transaction default: if two concurrent
   *  invoices race for the same sequenceNumber, one wins the unique
   *  constraint and the other rolls back its whole transaction (including
   *  the Invoice row), which is exactly what we want — no orphans, no
   *  forked chain. */
  async createInsideTx(
    tx: Prisma.TransactionClient,
    invoice: Invoice,
    issuerNif: string,
  ): Promise<VerifactuRegistry> {
    const cfg = getVerifactuConfig();
    // Caller has already uppercased + validated the NIF; we trust it
    // here so the hash input, XML and QR all agree byte-for-byte.
    const nif = issuerNif;
    if (!nif) {
      throw new Error(
        "Cannot create Verifactu registry: emitter NIF is empty (set Company.taxId).",
      );
    }

    const previous = await tx.verifactuRegistry.findFirst({
      where: { companyId: invoice.companyId },
      orderBy: { sequenceNumber: "desc" },
      select: { sequenceNumber: true, currentHash: true },
    });
    const sequenceNumber = (previous?.sequenceNumber ?? 0) + 1;
    const previousHash = previous?.currentHash ?? "";

    // Number is allocated atomically by VerifactuSubmitService *before*
    // it calls into here (in the same Prisma txn), so it's guaranteed
    // non-null at this point. We assert rather than fall back to a
    // placeholder because a missing number would silently produce a
    // Huella that disagrees with the XML we POST to AEAT.
    if (!invoice.number) {
      throw new Error(
        `Invoice ${invoice.id} has no allocated number — submit must allocate before createInsideTx`,
      );
    }
    const invoiceNumber = invoice.number;
    const fechaExpedicion = formatDateForHash(invoice.issueDate);
    const signedAt = new Date();
    const fechaHora = formatTimestampForHash(signedAt);
    // VeriFactu reports EUR. Use the EUR mirror; fall back to the plain
    // amount for pre-feature rows (null mirror), which were all EUR.
    const cuotaTotal = formatAmountForHash(invoice.vatAmountEur ?? invoice.vatAmount);
    const importeTotal = formatAmountForHash(
      invoice.totalAmountEur ?? invoice.totalAmount,
    );

    // Same type MUST feed the hash and the XML (see deriveTipoFactura).
    const tipoFactura = deriveTipoFactura(invoice.contactSnapshot);

    const { input, hash } = computeHuella({
      idEmisorFactura: nif,
      numSerieFactura: invoiceNumber,
      fechaExpedicionFactura: fechaExpedicion,
      tipoFactura,
      cuotaTotal,
      importeTotal,
      huella: previousHash,
      fechaHoraHusoGenRegistro: fechaHora,
    });

    const qrUrl = buildQrUrl(cfg.env, {
      nif,
      numSerie: invoiceNumber,
      fecha: fechaExpedicion,
      importe: importeTotal,
    });

    return tx.verifactuRegistry.create({
      data: {
        companyId: invoice.companyId,
        invoiceId: invoice.id,
        sequenceNumber,
        previousHash,
        currentHash: hash,
        hashInput: input,
        tipoFactura,
        qrUrl,
        signedAt,
        // In "submit" mode the cron will push this row to AEAT and
        // flip the status; in "local" mode it stays PENDING forever.
        aeatStatus: cfg.mode === "submit" ? "PENDING" : "PENDING",
      },
    });
  }
}
