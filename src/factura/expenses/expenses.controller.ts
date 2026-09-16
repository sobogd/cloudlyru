import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
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
  IsBoolean,
  IsISO8601,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
} from "class-validator";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { parseExpenseFile } from "./expenses-parse";
import { ExpenseDocStorageService } from "./expense-doc.storage";
import { classifyTerritory } from "../tax/territory";
import { validateNifIva, withCountryPrefix } from "../tax/nif-validation";

class ExpenseDto {
  @IsString() @MaxLength(200) supplierName!: string;
  @IsOptional() @IsString() @MaxLength(40) supplierTaxId?: string;
  @IsOptional() @IsString() @MaxLength(2) supplierCountryCode?: string;
  /** "goods" | "service" — distinguishes 349 clave A (goods) from I
   *  (services). Ads/Cloud/SaaS = service. Default service. */
  @IsOptional() @IsString() @MaxLength(10) nature?: string;
  /** Supplier in Canarias / Ceuta / Melilla (ES outside the IVA zone). */
  @IsOptional() @IsBoolean() supplierEsNoIva?: boolean;
  /** "invoice" (default) | "recurring_no_invoice" — the latter for
   *  TGSS/RETA social-security quotas with no invoice document. */
  @IsOptional() @IsString() @MaxLength(30) kind?: string;

  @IsISO8601() issueDate!: string; // "YYYY-MM-DD"
  @IsOptional() @IsString() @MaxLength(80) category?: string;
  @IsOptional() @IsString() @MaxLength(300) description?: string;
  @IsOptional() @IsString() @MaxLength(20000) notes?: string;

  @IsOptional() @IsString() @MaxLength(3) currency?: string;
  @IsNumber() @Min(0) netAmount!: number; // base imponible, in `currency`
  @IsOptional() @IsNumber() @Min(0) @Max(100) vatRate?: number; // default 21
  @IsOptional() @IsNumber() @Min(0) @Max(100) irpfRate?: number; // default 0

  /** EUR equivalent of the base when currency != EUR. Ignored for EUR. */
  @IsOptional() @IsNumber() @Min(0) netAmountEur?: number;
  /** FX rate (EUR per 1 unit of currency) + its reference date, the BCE/BOE
   *  rate at the devengo date. Stored for audit; ignored for EUR. */
  @IsOptional() @IsNumber() @Min(0) fxRate?: number;
  @IsOptional() @IsISO8601() fxRateDate?: string;

  @IsOptional() @IsNumber() @Min(0) @Max(100) deductibleVatPct?: number; // default 100
  @IsOptional() @IsBoolean() deductibleForIrpf?: boolean; // default true
  @IsOptional() @IsBoolean() reverseCharge?: boolean;

  // Attached source document (uploaded via /expenses/upload → S3 key).
  @IsOptional() @IsString() @MaxLength(300) fileS3Key?: string;
  @IsOptional() @IsString() @MaxLength(100) fileMime?: string;
  @IsOptional() @IsString() @MaxLength(300) fileName?: string;
}

/** Base64-encoded document (image or PDF) to store in S3 and — on the first
 *  create-flow upload — parse via Gemini vision. */
class UploadExpenseDto {
  @IsString() data!: string; // base64 (no data: URI prefix)
  @IsString() @MaxLength(100) mimeType!: string; // "image/jpeg" | "application/pdf" | …
  @IsOptional() @IsString() @MaxLength(300) fileName?: string;
  /** Run the AI parse and return pre-filled fields. Only the first upload
   *  of a new expense sets this; replacing a file does not re-run the AI. */
  @IsOptional() @IsBoolean() parse?: boolean;
}

const ALLOWED_MIME = /^(image\/(jpeg|png|webp|heic|heif)|application\/pdf)$/;

/** Expenses (facturas recibidas / gastos) CRUD, scoped to the active
 *  company. These feed the quarterly-declarations helper — the deductible
 *  IVA (soportado) for Modelo 303 and the deductible expenses for the
 *  Modelo 130 pago fraccionado. No numbering / VeriFactu duty: they are
 *  the supplier's documents, recorded for aggregation only.
 *
 *  All money is derived server-side from `netAmount` + `vatRate` +
 *  `irpfRate` so the stored figures are always internally consistent,
 *  the same discipline used on the invoice side. The EUR mirror equals
 *  the amounts for EUR expenses and is scaled from `netAmountEur` for
 *  foreign-currency ones. The source document lives in S3 (`fileS3Key`). */
@Controller("expenses")
@UseGuards(FacturaContextGuard)
export class ExpensesController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: ExpenseDocStorageService,
  ) {}

  @Get()
  async list(@Req() req: Request, @Query("year") year?: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const where: { companyId: string; issueDate?: { gte: Date; lt: Date } } = {
      companyId,
    };
    if (year) {
      const y = Number(year);
      if (!Number.isNaN(y)) {
        where.issueDate = {
          gte: new Date(Date.UTC(y, 0, 1)),
          lt: new Date(Date.UTC(y + 1, 0, 1)),
        };
      }
    }
    return this.prisma.expense.findMany({
      where,
      orderBy: { issueDate: "desc" },
    });
  }

  @Post()
  async create(@Req() req: Request, @Body() dto: ExpenseDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    return this.prisma.expense.create({
      data: { ...buildData(dto), ...fileData(dto), companyId },
    });
  }

  /** Store an uploaded bill (image/PDF) in S3, returning its key. When
   *  `parse` is true, also run Gemini vision and return the pre-filled
   *  fields — used only for the first upload of a new expense; replacing
   *  a file uploads without re-parsing. Nothing is persisted to the
   *  Expense row here; the client sends the returned key on save. */
  @Post("upload")
  async upload(@Req() req: Request, @Body() dto: UploadExpenseDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    if (!ALLOWED_MIME.test(dto.mimeType)) {
      throw new BadRequestException("Unsupported file type (use an image or PDF)");
    }
    // 20mb JSON body limit ⇒ ~14mb of raw file after base64 overhead.
    if (dto.data.length > 19_000_000) {
      throw new BadRequestException("File too large (max ~14 MB)");
    }
    const key = this.storage.key(companyId, dto.mimeType);
    await this.storage.upload({
      key,
      body: Buffer.from(dto.data, "base64"),
      mimeType: dto.mimeType,
      fileName: dto.fileName,
    });
    const parsed = dto.parse
      ? await parseExpenseFile(dto.data, dto.mimeType)
      : undefined;
    return { fileS3Key: key, fileMime: dto.mimeType, fileName: dto.fileName ?? null, parsed };
  }

  /** Stream the attached document's bytes through the API (same-origin, so
   *  pdf.js can render pages on mobile — an iframe PDF doesn't show there).
   *  The key is tenant-scoped; we only serve objects under this company's
   *  prefix. Works pre-save too (upload returns the key before a row exists). */
  @Get("raw")
  async raw(
    @Req() req: Request,
    @Res() res: Response,
    @Query("key") key?: string,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    if (!key || !key.startsWith(`expenses/${companyId}/`)) {
      throw new NotFoundException();
    }
    const obj = await this.storage.getObject(key);
    res.setHeader("Content-Type", obj.contentType || "application/octet-stream");
    if (obj.contentLength) res.setHeader("Content-Length", String(obj.contentLength));
    res.setHeader("Cache-Control", "private, max-age=60");
    obj.body.pipe(res);
  }

  /** Presigned URL for the attached document. Redirects by default; with
   *  `?json=1` returns `{ url }` so the dashboard can load it into an
   *  in-app preview modal (iframe) instead of a new tab. */
  @Get(":id/file")
  async file(
    @Req() req: Request,
    @Param("id") id: string,
    @Res() res: Response,
    @Query("json") json?: string,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    const row = await this.prisma.expense.findFirst({
      where: { id, companyId },
      select: { fileS3Key: true, fileMime: true, fileName: true },
    });
    if (!row?.fileS3Key) throw new NotFoundException();
    const url = await this.storage.getPresignedUrl(row.fileS3Key, 300);
    if (json) {
      res.json({ url, mime: row.fileMime, name: row.fileName });
      return;
    }
    res.redirect(302, url);
  }

  @Get(":id")
  async byId(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const row = await this.prisma.expense.findFirst({
      where: { id, companyId },
    });
    if (!row) throw new NotFoundException();
    return row;
  }

  @Patch(":id")
  async update(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() dto: ExpenseDto,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.expense.findFirst({
      where: { id, companyId },
      select: { id: true, fileS3Key: true },
    });
    if (!existing) throw new NotFoundException();
    const file = fileData(dto);
    // A replaced file leaves the old S3 object orphaned — delete it.
    if (existing.fileS3Key && existing.fileS3Key !== file.fileS3Key) {
      await this.storage.delete(existing.fileS3Key);
    }
    return this.prisma.expense.update({
      where: { id },
      data: { ...buildData(dto), ...file },
    });
  }

  @Delete(":id")
  async remove(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.expense.findFirst({
      where: { id, companyId },
      select: { id: true, fileS3Key: true },
    });
    if (!existing) throw new NotFoundException();
    if (existing.fileS3Key) await this.storage.delete(existing.fileS3Key);
    // Hard delete — expenses carry no legal retention duty (they're the
    // supplier's document, not ours) so there's nothing to soft-preserve.
    await this.prisma.expense.delete({ where: { id } });
    return { ok: true };
  }
}

/** Round to 2 decimals, avoiding binary-float drift on .5 cases. */
function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

/** The attached-document fields, normalised (empty → null). */
function fileData(dto: ExpenseDto) {
  return {
    fileS3Key: (dto.fileS3Key || "").trim() || null,
    fileMime: (dto.fileMime || "").trim() || null,
    fileName: (dto.fileName || "").trim() || null,
  };
}

/** Compute the full money shape + EUR mirror from the DTO. Single place
 *  so create and update can't diverge. */
function buildData(dto: ExpenseDto) {
  const name = dto.supplierName.trim();
  if (!name) throw new BadRequestException("supplierName is required");

  const currency = (dto.currency || "EUR").trim().toUpperCase();
  if (currency.length !== 3) {
    throw new BadRequestException("currency must be a 3-letter ISO 4217 code");
  }

  const cc = (dto.supplierCountryCode || "").trim().toUpperCase() || null;
  const nature = dto.nature === "goods" ? "goods" : "service";
  const supplierEsNoIva = dto.supplierEsNoIva === true;
  const kind = dto.kind === "recurring_no_invoice" ? "recurring_no_invoice" : "invoice";

  const issueDate = new Date(`${dto.issueDate.slice(0, 10)}T00:00:00.000Z`);
  if (Number.isNaN(issueDate.getTime())) {
    throw new BadRequestException("issueDate must be a valid YYYY-MM-DD date");
  }

  const territory = classifyTerritory(cc, nature, issueDate, { esNoIva: supplierEsNoIva });
  const supplierIsEu = territory === "EU";
  let supplierTaxId = (dto.supplierTaxId || "").trim().toUpperCase() || null;

  // NIF-IVA checksum guard (349-3): block obvious typos/OCR errors on an
  // intra-EU supplier before they reach the 349. The country lives in its own
  // field, so normalise a bare number to the prefixed form before validating
  // and store it prefixed (what the 349 and VIES need).
  if (territory === "EU" && supplierTaxId) {
    supplierTaxId = withCountryPrefix(supplierTaxId, cc);
    const check = validateNifIva(supplierTaxId);
    if (!check.valid) {
      throw new BadRequestException(
        `Invalid intra-EU VAT id "${supplierTaxId}"${check.reason ? ` (${check.reason})` : ""}.`,
      );
    }
    supplierTaxId = check.normalized;
  }

  const net = round2(dto.netAmount);
  const vatRate = dto.vatRate ?? 21;
  const irpfRate = dto.irpfRate ?? 0;
  const vat = round2((net * vatRate) / 100);
  const irpf = round2((net * irpfRate) / 100);
  const total = round2(net + vat - irpf);

  // EUR mirror: identity for EUR; scaled from the provided EUR base for
  // foreign-currency expenses (VAT/total recomputed at the same rate so
  // the mirror is internally consistent, not a second rounding of FX).
  const isEur = currency === "EUR";
  const netEur = isEur ? net : dto.netAmountEur != null ? round2(dto.netAmountEur) : null;
  const vatEur = netEur != null ? round2((netEur * vatRate) / 100) : null;
  const totalEur =
    netEur != null && vatEur != null
      ? round2(netEur + vatEur - round2((netEur * irpfRate) / 100))
      : null;

  const deductibleVatPct = dto.deductibleVatPct ?? 100;
  const fxRate = !isEur && dto.fxRate != null ? dto.fxRate : null;
  const fxRateDate =
    !isEur && dto.fxRateDate
      ? new Date(`${dto.fxRateDate.slice(0, 10)}T00:00:00.000Z`)
      : null;

  return {
    supplierName: name,
    supplierTaxId,
    supplierCountryCode: cc,
    supplierIsEu,
    supplierEsNoIva,
    nature,
    kind,
    issueDate,
    category: (dto.category || "").trim() || null,
    description: (dto.description || "").trim() || null,
    notes: (dto.notes || "").trim() || null,
    currency,
    netAmount: net,
    vatRate,
    vatAmount: vat,
    irpfRate,
    irpfAmount: irpf,
    totalAmount: total,
    netAmountEur: netEur,
    vatAmountEur: vatEur,
    totalAmountEur: totalEur,
    fxRate,
    fxRateDate,
    deductibleVatPct,
    deductibleForIrpf: dto.deductibleForIrpf !== false,
    // Reverse charge is now DERIVED from territory (EU acquisition), not a
    // free-standing AI guess — the engine recomputes VAT from it anyway.
    reverseCharge: territory === "EU",
  };
}
