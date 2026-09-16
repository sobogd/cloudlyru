import crypto from "node:crypto";
import { Injectable, Logger } from "@nestjs/common";
import type { Invoice, Prisma, VerifactuRegistry } from "@prisma/client";

import { PrismaService } from "../../../prisma/prisma.service";
import { InvoiceEventsService } from "../invoice-events.service";
import { InvoicesService } from "../invoices.service";
import { submitToAeat, type AeatSubmitResult } from "./aeat-client";
import { loadVerifactuCertForCompany, type VerifactuCert } from "./cert-reader";
import {
  deriveTipoFactura,
  formatDateForHash,
  formatTimestampForHash,
} from "./hash-chain";
import { getVerifactuConfig, VerifactuService } from "./verifactu.service";
import {
  buildSoapEnvelope,
  deriveDesglose,
  type DestinatarioInput,
  type RegistroAltaInput,
  type SistemaInformaticoInput,
} from "./xml-builder";
import { env } from "../../../config/env";

/** Identifies our software in the SistemaInformatico block. Same value
 *  on every record / every install of iq-factura — the per-install
 *  variation goes into NumeroInstalacion (Company.id).
 *
 *  IdSistemaInformatico is a 2-char product code chosen by the
 *  developer (AEAT does not assign it). It must match the value
 *  declared in the Declaración Responsable published on the website.
 *  "IF" = iq-factura. */
const SOFTWARE = {
  developerNombreRazon: "Bogdan Sokolov",
  developerNif: "Z1894474S",
  nombreSistemaInformatico: "iq-factura",
  idSistemaInformatico: "IF",
  version: "1.0.0",
  soloVerifactu: "S" as const,
  multiOT: "S" as const,
  indicadorMultiplesOT: "N" as const,
};

type SubmitOk = {
  ok: true;
  invoice: Invoice;
  registry: VerifactuRegistry;
  csv: string | null;
  /** AEAT may accept with warnings (estadoEnvio = ParcialmenteCorrecto,
   *  line state = AceptadoConErrores). Surfaced so the dashboard can
   *  show them as a non-blocking info banner. */
  warnings: { code: number | null; description: string | null }[];
};

type SubmitErr = {
  ok: false;
  kind: "aeat_rejected" | "soap_fault" | "http_error" | "network_error" | "parse_error";
  message: string;
  /** AEAT business code (1xxx for record-level rejections) when
   *  available; null for transport / schema faults. */
  code: number | null;
  /** Full SOAP / Fault XML so the dashboard modal can show everything. */
  rawResponse?: string;
};

/** Synchronous submission service — replaces the previous cron sweep.
 *  Called from the controller's POST /invoices/:id/submit endpoint.
 *
 *  Flow:
 *   1. Open a short transaction → ask VerifactuService to create the
 *      registry row (locks the chain, freezes Huella with timestamp =
 *      now). Commit.
 *   2. Submit the SOAP envelope (HTTP, outside any DB txn so a slow
 *      AEAT does not hold connections).
 *   3. On success: update registry status + invoice.status = SENT in
 *      a new txn, re-render the PDF so it carries the QR.
 *   4. On failure: DELETE the registry row so the next invoice's
 *      RegistroAnterior points at the previous accepted record. The
 *      sequenceNumber assigned in step 1 becomes a gap — that is
 *      acceptable for VeriFactu (the chain is contiguous on AEAT's
 *      side, gaps live only on the issuer's side). */
@Injectable()
export class VerifactuSubmitService {
  private readonly logger = new Logger(VerifactuSubmitService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly invoices: InvoicesService,
    private readonly verifactu: VerifactuService,
    private readonly events: InvoiceEventsService,
  ) {}

  /** Per-company serialization via Postgres advisory lock. Why:
   *
   *  The chain-creation + AEAT-call + finalize sequence can't safely
   *  overlap for the same company. If submit A creates registry seq 5,
   *  submit B reads it as its previousHash for seq 6, A fails AEAT and
   *  the rollback deletes seq 5, then seq 6's RegistroAnterior points at
   *  a row AEAT never saw → AEAT rejects B with a chain-break error.
   *
   *  An in-process Map<companyId, Promise> only protects a single Node
   *  worker. The moment we scale to two pm2 instances or two pods, the
   *  in-memory mutex doesn't see each other and the race is back.
   *
   *  `pg_advisory_xact_lock` takes a session-scoped lock that auto-
   *  releases on transaction end, is enforced cluster-wide by Postgres,
   *  and contends only across submits of the same company. We derive the
   *  BIGINT key by hashing the CUID — a 64-bit truncation of SHA-256 is
   *  ample for the keyspace (collisions across companies are tolerable —
   *  worst case is two unrelated submits briefly serialise). */
  private async withCompanyLock<T>(
    companyId: string,
    fn: () => Promise<T>,
  ): Promise<T> {
    const key = lockKeyForCompany(companyId);
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${key})`;
      return fn();
    }, {
      // AEAT round-trip can hit 30s; the lock txn must outlive it. We
      // pad to 60s so a transient slowness doesn't abort the whole
      // submit half-way through.
      timeout: 60_000,
      maxWait: 5_000,
    });
  }

  async submit(invoiceId: string): Promise<SubmitOk | SubmitErr> {
    const cfg = getVerifactuConfig();
    if (cfg.mode === "disabled") {
      return {
        ok: false,
        kind: "aeat_rejected",
        message: "VERIFACTU_MODE=disabled — set to 'submit' to send to AEAT",
        code: null,
      };
    }

    const loaded = await this.prisma.invoice.findUnique({
      where: { id: invoiceId },
      include: { lines: true },
    });
    if (!loaded) {
      return { ok: false, kind: "aeat_rejected", message: "Invoice not found", code: null };
    }
    // Re-bind to a `let` after the null guard so the in-txn closure
    // can swap in the post-allocation copy without TS losing the
    // non-null narrowing.
    let invoice = loaded;

    const emitter =
      (invoice.emitterSnapshot as {
        legalName?: string | null;
        name?: string;
        taxId?: string | null;
      }) ?? {};
    // Per-tenant signing cert. Every company signs with the cert of
    // the obligado tributario named on the invoice — no shared service
    // cert, no env fallback. If the company hasn't uploaded one, we
    // refuse the submit rather than silently signing with someone
    // else's identity.
    const certCompany = await this.prisma.company.findUnique({
      where: { id: invoice.companyId },
      select: {
        verifactuCertCipher: true,
        verifactuCertNonce: true,
        verifactuCertTag: true,
        verifactuCertExpiry: true,
        verifactuCertNif: true,
        invoiceNumberOffset: true,
      },
    });
    if (
      !certCompany?.verifactuCertCipher ||
      !certCompany.verifactuCertNonce ||
      !certCompany.verifactuCertTag
    ) {
      return {
        ok: false,
        kind: "aeat_rejected",
        message:
          "No signing certificate on file for this company. Upload your FNMT .p12 in Settings → Verifactu certificate.",
        code: null,
      };
    }
    if (
      certCompany.verifactuCertExpiry &&
      certCompany.verifactuCertExpiry.getTime() < Date.now()
    ) {
      return {
        ok: false,
        kind: "aeat_rejected",
        message: `The company's signing certificate expired on ${certCompany.verifactuCertExpiry
          .toISOString()
          .slice(0, 10)}. Upload a fresh cert in Settings.`,
        code: null,
      };
    }
    const cert: VerifactuCert = loadVerifactuCertForCompany({
      companyId: invoice.companyId,
      cipher: Buffer.from(certCompany.verifactuCertCipher),
      nonce: Buffer.from(certCompany.verifactuCertNonce),
      tag: Buffer.from(certCompany.verifactuCertTag),
    });

    // NIF is uppercased for every downstream use — the hash input, the
    // XML payload and the QR all need to agree, and AEAT lookups are
    // case-sensitive on NIF. The cert upload already validates NIF
    // case-insensitively, so user-entered "z1894474s" still works.
    const issuerNif = (emitter.taxId || "").trim().toUpperCase();
    if (!issuerNif) {
      return {
        ok: false,
        kind: "aeat_rejected",
        message: "Emitter NIF is empty — set Company.taxId in Settings",
        code: null,
      };
    }

    // Per-company serialization: only one submit at a time for a given
    // company so the chain create+submit+finalize is atomic. See the
    // companyMutex docstring above for why this matters.
    return this.withCompanyLock(invoice.companyId, async () => {

    // Idempotency check inside the lock. The controller already
    // rejects re-submits with status=SENT, but there's a TOCTOU
    // window between that check and acquiring the per-company lock:
    // two concurrent requests can both pass the controller check,
    // then serialize here. The first one flips status to SENT; the
    // second must observe that and bail with the existing result
    // instead of allocating a fresh serial + sending a duplicate
    // record to AEAT.
    const fresh = await this.prisma.invoice.findUnique({
      where: { id: invoice.id },
      include: { lines: true },
    });
    if (fresh?.status === "SENT") {
      const existingRegistry = await this.prisma.verifactuRegistry.findFirst({
        where: { invoiceId: invoice.id },
        orderBy: { signedAt: "desc" },
      });
      if (existingRegistry) {
        const csv =
          (existingRegistry.aeatResponseRaw as { csv?: string | null })?.csv ??
          null;
        return {
          ok: true,
          invoice: fresh,
          registry: existingRegistry,
          csv,
          warnings: [],
        };
      }
    }
    invoice = (fresh ?? invoice) as typeof invoice;

    // Recovery path — if a prior submit attempt for this invoice
    // committed its registry but then lost the network round-trip
    // to AEAT, we left the row as PENDING (see catch block below).
    // On retry we re-use that registry as-is: the envelope built
    // from it is byte-identical to the first attempt, so AEAT
    // either accepts it cleanly (if it never received the first
    // request) or recognises it as a duplicate. Either outcome is
    // better than building a fresh record with a new signedAt /
    // huella — which would create a second registry row and a
    // second record on AEAT's side.
    let existingPendingForThis = await this.prisma.verifactuRegistry.findFirst({
      where: { invoiceId: invoice.id, aeatStatus: "PENDING" },
    });

    // Chain-integrity gate — if SOME OTHER invoice in this company
    // is still PENDING (its prior submit lost the round-trip), we
    // can't safely add a new registry to the chain: its previousHash
    // would reference an unconfirmed record. Refuse the submit with
    // a clear pointer to the operator action required. The user
    // checks AEAT's portal: if the record is there, they mark it
    // ACCEPTED locally; if not, they cancel the local row and the
    // serial is released for re-use.
    if (!existingPendingForThis) {
      const otherPending = await this.prisma.verifactuRegistry.findFirst({
        where: {
          companyId: invoice.companyId,
          aeatStatus: "PENDING",
          invoiceId: { not: invoice.id },
        },
        include: { invoice: { select: { number: true } } },
      });
      if (otherPending) {
        return {
          ok: false,
          kind: "aeat_rejected",
          message: `Cannot submit: invoice ${otherPending.invoice?.number ?? otherPending.invoiceId} is still pending AEAT confirmation (the previous attempt didn't complete cleanly). Check the AEAT portal: if the record was accepted there, mark it ACCEPTED locally; otherwise cancel it so its serial number is released. Only then can the next invoice enter the chain.`,
          code: null,
        };
      }
    }

    // Step 1 — either reuse the existing PENDING registry (retry
    // path) or allocate a fresh FACT-YYYY-NNNNN number + create the
    // registry row in the same transaction (first attempt).
    //
    // Spanish law requires sent invoices to be sequentially numbered
    // without gaps, so we delay allocation until submit: an unsent
    // DRAFT is invisible to AEAT and shouldn't burn a serial.
    //
    // We also re-stamp `issueDate` to today on first allocation.
    // `fecha de expedición` per RD 1619/2012 art.11 is the moment of
    // issue, and that's NOW (when we send to AEAT), not whenever the
    // draft happened to be created. On retry we DON'T touch
    // issueDate — the envelope must match what we sent the first
    // time, so AEAT either accepts cleanly or recognises the dupe.
    let registry: VerifactuRegistry;
    let allocatedNumber: { number: string; serialIndex: number } | null = null;
    if (existingPendingForThis) {
      registry = existingPendingForThis;
      // invoice already has its number from the first attempt
    } else {
      const result = await this.prisma.$transaction(async (tx) => {
        let working = invoice;
        const now = new Date();
        const serialYearNow = now.getUTCFullYear();
        let allocated: { number: string; serialIndex: number } | null = null;
        if (!working.number || !working.serialIndex) {
          const max = await tx.invoice.aggregate({
            where: { companyId: working.companyId, serialYear: serialYearNow },
            _max: { serialIndex: true },
          });
          // invoiceNumberOffset is the "I issued N invoices by hand
          // before turning Verifactu on" bootstrap. We pick the max of
          // (last in-DB serial, offset) so once the chain crosses the
          // offset the field is effectively ignored. Offset only kicks
          // in on the very first submit of a (company × year).
          const offset = certCompany?.invoiceNumberOffset ?? 0;
          const serialIndex = Math.max(max._max.serialIndex ?? 0, offset) + 1;
          const number = `FACT-${serialYearNow}-${String(serialIndex).padStart(5, "0")}`;
          working = await tx.invoice.update({
            where: { id: working.id },
            data: {
              number,
              serialIndex,
              serialYear: serialYearNow,
              issueDate: now,
            },
            include: { lines: true },
          });
          allocated = { number, serialIndex };
        } else {
          working = await tx.invoice.update({
            where: { id: working.id },
            data: { issueDate: now, serialYear: serialYearNow },
            include: { lines: true },
          });
        }
        const reg = await this.verifactu.createInsideTx(tx, working, issuerNif);
        return { invoice: working, registry: reg, allocatedNumber: allocated };
      });
      registry = result.registry;
      invoice = result.invoice as typeof invoice;
      allocatedNumber = result.allocatedNumber;
    }

    // Step 2 — build the envelope and submit. If anything throws, we
    // roll back the registry row in the catch.
    try {
      const envelope = await this.buildEnvelope({
        invoice,
        registry,
        issuerNif,
        emitter,
      });

      // Audit: persist the exact bytes we're about to send. If AEAT
      // inspects in 4 years we need to reproduce this verbatim.
      await this.events.log({
        invoiceId: invoice.id,
        companyId: invoice.companyId,
        type: "VERIFACTU_SUBMIT_REQUEST",
        outcome: "info",
        summary: `POST → AEAT (${cfg.env}) — seq #${registry.sequenceNumber}, huella ${registry.currentHash.slice(0, 8)}…`,
        payload: {
          env: cfg.env,
          sequenceNumber: registry.sequenceNumber,
          huella: registry.currentHash,
          signedAt: registry.signedAt,
          soapEnvelope: envelope,
        },
      });

      let aeatResult: AeatSubmitResult;
      try {
        aeatResult = await submitToAeat(cfg.env, envelope, cert);
      } catch (err) {
        const e = err as { kind?: string; message?: string; rawResponseXml?: string };
        await this.events.log({
          invoiceId: invoice.id,
          companyId: invoice.companyId,
          type: "VERIFACTU_SUBMIT_NETWORK_ERROR",
          outcome: "error",
          summary: `AEAT call failed (registry left PENDING for retry): ${e.message ?? "unknown"}`,
          payload: {
            kind: e.kind,
            message: e.message,
            rawResponse: e.rawResponseXml,
          },
        });
        // Crucial: do NOT rollback on transport-level failures. AEAT's
        // verdict is unknown — it may have accepted the record before
        // the response was lost. Deleting our row + releasing the
        // serial here would let the next submit chain off an earlier
        // huella while AEAT keeps the orphan record, breaking the
        // chain on AEAT's side. Instead we leave the registry as
        // PENDING; the recovery path at the top of submit() will
        // re-send the byte-identical envelope on retry. The chain-
        // integrity gate also refuses to submit other invoices for
        // this company until this PENDING is resolved.
        return {
          ok: false,
          kind:
            e.kind === "network_error" ||
            e.kind === "http_error" ||
            e.kind === "soap_fault" ||
            e.kind === "parse_error"
              ? e.kind
              : "aeat_rejected",
          message: e.message ?? "AEAT submission failed",
          code: null,
          rawResponse: e.rawResponseXml,
        };
      }

      const line = aeatResult.lineas[0];
      const accepted =
        aeatResult.estadoEnvio !== "Incorrecto" &&
        (line?.estado === "Correcto" || line?.estado === "AceptadoConErrores");

      if (!accepted) {
        await this.events.log({
          invoiceId: invoice.id,
          companyId: invoice.companyId,
          type: "VERIFACTU_SUBMIT_REJECTED",
          outcome: "error",
          summary: `Rejected (code ${line?.codigoError ?? "?"}): ${line?.descripcionError ?? aeatResult.estadoEnvio}`,
          payload: {
            estadoEnvio: aeatResult.estadoEnvio,
            httpStatus: aeatResult.httpStatus,
            line,
            rawResponse: aeatResult.rawResponseXml,
          },
        });
        await this.rollback(registry.id, invoice.id, invoice.companyId, allocatedNumber);
        return {
          ok: false,
          kind: "aeat_rejected",
          message:
            line?.descripcionError ||
            `AEAT rejected the submission (EstadoEnvio=${aeatResult.estadoEnvio})`,
          code: line?.codigoError ?? null,
          rawResponse: aeatResult.rawResponseXml,
        };
      }

      // Step 3 — persist success.
      const status: string =
        line?.estado === "Correcto" ? "ACCEPTED" : "ACCEPTED_WITH_ERRORS";
      const [updatedRegistry, updatedInvoice] = await this.prisma.$transaction([
        this.prisma.verifactuRegistry.update({
          where: { id: registry.id },
          data: {
            aeatStatus: status,
            aeatSubmittedAt: new Date(),
            aeatResponseCode: line?.codigoError?.toString() ?? null,
            aeatResponseRaw: {
              csv: aeatResult.csv,
              estadoEnvio: aeatResult.estadoEnvio,
              line: line ?? null,
              httpStatus: aeatResult.httpStatus,
            } as unknown as Prisma.InputJsonValue,
            aeatRetryCount: { increment: 1 },
          },
        }),
        this.prisma.invoice.update({
          where: { id: invoice.id },
          data: { status: "SENT" },
        }),
      ]);

      await this.events.log({
        invoiceId: invoice.id,
        companyId: invoice.companyId,
        type: "VERIFACTU_SUBMIT_RESPONSE",
        outcome: "ok",
        summary:
          line?.estado === "Correcto"
            ? `Accepted (CSV ${aeatResult.csv})`
            : `Accepted with warnings (CSV ${aeatResult.csv}, code ${line?.codigoError}): ${line?.descripcionError}`,
        payload: {
          csv: aeatResult.csv,
          estadoEnvio: aeatResult.estadoEnvio,
          httpStatus: aeatResult.httpStatus,
          line,
          rawResponse: aeatResult.rawResponseXml,
        },
      });

      // Re-render PDF so the QR appears immediately. We swallow render
      // errors — the chain is committed, the user can re-download
      // later via /pdf which regenerates on demand.
      try {
        await this.invoices.generateAndStorePdf(invoice.id);
      } catch (err) {
        this.logger.warn(
          `PDF re-render after submit failed for ${invoice.number}: ${(err as Error).message}`,
        );
      }

      const warnings =
        line?.estado === "AceptadoConErrores" && line.descripcionError
          ? [{ code: line.codigoError, description: line.descripcionError }]
          : [];
      return {
        ok: true,
        invoice: updatedInvoice,
        registry: updatedRegistry,
        csv: aeatResult.csv,
        warnings,
      };
    } catch (err) {
      // Defensive: any unexpected error after step 1 rolls back the
      // registry AND releases the allocated serial number to keep
      // both AEAT chain and the local FACT-NNNNN sequence clean.
      await this.rollback(registry.id, invoice.id, invoice.companyId, allocatedNumber);
      throw err;
    }

    });
  }

  private async rollback(
    registryId: string,
    invoiceId: string,
    companyId: string,
    allocatedNumber: { number: string; serialIndex: number } | null,
  ): Promise<void> {
    try {
      await this.prisma.verifactuRegistry.delete({ where: { id: registryId } });
      // Release the serial number we burned on the way in. The
      // invoice goes back to a "true DRAFT" state — same as if the
      // user had just created it — so the next submit (theirs or
      // someone else's) can claim the same serial.
      if (allocatedNumber) {
        await this.prisma.invoice.update({
          where: { id: invoiceId },
          data: { number: null, serialIndex: null },
        });
      }
      await this.events.log({
        invoiceId,
        companyId,
        type: "VERIFACTU_REGISTRY_ROLLBACK",
        outcome: "info",
        summary: allocatedNumber
          ? `Registry deleted + serial #${allocatedNumber.serialIndex} released`
          : `Registry row deleted to keep chain contiguous`,
        payload: { registryId, releasedNumber: allocatedNumber?.number ?? null },
      });
    } catch (err) {
      this.logger.error(
        `Failed to rollback registry ${registryId}: ${(err as Error).message}`,
      );
    }
  }

  private async buildEnvelope(args: {
    invoice: Awaited<ReturnType<PrismaService["invoice"]["findUnique"]>> & {
      lines: unknown[];
    };
    registry: VerifactuRegistry;
    issuerNif: string;
    emitter: { legalName?: string | null; name?: string };
  }): Promise<string> {
    const { invoice, registry, issuerNif, emitter } = args;
    const contact =
      (invoice!.contactSnapshot as {
        name?: string;
        taxId?: string | null;
        countryCode?: string | null;
        isEu?: boolean;
      }) ?? {};

    let encadenamiento: RegistroAltaInput["encadenamiento"];
    if (registry.sequenceNumber === 1) {
      encadenamiento = { kind: "primero" };
    } else {
      const prev = await this.prisma.verifactuRegistry.findFirst({
        where: {
          companyId: registry.companyId,
          sequenceNumber: registry.sequenceNumber - 1,
        },
        include: { invoice: { select: { number: true, issueDate: true } } },
      });
      if (!prev || !prev.invoice.number) {
        throw new Error(
          `Registry ${registry.id} has no predecessor at seq ${registry.sequenceNumber - 1}`,
        );
      }
      encadenamiento = {
        kind: "anterior",
        idEmisorFactura: issuerNif,
        numSerieFactura: prev.invoice.number,
        fechaExpedicionFactura: formatDateForHash(prev.invoice.issueDate),
        huella: prev.currentHash,
      };
    }

    // VeriFactu reports EUR — read the EUR mirror, falling back to the
    // plain amount for pre-feature rows (all EUR).
    const desglose = deriveDesglose({
      vatRate: Number(invoice!.vatRate),
      net: toMoney(invoice!.netAmountEur ?? invoice!.netAmount),
      vat: toMoney(invoice!.vatAmountEur ?? invoice!.vatAmount),
      contactIsEu: !!contact.isEu,
    });

    // AEAT keys the chain off the SIF identity tuple
    // (NombreSistemaInformatico, IdSistemaInformatico, NumeroInstalacion).
    // Changing NumeroInstalacion makes AEAT treat us as a fresh
    // installation — useful as an escape hatch when the local
    // registry has been wiped (e.g. during sandbox cleanup) but AEAT
    // still has prior records under the old identity. In prod we
    // leave VERIFACTU_INSTALLATION_ID unset and fall back to
    // Company.id which is stable for the lifetime of the deploy.
    const numeroInstalacion =
      env.VERIFACTU_INSTALLATION_ID.trim() ||
      registry.companyId;
    const sif: SistemaInformaticoInput = {
      ...SOFTWARE,
      numeroInstalacion,
    };

    const nombreRazonEmisor = (
      emitter.legalName ||
      emitter.name ||
      issuerNif
    ).slice(0, 120);

    // Same assertion as in verifactu.service.ts createInsideTx — the
    // submit flow allocates number before this point so it's non-null
    // here, but TS doesn't propagate that across the txn boundary.
    if (!invoice!.number) {
      throw new Error(
        `Invoice ${invoice!.id} has no number — submit allocation missed`,
      );
    }
    // A customer who gave no tax id is an unidentified consumer. AEAT
    // forbids F1 (factura completa) without identification (error 1189),
    // and forcing a placeholder IDOtro trips rule 1126. The correct
    // vehicle is F2 (factura simplificada), which omits Destinatario
    // entirely. F2 is only legal up to 400€ (art. 4 RD 1619/2012); above
    // that the recipient MUST be identified, so we refuse rather than
    // emit a non-compliant record.
    // Derived from the raw snapshot via the shared helper so this agrees
    // byte-for-byte with the type baked into the Huella at creation time.
    const tipoFactura = deriveTipoFactura(invoice!.contactSnapshot);
    const hasIdentity = tipoFactura === "F1";
    const totalForLimit = Number(
      (invoice!.totalAmountEur ?? invoice!.totalAmount)?.toString() ?? "0",
    );
    if (!hasIdentity && totalForLimit > 400) {
      throw new Error(
        `Invoice ${invoice!.number} (${totalForLimit.toFixed(2)}€) has no ` +
          `customer tax id: F2 (factura simplificada) is capped at 400€. ` +
          `Add the customer's tax id to issue this as F1.`,
      );
    }

    const registroAlta: RegistroAltaInput = {
      idEmisorFactura: issuerNif,
      numSerieFactura: invoice!.number,
      fechaExpedicionFactura: formatDateForHash(invoice!.issueDate),
      nombreRazonEmisor,
      tipoFactura,
      descripcionOperacion: (invoice!.description || "Servicios").slice(0, 500),
      destinatario: hasIdentity ? deriveDestinatario(contact) : undefined,
      desglose,
      cuotaTotal: toMoney(invoice!.vatAmountEur ?? invoice!.vatAmount),
      importeTotal: toMoney(invoice!.totalAmountEur ?? invoice!.totalAmount),
      encadenamiento,
      fechaHoraHusoGenRegistro: formatTimestampForHash(registry.signedAt),
      huella: registry.currentHash,
    };

    return buildSoapEnvelope({
      cabecera: {
        obligadoNombreRazon: nombreRazonEmisor,
        obligadoNif: issuerNif,
      },
      sistemaInformatico: sif,
      registros: [registroAlta],
    });
  }
}

/** Map our internal contactSnapshot to the AEAT Destinatario shape.
 *  See deriveDestinatario in the deprecated submit.cron for branch
 *  rationale — kept here as the canonical impl now that the cron is
 *  gone. */
function deriveDestinatario(c: {
  name?: string;
  taxId?: string | null;
  countryCode?: string | null;
  isEu?: boolean;
}): DestinatarioInput {
  const name = (c.name || "Cliente").slice(0, 120);
  const taxId = (c.taxId || "").trim();
  const country = (c.countryCode || "").trim().toUpperCase();
  if (country === "ES" && taxId) {
    return { nombreRazon: name, id: { kind: "nif", nif: taxId } };
  }
  if (c.isEu && taxId) {
    const cc = country || "FR";
    // NIF-IVA (IDType=02) is the EU intra-community VAT number. AEAT
    // expects the FULL prefixed form here — "DE123456789", not the
    // bare digits. If the user typed it without prefix we add one;
    // if they typed it already-prefixed we keep it. Sending bare
    // digits triggers AEAT error 1103 "El valor del campo ID es
    // incorrecto" because the format check is country-aware.
    return {
      nombreRazon: name,
      id: {
        kind: "otro",
        codigoPais: cc,
        idType: "02",
        idValue: ensureCountryPrefix(taxId, cc).slice(0, 20),
      },
    };
  }
  return {
    nombreRazon: name,
    id: {
      kind: "otro",
      codigoPais: country || "XX",
      // IDType=04 (national doc id) / 07 (no censado) take the bare
      // local identifier — the country prefix convention is only for
      // NIF-IVA (02).
      idType: taxId ? "04" : "07",
      idValue: stripCountryPrefix(taxId || "NOIDFISCAL", country).slice(0, 20),
    },
  };
}

function stripCountryPrefix(id: string, countryCode: string): string {
  if (!countryCode || countryCode.length !== 2) return id;
  const upper = id.toUpperCase();
  return upper.startsWith(countryCode.toUpperCase()) ? id.slice(2) : id;
}

function ensureCountryPrefix(id: string, countryCode: string): string {
  if (!countryCode || countryCode.length !== 2) return id;
  const upperId = id.toUpperCase();
  const upperCC = countryCode.toUpperCase();
  return upperId.startsWith(upperCC) ? id : `${upperCC}${id}`;
}

function toMoney(v: number | string | { toString(): string }): string {
  const n = typeof v === "number" ? v : Number(v.toString());
  if (!Number.isFinite(n)) return "0.00";
  return n.toFixed(2);
}

/** Map a companyId (CUID string) to a 64-bit signed BIGINT for use as a
 *  Postgres advisory-lock key. We take the first 8 bytes of SHA-256 and
 *  reinterpret as a signed int64 — Postgres advisory locks accept
 *  -2^63…2^63-1. Collisions are vanishingly rare across our companyId
 *  space; in the worst case two unrelated companies briefly serialise
 *  their submits, which is harmless. */
function lockKeyForCompany(companyId: string): bigint {
  const hash = crypto.createHash("sha256").update(companyId).digest();
  // Read as big-endian signed int64. Buffer.readBigInt64BE returns a
  // bigint, exactly what Prisma's $executeRaw wants for an int8 param.
  return hash.readBigInt64BE(0);
}
