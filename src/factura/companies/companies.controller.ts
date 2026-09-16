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
  Req,
  UseGuards,
} from "@nestjs/common";
import { IsString, MaxLength } from "class-validator";
import type { Request } from "express";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { CreateCompanyDto, UpdateCompanyDto } from "./dto";
import { parseAndEncrypt } from "../invoices/verifactu/cert-store";
import { evictTenantCertCache } from "../invoices/verifactu/cert-reader";

/** Fields shown to the dashboard. Excludes the encrypted blob, nonce
 *  and tag — those never leave the server. NIF / subject / issuer /
 *  expiry are safe to surface so the Settings UI can show
 *  "Loaded — NIF Z1894474S, expires 2028-07-16". */
const COMPANY_SAFE_SELECT = {
  id: true, name: true, legalName: true, taxId: true, vatId: true,
  addressLine1: true, addressLine2: true, city: true, postalCode: true,
  region: true, country: true,
  bankName: true, iban: true, swift: true,
  defaultIrpfRate: true, activityType: true, activityStartDate: true,
  invoiceNumberOffset: true, baseCurrency: true,
  onboardingStep: true,
  // Cert metadata is fine to expose; the ciphertext / nonce / tag are not.
  verifactuCertNif: true, verifactuCertSubject: true,
  verifactuCertIssuer: true, verifactuCertExpiry: true,
  createdAt: true, updatedAt: true,
} as const;

class UploadCertDto {
  @IsString() @MaxLength(50_000) p12Base64!: string;
  @IsString() @MaxLength(400)    password!: string;
}

@Controller("companies")
export class CompaniesController {
  constructor(private readonly prisma: PrismaService) {}

  /** All companies the current user belongs to. Session-only — user may
   *  have zero companies (during signup before the wizard completes). */
  @Get()
  @UseGuards(FacturaContextGuard)
  async list(@Req() req: Request) {
    const { userId } = (req as AuthedRequest).authUser;
    const rows = await this.prisma.userCompany.findMany({
      where: { userId },
      include: { company: true },
      orderBy: { createdAt: "asc" },
    });
    return rows.map((uc) => ({ ...uc.company, role: uc.role }));
  }

  /** Currently active company. Requires the user already has one.
   *  Encrypted cert material is NEVER returned — only the metadata
   *  the dashboard needs to render the status pill. */
  @Get("me")
  @UseGuards(FacturaContextGuard)
  async me(@Req() req: Request) {
    const { companyId } = (req as AuthedRequest).authUser;
    const company = await this.prisma.company.findUnique({
      where: { id: companyId },
      select: COMPANY_SAFE_SELECT,
    });
    if (!company) throw new NotFoundException("Company not found");
    return company;
  }

  @Patch("me")
  @UseGuards(FacturaContextGuard)
  async updateMe(@Req() req: Request, @Body() dto: UpdateCompanyDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    // activityStartDate comes from the dashboard as "YYYY-MM-DD" (HTML
    // <input type="date">). Prisma's DateTime column requires a JS Date
    // or full ISO-8601 string — anchor the date at UTC midnight so the
    // year boundary stays stable regardless of server timezone.
    const { activityStartDate, ...rest } = dto;
    const data: Record<string, unknown> = { ...rest };
    if (typeof data.baseCurrency === "string") {
      data.baseCurrency = data.baseCurrency.toUpperCase();
    }
    if (activityStartDate !== undefined) {
      data.activityStartDate = activityStartDate
        ? new Date(`${activityStartDate}T00:00:00.000Z`)
        : null;
    }
    return this.prisma.company.update({
      where: { id: companyId },
      data,
      select: COMPANY_SAFE_SELECT,
    });
  }

  /** Upload the tenant's FNMT signing certificate. Body carries the
   *  `.p12` base64-encoded plus the password protecting it. We parse
   *  it once (validate NIF matches Company.taxId, check it's not
   *  expired), re-encrypt the unwrapped PEM material with the service
   *  master key, and store the ciphertext on Company. The original
   *  user-typed password is discarded — submit-time decryption uses
   *  the master key alone. */
  @Post("me/verifactu-cert")
  @UseGuards(FacturaContextGuard)
  async uploadCert(@Req() req: Request, @Body() dto: UploadCertDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    const company = await this.prisma.company.findUnique({
      where: { id: companyId },
      select: { taxId: true },
    });
    if (!company) throw new NotFoundException("Company not found");

    let pfx: Buffer;
    try {
      pfx = Buffer.from(dto.p12Base64, "base64");
    } catch {
      throw new BadRequestException("p12Base64 is not valid base64");
    }
    if (pfx.length === 0 || pfx.length > 200_000) {
      throw new BadRequestException("Certificate file is empty or too large");
    }

    let enc;
    try {
      enc = parseAndEncrypt(pfx, dto.password);
    } catch (e) {
      // node-forge throws descriptive errors on wrong password / bad
      // file. We surface those as 400s so the user sees what's wrong.
      throw new BadRequestException(
        `Could not read the .p12: ${(e as Error).message}`,
      );
    }

    if (company.taxId && enc.nif !== company.taxId.toUpperCase()) {
      throw new BadRequestException(
        `The certificate's NIF (${enc.nif}) does not match this company's tax ID (${company.taxId}). Upload the cert for the obligado tributario on file, or update the company tax ID first.`,
      );
    }

    const updated = await this.prisma.company.update({
      where: { id: companyId },
      data: {
        // Cert-store отдаёт Buffer, и он же нужен полям Bytes у Prisma 5 (в исходном сервисе
        // на Prisma 6 приходилось оборачивать в Uint8Array — здесь это лишнее).
        verifactuCertCipher: enc.cipher,
        verifactuCertNonce: enc.nonce,
        verifactuCertTag: enc.tag,
        verifactuCertNif: enc.nif,
        verifactuCertSubject: enc.subject,
        verifactuCertIssuer: enc.issuer,
        verifactuCertExpiry: enc.expiry,
      },
      select: COMPANY_SAFE_SELECT,
    });
    // The decrypted PEM is cached in-process for the lifetime of the
    // node — without eviction the next submit would still sign with
    // the prior cert until the process restarts.
    evictTenantCertCache(companyId);
    return updated;
  }

  /** Wipe the stored certificate (e.g. user wants to re-upload a
   *  fresher one, or revoke access). Verifactu submit will then refuse
   *  until a new cert is uploaded. */
  @Delete("me/verifactu-cert")
  @UseGuards(FacturaContextGuard)
  async deleteCert(@Req() req: Request) {
    const { companyId } = (req as AuthedRequest).authUser;
    await this.prisma.company.update({
      where: { id: companyId },
      data: {
        verifactuCertCipher: null,
        verifactuCertNonce: null,
        verifactuCertTag: null,
        verifactuCertNif: null,
        verifactuCertSubject: null,
        verifactuCertIssuer: null,
        verifactuCertExpiry: null,
      },
    });
    evictTenantCertCache(companyId);
    return { ok: true };
  }

  /** Bootstrap a new company. Session-only — first call from a fresh
   *  account, before any company exists. */
  @Post()
  @UseGuards(FacturaContextGuard)
  async create(@Req() req: Request, @Body() dto: CreateCompanyDto) {
    const { userId } = (req as AuthedRequest).authUser;
    return this.prisma.$transaction(async (tx) => {
      const company = await tx.company.create({
        data: {
          name: dto.name,
          taxId: dto.taxId,
        },
      });
      await tx.userCompany.create({
        data: { userId, companyId: company.id, role: "OWNER" },
      });
      // Остатки регистрации на лендинге (имя компании из мастера входа) больше не нужны:
      // компания создана. Модель фактурного пользователя называется FacturaUser — в облаке
      // уже есть своя `User`.
      await tx.facturaUser.update({
        where: { id: userId },
        data: { pendingCompanyName: null },
      });
      return company;
    });
  }

  @Get(":id")
  @UseGuards(FacturaContextGuard)
  async byId(@Req() req: Request, @Param("id") id: string) {
    const { userId } = (req as AuthedRequest).authUser;
    const membership = await this.prisma.userCompany.findUnique({
      where: { userId_companyId: { userId, companyId: id } },
      include: { company: true },
    });
    if (!membership) throw new NotFoundException();
    return { ...membership.company, role: membership.role };
  }
}
