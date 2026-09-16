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
  IsInt,
  IsISO8601,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
} from "class-validator";
import { Prisma } from "@prisma/client";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { parseFiledDeclarationFile } from "./filed-declarations-parse";
import { FiledDeclarationDocStorageService } from "./filed-declaration-doc.storage";

const MODELS = new Set(["303", "130", "349"]);

class FiledDeclarationDto {
  @IsString() @MaxLength(3) model!: string; // "303" | "130" | "349"
  @IsInt() @Min(2000) @Max(2100) year!: number;
  @IsInt() @Min(1) @Max(4) quarter!: number;

  @IsOptional() @IsString() @MaxLength(60) justificante?: string;
  @IsOptional() @IsISO8601() submittedAt?: string; // "YYYY-MM-DD"

  /** Full box map as filed, e.g. { "07": 2674.04 }. */
  @IsOptional() @IsObject() casillas?: Record<string, unknown>;

  @IsOptional() @IsNumber() resultPaid?: number; // 130→box07 ; 303→box71
  @IsOptional() @IsNumber() compensarNext?: number; // 303→box87

  @IsOptional() @IsString() @MaxLength(20000) notes?: string;

  // Attached source document (uploaded via /filed-declarations/upload → S3 key).
  @IsOptional() @IsString() @MaxLength(300) fileS3Key?: string;
  @IsOptional() @IsString() @MaxLength(100) fileMime?: string;
  @IsOptional() @IsString() @MaxLength(300) fileName?: string;
}

/** Base64-encoded document (image or PDF) to store in S3 and — on the first
 *  create-flow upload — parse via Gemini vision. */
class UploadFiledDeclarationDto {
  @IsString() data!: string; // base64 (no data: URI prefix)
  @IsString() @MaxLength(100) mimeType!: string; // "image/jpeg" | "application/pdf" | …
  @IsOptional() @IsString() @MaxLength(300) fileName?: string;
  /** Run the AI parse and return pre-filled fields. Only the first upload
   *  of a new declaration sets this; replacing a file does not re-run the AI. */
  @IsOptional() @IsBoolean() parse?: boolean;
}

const ALLOWED_MIME = /^(image\/(jpeg|png|webp|heic|heif)|application\/pdf)$/;

/** Filed declarations (declaraciones presentadas) CRUD, scoped to the active
 *  company. The declarations engine is stateless except two boxes that
 *  legally must read PRIOR filed returns — Modelo 130 box 05 (sum of prior
 *  quarters' box 07 = resultPaid) and Modelo 303 boxes 110/78/87 (carry from
 *  the prior filed return's compensarNext). This is the store of record for
 *  what the user actually filed, entered by typing or by uploading the AEAT
 *  PDF and letting AI autofill — the same discipline as expenses.
 *
 *  The source document lives in S3 (`fileS3Key`). */
@Controller("filed-declarations")
@UseGuards(FacturaContextGuard)
export class FiledDeclarationsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: FiledDeclarationDocStorageService,
  ) {}

  @Get()
  async list(@Req() req: Request, @Query("year") year?: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const where: { companyId: string; year?: number } = { companyId };
    if (year) {
      const y = Number(year);
      if (!Number.isNaN(y)) where.year = y;
    }
    return this.prisma.filedDeclaration.findMany({
      where,
      orderBy: [{ year: "desc" }, { quarter: "desc" }, { model: "asc" }],
    });
  }

  @Post()
  async create(@Req() req: Request, @Body() dto: FiledDeclarationDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    const key = validateKey(dto);
    const data = { ...buildData(dto), ...fileData(dto) };
    // Upsert on the unique (companyId, model, year, quarter): re-filing a
    // period overwrites the previously recorded return rather than 409-ing.
    return this.prisma.filedDeclaration.upsert({
      where: {
        companyId_model_year_quarter: {
          companyId,
          model: key.model,
          year: key.year,
          quarter: key.quarter,
        },
      },
      create: { ...data, companyId },
      update: data,
    });
  }

  /** Store an uploaded AEAT return (image/PDF) in S3, returning its key. When
   *  `parse` is true, also run Gemini vision and return the pre-filled fields
   *  — used only for the first upload of a new declaration; replacing a file
   *  uploads without re-parsing. Nothing is persisted here; the client sends
   *  the returned key on save. */
  @Post("upload")
  async upload(@Req() req: Request, @Body() dto: UploadFiledDeclarationDto) {
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
      ? await parseFiledDeclarationFile(dto.data, dto.mimeType)
      : undefined;
    return { fileS3Key: key, fileMime: dto.mimeType, fileName: dto.fileName ?? null, parsed };
  }

  /** Stream the attached document's bytes through the API (same-origin, so
   *  pdf.js renders pages on mobile). Tenant-scoped by key prefix; works
   *  pre-save (the upload returns the key before a row exists). */
  @Get("raw")
  async raw(
    @Req() req: Request,
    @Res() res: Response,
    @Query("key") key?: string,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    if (!key || !key.startsWith(`filed-declarations/${companyId}/`)) {
      throw new NotFoundException();
    }
    const obj = await this.storage.getObject(key);
    res.setHeader("Content-Type", obj.contentType || "application/octet-stream");
    if (obj.contentLength) res.setHeader("Content-Length", String(obj.contentLength));
    res.setHeader("Cache-Control", "private, max-age=60");
    obj.body.pipe(res);
  }

  /** Presigned URL for the attached document. Redirects by default; with
   *  `?json=1` returns `{ url }` for the in-app preview modal (iframe). */
  @Get(":id/file")
  async file(
    @Req() req: Request,
    @Param("id") id: string,
    @Res() res: Response,
    @Query("json") json?: string,
  ): Promise<void> {
    const { companyId } = (req as AuthedRequest).authUser;
    const row = await this.prisma.filedDeclaration.findFirst({
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
    const row = await this.prisma.filedDeclaration.findFirst({
      where: { id, companyId },
    });
    if (!row) throw new NotFoundException();
    return row;
  }

  @Patch(":id")
  async update(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() dto: FiledDeclarationDto,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const key = validateKey(dto);
    const existing = await this.prisma.filedDeclaration.findFirst({
      where: { id, companyId },
      select: { id: true, fileS3Key: true },
    });
    if (!existing) throw new NotFoundException();

    // model/year/quarter stay editable, but the (companyId, model, year,
    // quarter) uniqueness must still hold — a collision with a *different*
    // row is a 400, not a silent overwrite.
    const clash = await this.prisma.filedDeclaration.findFirst({
      where: {
        companyId,
        model: key.model,
        year: key.year,
        quarter: key.quarter,
        NOT: { id },
      },
      select: { id: true },
    });
    if (clash) {
      throw new BadRequestException(
        "A declaration for this model/year/quarter already exists",
      );
    }

    const file = fileData(dto);
    // A replaced file leaves the old S3 object orphaned — delete it.
    if (existing.fileS3Key && existing.fileS3Key !== file.fileS3Key) {
      await this.storage.delete(existing.fileS3Key);
    }
    return this.prisma.filedDeclaration.update({
      where: { id },
      data: { ...buildData(dto), ...file },
    });
  }

  @Delete(":id")
  async remove(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.filedDeclaration.findFirst({
      where: { id, companyId },
      select: { id: true, fileS3Key: true },
    });
    if (!existing) throw new NotFoundException();
    if (existing.fileS3Key) await this.storage.delete(existing.fileS3Key);
    await this.prisma.filedDeclaration.delete({ where: { id } });
    return { ok: true };
  }
}

/** Round to 2 decimals, avoiding binary-float drift on .5 cases. */
function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

/** The attached-document fields, normalised (empty → null). */
function fileData(dto: FiledDeclarationDto) {
  return {
    fileS3Key: (dto.fileS3Key || "").trim() || null,
    fileMime: (dto.fileMime || "").trim() || null,
    fileName: (dto.fileName || "").trim() || null,
  };
}

/** Validate + normalise the composite unique key (model/year/quarter). */
function validateKey(dto: FiledDeclarationDto): {
  model: string;
  year: number;
  quarter: number;
} {
  const model = String(dto.model || "").trim();
  if (!MODELS.has(model)) {
    throw new BadRequestException("model must be one of 303, 130, 349");
  }
  const year = Math.trunc(Number(dto.year));
  if (!Number.isInteger(year) || year < 2000 || year > 2100) {
    throw new BadRequestException("year must be between 2000 and 2100");
  }
  const quarter = Math.trunc(Number(dto.quarter));
  if (!Number.isInteger(quarter) || quarter < 1 || quarter > 4) {
    throw new BadRequestException("quarter must be between 1 and 4");
  }
  return { model, year, quarter };
}

/** Normalise the casillas map to { box: round2(number) }, dropping any
 *  non-numeric values. */
function normalizeCasillas(raw: Record<string, unknown> | undefined): Record<string, number> {
  const out: Record<string, number> = {};
  if (!raw || typeof raw !== "object") return out;
  for (const [box, v] of Object.entries(raw)) {
    const n = typeof v === "number" ? v : Number(v);
    if (Number.isFinite(n)) out[box] = round2(n);
  }
  return out;
}

/** Compute the full persisted shape from the DTO. Single place so create and
 *  update can't diverge. resultPaid / compensarNext are kept in sync with the
 *  casillas map when the client only sends the boxes. */
function buildData(dto: FiledDeclarationDto) {
  const key = validateKey(dto);
  const casillas = normalizeCasillas(dto.casillas);

  // Derive the two carry-forward figures from casillas when the client didn't
  // send them explicitly — box 07 (130) / box 71 (303) for resultPaid, box 87
  // (303 only) for compensarNext.
  let resultPaid: number | null =
    dto.resultPaid != null ? round2(dto.resultPaid) : null;
  if (resultPaid == null) {
    const boxKey = key.model === "130" ? "07" : key.model === "303" ? "71" : null;
    if (boxKey && casillas[boxKey] != null) resultPaid = casillas[boxKey];
  }

  let compensarNext: number | null =
    dto.compensarNext != null ? round2(dto.compensarNext) : null;
  if (compensarNext == null && key.model === "303" && casillas["87"] != null) {
    compensarNext = casillas["87"];
  }

  const submittedAt = normalizeDate(dto.submittedAt);

  return {
    model: key.model,
    year: key.year,
    quarter: key.quarter,
    justificante: (dto.justificante || "").trim() || null,
    submittedAt,
    casillas: casillas as Prisma.InputJsonValue,
    resultPaid: resultPaid != null ? new Prisma.Decimal(resultPaid) : null,
    compensarNext: compensarNext != null ? new Prisma.Decimal(compensarNext) : null,
    notes: (dto.notes || "").trim() || null,
  };
}

/** Parse a YYYY-MM-DD @db.Date into a UTC-midnight Date, or null. */
function normalizeDate(v: string | undefined): Date | null {
  const s = (v || "").trim();
  if (!s) return null;
  const d = new Date(`${s.slice(0, 10)}T00:00:00.000Z`);
  if (Number.isNaN(d.getTime())) {
    throw new BadRequestException("submittedAt must be a valid YYYY-MM-DD date");
  }
  return d;
}
