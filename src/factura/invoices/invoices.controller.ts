import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
  HttpException,
  HttpStatus,
  NotFoundException,
  Param,
  Patch,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from "@nestjs/common";
import type { Request, Response } from "express";
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from "class-validator";
import { Type } from "class-transformer";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { InvoicesService } from "./invoices.service";
import { InvoicePdfStorageService } from "./s3/invoice-pdf.storage";
import { VerifactuService } from "./verifactu/verifactu.service";
import { VerifactuSubmitService } from "./verifactu/submit.service";
import { InvoiceEventsService } from "./invoice-events.service";

class CreateInvoiceContactDto {
  @IsOptional() @IsString() @MaxLength(160) name?: string;
  @IsOptional() @IsString() @MaxLength(60)  taxId?: string;
  @IsOptional() @IsString() @MaxLength(2)   countryCode?: string;
  @IsOptional() @IsBoolean()                isEu?: boolean;

  @IsOptional() @IsString() @MaxLength(160) email?: string;
  @IsOptional() @IsString() @MaxLength(200) addressLine1?: string;
  @IsOptional() @IsString() @MaxLength(200) addressLine2?: string;
  @IsOptional() @IsString() @MaxLength(20)  postalCode?: string;
  @IsOptional() @IsString() @MaxLength(120) city?: string;
  @IsOptional() @IsString() @MaxLength(120) region?: string;
}

class CreateInvoiceLineDto {
  @IsString() @MaxLength(500) description!: string;
  @Type(() => Number) @IsNumber() @Min(0) amount!: number;

  /** Manual EUR equivalent of this line, required (per line) only when
   *  the invoice currency != EUR. Ignored for EUR invoices. Feeds
   *  Invoice.netAmountEur so VeriFactu always reports EUR. */
  @IsOptional() @Type(() => Number) @IsNumber() @Min(0) amountEur?: number;
}

class CreateInvoiceDto {
  @IsOptional() @IsString() contactId?: string;

  /** ISO 4217 currency the invoice is issued in. Defaults to the
   *  contact's currency, then the account's baseCurrency, then EUR.
   *  Non-EUR is only accepted when vatRate=0 (non-Spanish client). */
  @IsOptional() @IsString() @MaxLength(3) currency?: string;

  /** Inline counterparty (when no saved contact). Either contactId or
   *  contact must be supplied; otherwise the snapshot is empty. */
  @IsOptional() @ValidateNested() @Type(() => CreateInvoiceContactDto)
  contact?: CreateInvoiceContactDto;

  /** Multi-line items. When present (wizard form), the per-line
   *  amounts are summed and used as the invoice net (or, when
   *  `amountIsClientPays` is true with exactly one line and Spain
   *  B2B, that one line's amount is treated as gross-minus-IRPF).
   *  When absent, the legacy single-line path uses `amount` +
   *  `description` instead. */
  @IsOptional() @IsArray() @ArrayMaxSize(20)
  @ValidateNested({ each: true }) @Type(() => CreateInvoiceLineDto)
  lineItems?: CreateInvoiceLineDto[];

  @IsOptional() @Type(() => Number) @IsNumber() @Min(0) amount?: number;

  /** When true (only honoured for vatRate=21 + Spain B2B with a
   *  single line), `amount` is interpreted as what the CLIENT
   *  ACTUALLY PAYS — i.e. gross minus IRPF retention — and the
   *  backend reverse-calculates the net via the legacy spain.js
   *  formula:
   *
   *     denom = 1 + vatRate/100 - irpfRate/100
   *     net   = paidAmount / denom
   *
   *  We also force `toPayAmount = amount` instead of recomputing it
   *  from total - irpf, so the stored "to pay" matches the figure the
   *  customer typed to the cent, defending against rounding drift in
   *  the chained multiplications. Mirrors legacy spain.js exactly. */
  @IsOptional() @IsBoolean() amountIsClientPays?: boolean;

  @Type(() => Number) @IsNumber() @IsIn([0, 21]) vatRate!: number;

  /** 0, 7, or 15 — only meaningful when vatRate=21 (Spanish B2B). */
  @IsOptional() @Type(() => Number) @IsNumber() @IsIn([0, 7, 15])
  irpfRate?: number;

  /** Single-line description (legacy single-amount path). Optional now
   *  because the wizard ships line items in `lineItems[]` instead. */
  @IsOptional() @IsString() @MaxLength(500) description?: string;

  @IsOptional() @IsString() @MaxLength(2000) notes?: string;

  /** "art69" | "reverseCharge" | undefined */
  @IsOptional() @IsString() @MaxLength(40) legalNoteCode?: string;

  /** Per-invoice bank account picked on step 3 of the wizard. */
  @IsOptional() @IsString() bankAccountId?: string;

  /** ISO date string (YYYY-MM-DD). Defaults to today. Frontend no
   *  longer sends this — backend defaults to now() and the submit
   *  flow re-stamps to "today" right before the chain row is sealed. */
  @IsOptional() @IsString() issueDate?: string;
}

/** IRPF retention picked from the issuer's tax profile + invoice date.
 *
 *  Order of precedence:
 *    1. Company.defaultIrpfRate — manual override the user typed in
 *       Settings. Beats every rule below.
 *    2. activityType lookup:
 *       - "empresarial"          → 0% (estimación directa, no retention)
 *       - "modulos_empresarial"  → 1%
 *       - "modulos_agricola"     → 2%
 *       - "alquiler"             → 15%
 *       - "profesional" / null   → 7% during alta-year + 2 following
 *                                  calendar years, then 15%
 *    3. When activityType = profesional but no activityStartDate is
 *       known, we assume the autónomo is past the 3-year window and
 *       go with 15% (safer than under-withholding).
 *
 *  Only ever called for Spanish B2B invoices (vatRate=21). Non-ES
 *  clients never trigger IRPF retention. */
function computeIrpfRate(
  issueDate: Date,
  company: {
    defaultIrpfRate: { toString(): string } | null;
    activityType: string | null;
    activityStartDate: Date | null;
  },
): number {
  if (company.defaultIrpfRate != null) {
    return Number(company.defaultIrpfRate.toString());
  }
  const type = company.activityType ?? "profesional";
  if (type === "empresarial") return 0;
  if (type === "modulos_empresarial") return 1;
  if (type === "modulos_agricola") return 2;
  if (type === "alquiler") return 15;
  // profesional — 7% during alta year + 2 next; otherwise 15.
  const startYear = company.activityStartDate
    ? company.activityStartDate.getUTCFullYear()
    : null;
  if (startYear == null) return 15;
  const yearsSinceAlta = issueDate.getUTCFullYear() - startYear;
  return yearsSinceAlta <= 2 ? 7 : 15;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

@Controller("invoices")
@UseGuards(FacturaContextGuard)
export class InvoicesController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly invoices: InvoicesService,
    private readonly storage: InvoicePdfStorageService,
    private readonly verifactu: VerifactuService,
    private readonly verifactuSubmit: VerifactuSubmitService,
    private readonly events: InvoiceEventsService,
  ) {}

  @Get()
  async list(
    @Req() req: Request,
    @Query("year") year?: string,
    @Query("limit") limit = "100",
    @Query("offset") offset = "0",
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const where: { companyId: string; serialYear?: number } = { companyId };
    if (year) {
      const y = Number(year);
      if (!Number.isNaN(y)) where.serialYear = y;
    }
    const [rows, total] = await Promise.all([
      this.prisma.invoice.findMany({
        where,
        orderBy: { issueDate: "desc" },
        take: Math.min(Number(limit) || 100, 500),
        skip: Number(offset) || 0,
        include: { contact: { select: { id: true, name: true } } },
      }),
      this.prisma.invoice.count({ where }),
    ]);
    return { rows, total };
  }

  @Get(":id")
  async byId(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const inv = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      include: { lines: true, contact: true },
    });
    if (!inv) throw new NotFoundException();
    // Surface a PENDING Verifactu registry to the dashboard so it can
    // show the manual-resolution banner. We only need a boolean +
    // the prior submit's timestamp; the full registry row is too
    // heavy to include in the list/detail payload.
    const pending = await this.prisma.verifactuRegistry.findFirst({
      where: { invoiceId: id, aeatStatus: "PENDING" },
      select: { id: true, signedAt: true, sequenceNumber: true },
    });
    return { ...inv, verifactuPending: pending };
  }

  /** Full audit timeline for one invoice — chronologically ordered.
   *  Used by the dashboard history drawer. Returns events as-is, the
   *  large `payload` fields (raw XML envelopes, AEAT responses) are
   *  shown collapsed by default in the UI. */
  @Get(":id/events")
  async listEvents(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    // Tenant check via Invoice — events table has companyId denormalised
    // but we still verify the invoice belongs to the caller's company so
    // a stolen invoiceId can't be used to enumerate someone else's chain.
    const inv = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      select: { id: true },
    });
    if (!inv) throw new NotFoundException();
    const rows = await this.prisma.invoiceEvent.findMany({
      where: { invoiceId: id, companyId },
      orderBy: { createdAt: "asc" },
    });
    return { rows };
  }

  @Post()
  async create(@Req() req: Request, @Body() dto: CreateInvoiceDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    const normalised = await this.normaliseInvoiceDto(dto, companyId);

    // DRAFTs do NOT receive a number / serialIndex here. Spanish law
    // requires the sent-invoice sequence to be gap-free; allocating a
    // number at create time would let an abandoned draft punch a hole
    // in the chain AEAT sees. Numbers are assigned at submit time
    // instead (see VerifactuSubmitService), so the FACT-YYYY-NNNNN
    // sequence reflects only invoices that actually went out.
    // Use UTC so the year matches Verifactu's UTC-based date hash. A
    // 23:30 UTC issue on Dec 31 would otherwise become next-year's
    // serial in a UTC+1 deploy yet last-year's date inside the AEAT
    // hash input — splitting the chain across two serialYear buckets.
    const serialYear = normalised.issueDate.getUTCFullYear();
    const created = await this.createDraft({
      companyId,
      serialYear,
      ...normalised,
    });

    await this.events.log({
      invoiceId: created.id,
      companyId,
      type: "INVOICE_CREATED",
      outcome: "info",
      summary: `Draft created — ${created.totalAmount} ${created.currency} to ${normalised.contactSnapshot.name}`,
      payload: {
        number: created.number,
        issueDate: created.issueDate,
        netAmount: created.netAmount,
        vatRate: created.vatRate,
        vatAmount: created.vatAmount,
        totalAmount: created.totalAmount,
        contactSnapshot: normalised.contactSnapshot,
      },
    });

    // Render + upload the PDF, then patch pdfS3Key / pdfSha256 /
    // pdfGeneratedAt on the row. We swallow PDF failures here so the
    // create response stays 200 — the customer's invoice is saved in DB
    // either way, and the repair cron picks up missing PDFs every 5 min.
    try {
      await this.invoices.renderAndStore(created);
    } catch (err) {
      // Re-fetch so callers don't see a half-updated object on retry.
      // eslint-disable-next-line no-console
      console.error(
        `[invoices] PDF generation failed for ${created.id} (${created.number})`,
        err,
      );
    }

    // Return the freshest row (with pdf fields populated if generation
    // succeeded) so the dashboard immediately gets a download link.
    return this.prisma.invoice.findUnique({
      where: { id: created.id },
      include: { lines: true, contact: { select: { id: true, name: true } } },
    });
  }

  /** Duplicate an invoice (DRAFT or SENT) into a brand-new DRAFT — no
   *  number/serialIndex, no AEAT submission, no registry row. The copy
   *  carries over the contact + emitter snapshots, currency, amounts,
   *  lines, notes and bank account verbatim; only the issue date is reset
   *  to today (a duplicate is a fresh invoice about to be re-issued) and
   *  the serialYear recomputed from it. The user reviews / edits and
   *  submits the copy when ready, so this never touches the sent-invoice
   *  chain. */
  @Post(":id/duplicate")
  async duplicate(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const src = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      include: { lines: { orderBy: { sortOrder: "asc" } } },
    });
    if (!src) throw new NotFoundException();

    // Today at UTC midnight — matches the UTC-based serialYear / date-hash
    // convention used on create so the copy lands in the right year bucket.
    const now = new Date();
    const issueDate = new Date(
      Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
    );

    const created = await this.prisma.invoice.create({
      data: {
        companyId,
        contactId: src.contactId,
        // Fresh DRAFT — number allocated only at submit time.
        number: null,
        serialIndex: null,
        serialYear: issueDate.getUTCFullYear(),
        series: src.series,
        status: "DRAFT",
        issueDate,
        contactSnapshot: src.contactSnapshot as never,
        emitterSnapshot: src.emitterSnapshot as never,
        currency: src.currency,
        language: src.language,
        vatRate: src.vatRate,
        irpfRate: src.irpfRate,
        netAmount: src.netAmount,
        vatAmount: src.vatAmount,
        irpfAmount: src.irpfAmount,
        totalAmount: src.totalAmount,
        toPayAmount: src.toPayAmount,
        netAmountEur: src.netAmountEur,
        vatAmountEur: src.vatAmountEur,
        totalAmountEur: src.totalAmountEur,
        description: src.description,
        notes: src.notes,
        legalNoteCode: src.legalNoteCode,
        bankAccountId: src.bankAccountId,
        lines: {
          create: src.lines.map((l) => ({
            sortOrder: l.sortOrder,
            description: l.description,
            quantity: l.quantity,
            unit: l.unit,
            unitPrice: l.unitPrice,
            total: l.total,
            totalEur: l.totalEur,
          })),
        },
      },
      include: {
        lines: true,
        contact: { select: { id: true, name: true } },
        bankAccount: true,
      },
    });

    await this.events.log({
      invoiceId: created.id,
      companyId,
      type: "INVOICE_CREATED",
      outcome: "info",
      summary: `Draft duplicated from ${src.number ?? "draft"} — ${created.totalAmount} ${created.currency}`,
      payload: {
        duplicatedFrom: src.id,
        sourceNumber: src.number,
        totalAmount: created.totalAmount,
      },
    });

    // Render the PDF for the new draft (swallow failures — the repair cron
    // backfills, same as create).
    try {
      await this.invoices.renderAndStore(created);
    } catch (err) {
      console.error(`[invoices] PDF generation failed for duplicate ${created.id}`, err);
    }

    return this.prisma.invoice.findUnique({
      where: { id: created.id },
      include: { lines: true, contact: { select: { id: true, name: true } } },
    });
  }

  /** Hand the browser a short-lived presigned URL pointing at the PDF
   *  in S3. The dashboard issues this via `window.open(...)` so the file
   *  downloads directly from the bucket without proxying bytes through
   *  the NestJS process.
   *
   *  When the row has no `pdfS3Key` (PDF generation failed at create
   *  time and the repair cron hasn't run yet), we regenerate on-demand
   *  before redirecting. This makes the endpoint self-healing without
   *  the dashboard needing to know about the retry surface. */
  @Get(":id/pdf")
  async pdf(
    @Req() req: Request,
    @Param("id") id: string,
    @Res() res: Response,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    const inv = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      select: { id: true, pdfS3Key: true, number: true },
    });
    if (!inv) throw new NotFoundException();

    let key = inv.pdfS3Key;
    if (!key) {
      try {
        await this.invoices.generateAndStorePdf(inv.id);
      } catch (err) {
        throw new HttpException(
          "PDF generation failed — try again in a moment",
          HttpStatus.SERVICE_UNAVAILABLE,
        );
      }
      const refreshed = await this.prisma.invoice.findUnique({
        where: { id: inv.id },
        select: { pdfS3Key: true },
      });
      key = refreshed?.pdfS3Key ?? null;
    }
    if (!key) {
      throw new HttpException(
        "PDF not yet available",
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    const url = await this.storage.getPresignedUrl(key, 300);
    res.redirect(302, url);
  }

  /** Submit a DRAFT invoice to AEAT VeriFactu. Synchronous: creates the
   *  VerifactuRegistry row with a fresh signedAt + computed Huella,
   *  POSTs the SOAP envelope, and either:
   *
   *   • commits invoice.status = "SENT" + the registry row (when AEAT
   *     returns EstadoEnvio = Correcto / ParcialmenteCorrecto with line
   *     state Correcto or AceptadoConErrores), regenerates the PDF so
   *     it carries the QR + chain-hash tail;
   *
   *   • rolls back the registry row (so the chain doesn't reference a
   *     record AEAT didn't accept) and surfaces the AEAT response to
   *     the caller. The invoice stays DRAFT, the UI shows the modal,
   *     the user fixes and retries. */
  @Post(":id/submit")
  async submitToAeat(
    @Req() req: Request,
    @Param("id") id: string,
    @Res() res: Response,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    const inv = await this.prisma.invoice.findFirst({
      where: { id, companyId },
    });
    if (!inv) throw new NotFoundException();
    if (inv.status === "SENT") {
      throw new BadRequestException("Invoice already submitted");
    }

    const result = await this.verifactuSubmit.submit(inv.id);
    if (result.ok) {
      // PDF re-rendered inside submit() so the response includes the
      // refreshed pdfS3Key (and the QR is visible the moment the
      // dashboard re-fetches the row).
      res.status(HttpStatus.OK).json({
        invoice: result.invoice,
        registry: result.registry,
        csv: result.csv,
        warnings: result.warnings,
      });
      return;
    }
    res.status(HttpStatus.BAD_REQUEST).json({
      error: {
        kind: result.kind,
        message: result.message,
        code: result.code ?? null,
        // Full raw response from AEAT — the UI modal renders this so
        // the user can paste it into a ticket / forum if needed.
        rawResponse: result.rawResponse ?? null,
      },
    });
  }

  /** Operator action: a previous /submit attempt for this invoice
   *  lost the network round-trip to AEAT. We left the local registry
   *  in PENDING state because we couldn't tell whether AEAT actually
   *  recorded the invoice or not. The user has now checked the AEAT
   *  portal in person:
   *
   *   • `/confirm` — yes, the record IS at AEAT. Promote our local
   *      row to ACCEPTED and flip the invoice to SENT. The user pastes
   *      the CSV from the AEAT cabinet so we can store it.
   *
   *   • `/cancel`  — no, AEAT never received it. Delete the registry
   *      row and release the FACT-NNNNN serial so the next invoice
   *      can claim it. Invoice goes back to DRAFT.
   *
   *  Both endpoints are no-ops if the registry is already resolved
   *  (idempotent — UI may double-submit). */
  @Post(":id/verifactu/confirm")
  async confirmPending(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() body: { csv?: string },
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const inv = await this.prisma.invoice.findFirst({ where: { id, companyId } });
    if (!inv) throw new NotFoundException();
    const reg = await this.prisma.verifactuRegistry.findFirst({
      where: { invoiceId: id, aeatStatus: "PENDING" },
    });
    if (!reg) {
      throw new BadRequestException(
        "No pending registry to confirm. The invoice is already resolved.",
      );
    }
    const csv = (body.csv ?? "").trim() || null;
    await this.prisma.$transaction([
      this.prisma.verifactuRegistry.update({
        where: { id: reg.id },
        data: {
          aeatStatus: "ACCEPTED",
          aeatSubmittedAt: new Date(),
          aeatResponseRaw: { csv, manualConfirmation: true } as never,
        },
      }),
      this.prisma.invoice.update({
        where: { id: inv.id },
        data: { status: "SENT" },
      }),
    ]);
    await this.events.log({
      invoiceId: inv.id,
      companyId,
      type: "VERIFACTU_MANUAL_CONFIRM",
      outcome: "ok",
      summary: `Operator marked PENDING #${reg.sequenceNumber} as accepted (CSV ${csv ?? "n/a"})`,
      payload: { registryId: reg.id, csv },
    });
    return { ok: true };
  }

  @Post(":id/verifactu/cancel")
  async cancelPending(
    @Req() req: Request,
    @Param("id") id: string,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const inv = await this.prisma.invoice.findFirst({ where: { id, companyId } });
    if (!inv) throw new NotFoundException();
    const reg = await this.prisma.verifactuRegistry.findFirst({
      where: { invoiceId: id, aeatStatus: "PENDING" },
    });
    if (!reg) {
      throw new BadRequestException(
        "No pending registry to cancel. The invoice is already resolved.",
      );
    }
    await this.prisma.$transaction([
      this.prisma.verifactuRegistry.delete({ where: { id: reg.id } }),
      this.prisma.invoice.update({
        where: { id: inv.id },
        data: { number: null, serialIndex: null },
      }),
    ]);
    await this.events.log({
      invoiceId: inv.id,
      companyId,
      type: "VERIFACTU_MANUAL_CANCEL",
      outcome: "info",
      summary: `Operator canceled PENDING #${reg.sequenceNumber} (AEAT did not receive)`,
      payload: { registryId: reg.id, releasedNumber: inv.number },
    });
    return { ok: true };
  }

  /** Edit a DRAFT invoice in place. Re-uses the wizard's create-time
   *  normalisation so the math and snapshot composition stays in lock-
   *  step. Refuses to touch invoices already accepted by AEAT — the
   *  Verifactu chain has frozen them. */
  @Patch(":id")
  async update(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() dto: CreateInvoiceDto,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      select: { id: true, status: true, number: true },
    });
    if (!existing) throw new NotFoundException();
    if (existing.status !== "DRAFT") {
      throw new BadRequestException("Only DRAFT invoices can be edited");
    }

    const n = await this.normaliseInvoiceDto(dto, companyId);

    const updated = await this.prisma.$transaction(async (tx) => {
      await tx.invoiceLine.deleteMany({ where: { invoiceId: id } });
      return tx.invoice.update({
        where: { id },
        data: {
          contactId: n.contactId,
          issueDate: n.issueDate,
          contactSnapshot: n.contactSnapshot as never,
          emitterSnapshot: n.emitterSnapshot as never,
          currency: n.currency,
          language: n.language,
          vatRate: n.vatRate,
          irpfRate: n.irpfRate,
          netAmount: n.net,
          vatAmount: n.vatAmount,
          irpfAmount: n.irpfAmount,
          totalAmount: n.total,
          toPayAmount: n.toPay,
          netAmountEur: n.netEur,
          vatAmountEur: n.vatEur,
          totalAmountEur: n.totalEur,
          description: n.description,
          notes: n.notes,
          legalNoteCode: n.legalNoteCode,
          bankAccountId: n.bankAccountId,
          lines: {
            create: n.items.map((it, idx) => ({
              sortOrder: idx,
              description: it.description,
              quantity: 1,
              unit: n.language === "es" ? "ud" : "pc",
              unitPrice: it.amount,
              total: it.amount,
              totalEur: it.amountEur,
            })),
          },
        },
        // bankAccount included so the downstream renderAndStore() can
        // print DATOS DE PAGO. Same fix as createDraft — Prisma doesn't
        // auto-resolve relations on update() returns.
        include: {
          lines: true,
          contact: { select: { id: true, name: true } },
          bankAccount: true,
        },
      });
    });

    await this.events.log({
      invoiceId: updated.id,
      companyId,
      type: "INVOICE_UPDATED",
      outcome: "info",
      summary: `Edited ${updated.number} — ${updated.totalAmount} ${updated.currency} to ${n.contactSnapshot.name}`,
      payload: {
        netAmount: updated.netAmount,
        vatAmount: updated.vatAmount,
        totalAmount: updated.totalAmount,
        contactSnapshot: n.contactSnapshot,
      },
    });

    // Refresh the PDF so the QR/contents reflect the edit. Errors are
    // swallowed for the same reason as in create — the row is saved
    // either way.
    try {
      await this.invoices.renderAndStore(updated);
    } catch (err) {
      console.error(
        `[invoices] PDF regen failed for ${updated.id} (${updated.number})`,
        err,
      );
    }

    return this.prisma.invoice.findUnique({
      where: { id: updated.id },
      include: { lines: true, contact: { select: { id: true, name: true } } },
    });
  }

  /** Delete a DRAFT invoice. Cascades to InvoiceLines + InvoiceEvents
   *  + VerifactuRegistry via the schema. Refused on SENT invoices —
   *  the Spanish tax law retention duty is 4 years minimum, and we
   *  also need the Huella for chain integrity downstream. */
  @Delete(":id")
  async remove(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.invoice.findFirst({
      where: { id, companyId },
      select: { id: true, status: true, number: true },
    });
    if (!existing) throw new NotFoundException();
    if (existing.status !== "DRAFT") {
      throw new BadRequestException("Only DRAFT invoices can be deleted");
    }
    await this.prisma.invoice.delete({ where: { id } });
    return { ok: true, number: existing.number };
  }

  /** Shared invoice-DTO normalisation: turns the raw input into the
   *  derived fields both create and update need. Pulled out so the
   *  math + snapshot assembly stays in one place — the two endpoints
   *  diverge only in how they persist (create allocates a serial,
   *  update reuses the existing one). */
  private async normaliseInvoiceDto(
    dto: CreateInvoiceDto,
    companyId: string,
  ): Promise<{
    issueDate: Date;
    items: { description: string; amount: number; amountEur: number | null }[];
    currency: string;
    vatRate: number;
    irpfRate: number;
    net: number;
    vatAmount: number;
    total: number;
    irpfAmount: number;
    toPay: number;
    netEur: number;
    vatEur: number;
    totalEur: number;
    contactId: string | null;
    contactSnapshot: {
      lines: string[];
      name: string;
      taxId: string | null;
      countryCode: string | null;
      isEu: boolean;
      nature?: string;
      esNoIva?: boolean;
    };
    emitterSnapshot: Record<string, unknown>;
    language: string;
    nature: string;
    description: string;
    notes: string | null;
    legalNoteCode: string | null;
    bankAccountId: string | null;
  }> {
    const company = await this.prisma.company.findUnique({
      where: { id: companyId },
    });
    if (!company) throw new NotFoundException("Company not found");

    const issueDate = dto.issueDate ? new Date(dto.issueDate) : new Date();
    if (Number.isNaN(issueDate.getTime())) {
      throw new BadRequestException("Invalid issueDate");
    }

    // Normalise the two intake shapes into a uniform `items` array
    // before doing money math.
    const items: { description: string; amount: number; amountEur: number | null }[] =
      dto.lineItems && dto.lineItems.length > 0
        ? dto.lineItems.map((l) => ({
            description: l.description.trim(),
            amount: round2(l.amount),
            amountEur: l.amountEur !== undefined ? round2(l.amountEur) : null,
          }))
        : dto.amount !== undefined && dto.description !== undefined
          ? [{
              description: dto.description.trim(),
              amount: round2(dto.amount),
              amountEur: null,
            }]
          : [];
    if (items.length === 0) {
      throw new BadRequestException(
        "Provide lineItems[] or description+amount",
      );
    }

    const irpfRate =
      dto.vatRate === 21
        ? (dto.irpfRate ?? computeIrpfRate(issueDate, company))
        : 0;
    const itemsSum = round2(items.reduce((acc, i) => acc + i.amount, 0));

    let net: number;
    let forcedToPay: number | null = null;
    if (dto.amountIsClientPays && dto.vatRate === 21 && items.length === 1) {
      const denom = 1 + dto.vatRate / 100 - irpfRate / 100;
      if (denom <= 0) {
        throw new BadRequestException("Invalid VAT + IRPF combination");
      }
      net = round2(itemsSum / denom);
      forcedToPay = round2(itemsSum);
      items[0] = { ...items[0], amount: net };
    } else {
      net = itemsSum;
    }

    const vatAmount = round2((net * dto.vatRate) / 100);
    const total = round2(net + vatAmount);
    const irpfAmount = round2((net * irpfRate) / 100);
    const toPay = forcedToPay ?? round2(total - irpfAmount);

    // Resolve counterparty snapshot — saved contact OR inline.
    let contactId: string | null = null;
    let contactCurrency: string | null = null;
    let contactSnapshot: {
      lines: string[];
      name: string;
      taxId: string | null;
      countryCode: string | null;
      isEu: boolean;
      nature?: string;
      esNoIva?: boolean;
    };
    if (dto.contactId) {
      // Picked from the saved-contacts list. Gemini already ran when
      // the Contact row was created / last edited — we just freeze
      // its current shape into the invoice snapshot, no LLM call here.
      const c = await this.prisma.contact.findFirst({
        where: { id: dto.contactId, companyId, archivedAt: null },
      });
      if (!c) throw new BadRequestException("Contact not found");
      contactId = c.id;
      contactCurrency = c.currency;
      contactSnapshot = {
        name: c.name,
        taxId: c.taxId,
        countryCode: c.countryCode,
        isEu: c.isEu,
        nature: c.nature,
        esNoIva: c.esNoIva,
        email: c.email,
        addressLine1: c.addressLine1,
        addressLine2: c.addressLine2,
        postalCode: c.postalCode,
        city: c.city,
        region: c.region,
      } as never;
    } else if (dto.contact) {
      // Inline-contact path kept for backward compat — same structured
      // shape, no Gemini. The current wizard sends contactId only.
      const c = dto.contact;
      contactSnapshot = {
        name: c.name ?? "Client",
        taxId: c.taxId ?? null,
        countryCode: c.countryCode ?? null,
        isEu: !!c.isEu,
        nature: (c as { nature?: string }).nature === "goods" ? "goods" : "service",
        esNoIva: (c as { esNoIva?: boolean }).esNoIva === true,
        email: c.email ?? null,
        addressLine1: c.addressLine1 ?? null,
        addressLine2: c.addressLine2 ?? null,
        postalCode: c.postalCode ?? null,
        city: c.city ?? null,
        region: c.region ?? null,
      } as never;
    } else {
      throw new BadRequestException("contactId or contact required");
    }

    // PDF language is country-driven now: Spanish customers get a
    // Spanish invoice, everyone else gets English. EU vs non-EU still
    // matters but only for the footer legal note (driven separately by
    // legalNoteCode), not for the whole document.
    const language = contactSnapshot.countryCode === "ES" ? "es" : "en";

    const emitterSnapshot = {
      name: company.name,
      legalName: company.legalName,
      taxId: company.taxId,
      vatId: company.vatId,
      addressLine1: company.addressLine1,
      addressLine2: company.addressLine2,
      city: company.city,
      postalCode: company.postalCode,
      region: company.region,
      country: company.country,
      bankName: company.bankName,
      iban: company.iban,
      swift: company.swift,
    };

    // Validate the picked bank account belongs to this tenant. Drops to
    // null if the user didn't pick one (no payment block on the PDF).
    let bankAccountId: string | null = null;
    if (dto.bankAccountId) {
      const ba = await this.prisma.bankAccount.findFirst({
        where: { id: dto.bankAccountId, companyId, archivedAt: null },
        select: { id: true },
      });
      if (!ba) {
        throw new BadRequestException("Bank account not found");
      }
      bankAccountId = ba.id;
    }

    // Resolve the invoice currency: explicit DTO > contact's currency >
    // account base currency > EUR. Non-EUR is only legal on 0%-VAT
    // (non-Spanish) invoices — with Spanish VAT the cuota would have to
    // be expressed in EUR on the invoice, which we don't support yet.
    const currency = (
      dto.currency ||
      contactCurrency ||
      company.baseCurrency ||
      "EUR"
    ).toUpperCase();

    let netEur: number;
    let vatEur: number;
    let totalEur: number;
    if (currency === "EUR") {
      // Recipient currency IS EUR — the EUR mirror equals the figures.
      netEur = net;
      vatEur = vatAmount;
      totalEur = total;
    } else {
      if (dto.vatRate !== 0) {
        throw new BadRequestException(
          "Non-EUR currency is only allowed on 0% VAT invoices",
        );
      }
      // Each line must carry a manual EUR equivalent — that sum is what
      // VeriFactu reports as the EUR base. No VAT (vatRate=0) so the EUR
      // total equals the EUR net.
      if (items.some((it) => it.amountEur === null)) {
        throw new BadRequestException(
          "Each line needs an EUR amount (amountEur) when currency != EUR",
        );
      }
      netEur = round2(
        items.reduce((acc, it) => acc + (it.amountEur ?? 0), 0),
      );
      vatEur = 0;
      totalEur = netEur;
    }

    return {
      issueDate,
      items,
      currency,
      netEur,
      vatEur,
      totalEur,
      vatRate: dto.vatRate,
      irpfRate,
      net,
      vatAmount,
      total,
      irpfAmount,
      toPay,
      contactId,
      contactSnapshot,
      emitterSnapshot,
      language,
      nature: contactSnapshot.nature ?? "service",
      description: (dto.description ?? items[0].description).trim(),
      notes: dto.notes?.trim() || null,
      legalNoteCode: dto.legalNoteCode || null,
      bankAccountId,
    };
  }

  /** Persist a fresh DRAFT row. No serial number is allocated — that
   *  happens at submit time so abandoned drafts don't punch holes in
   *  the chain AEAT eventually sees. */
  private async createDraft(args: {
    companyId: string;
    contactId: string | null;
    serialYear: number;
    issueDate: Date;
    contactSnapshot: Record<string, unknown>;
    emitterSnapshot: Record<string, unknown>;
    currency: string;
    vatRate: number;
    irpfRate: number;
    net: number;
    vatAmount: number;
    total: number;
    irpfAmount: number;
    toPay: number;
    netEur: number;
    vatEur: number;
    totalEur: number;
    items: { description: string; amount: number; amountEur: number | null }[];
    description: string;
    notes: string | null;
    legalNoteCode: string | null;
    language: string;
    nature: string;
    bankAccountId: string | null;
  }) {
    return this.prisma.invoice.create({
      data: {
        companyId: args.companyId,
        contactId: args.contactId,
        nature: args.nature,
        // Both null on DRAFT — populated by VerifactuSubmitService
        // when the user clicks Submit.
        number: null,
        serialIndex: null,
        serialYear: args.serialYear,
        series: "FACT",
        issueDate: args.issueDate,
        contactSnapshot: args.contactSnapshot as never,
        emitterSnapshot: args.emitterSnapshot as never,
        currency: args.currency,
        language: args.language,
        vatRate: args.vatRate,
        irpfRate: args.irpfRate,
        netAmount: args.net,
        vatAmount: args.vatAmount,
        irpfAmount: args.irpfAmount,
        totalAmount: args.total,
        toPayAmount: args.toPay,
        netAmountEur: args.netEur,
        vatAmountEur: args.vatEur,
        totalAmountEur: args.totalEur,
        description: args.description,
        notes: args.notes,
        legalNoteCode: args.legalNoteCode,
        bankAccountId: args.bankAccountId,
        lines: {
          create: args.items.map((it, idx) => ({
            sortOrder: idx,
            description: it.description,
            quantity: 1,
            unit: args.language === "es" ? "ud" : "pc",
            unitPrice: it.amount,
            total: it.amount,
            totalEur: it.amountEur,
          })),
        },
      },
      // bankAccount is included so the immediate renderAndStore() call
      // can compose the DATOS DE PAGO block. Without it the relation
      // is undefined on the returned row and the PDF renders without
      // the payment footer even when bankAccountId is set on the DB.
      include: {
        lines: true,
        contact: { select: { id: true, name: true } },
        bankAccount: true,
      },
    });
  }
}

