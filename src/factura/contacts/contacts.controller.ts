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
import type { Request } from "express";
import { IsBoolean, IsOptional, IsString, MaxLength } from "class-validator";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { parseContactText } from "./contacts-parse";
import { classifyTerritory } from "../tax/territory";
import { validateNifIva, withCountryPrefix } from "../tax/nif-validation";

class ParseDto {
  @IsString() @MaxLength(4000) text!: string;
}

class ContactDto {
  @IsString() @MaxLength(160) name!: string;
  @IsOptional() @IsString() @MaxLength(60) taxId?: string;
  @IsOptional() @IsString() @MaxLength(2) countryCode?: string;
  /** "goods" | "service" — default kind of supply billed to this client.
   *  Drives 349 clave E (goods) vs S (services). Default service. */
  @IsOptional() @IsString() @MaxLength(10) nature?: string;
  /** Client in Canarias / Ceuta / Melilla (ES outside the IVA zone). */
  @IsOptional() @IsBoolean() esNoIva?: boolean;
  @IsOptional() @IsString() @MaxLength(160) email?: string;
  @IsOptional() @IsString() @MaxLength(200) addressLine1?: string;
  @IsOptional() @IsString() @MaxLength(200) addressLine2?: string;
  @IsOptional() @IsString() @MaxLength(20) postalCode?: string;
  @IsOptional() @IsString() @MaxLength(120) city?: string;
  @IsOptional() @IsString() @MaxLength(120) region?: string;
  @IsOptional() @IsString() @MaxLength(2000) notes?: string;
  /** ISO 4217 currency this client is invoiced in. Null/empty = use the
   *  account's base currency. */
  @IsOptional() @IsString() @MaxLength(3) currency?: string;
}

/** Per-company contacts (recipients of invoices). Stored as plain
 *  structured fields — no LLM cleanup. The invoice flow copies these
 *  straight into contactSnapshot at issue time. */
@Controller("contacts")
@UseGuards(FacturaContextGuard)
export class ContactsController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async list(@Req() req: Request) {
    const { companyId } = (req as AuthedRequest).authUser;
    const [contacts, stats] = await Promise.all([
      this.prisma.contact.findMany({
        where: { companyId, archivedAt: null },
        orderBy: [{ name: "asc" }],
      }),
      this.prisma.invoice.groupBy({
        by: ["contactId"],
        where: { companyId, contactId: { not: null } },
        _count: { _all: true },
        _sum: { totalAmount: true },
      }),
    ]);

    const statsByContact = new Map<
      string,
      { invoiceCount: number; invoiceTotal: number }
    >();
    for (const s of stats) {
      if (!s.contactId) continue;
      statsByContact.set(s.contactId, {
        invoiceCount: s._count._all,
        invoiceTotal: Number(s._sum.totalAmount ?? 0),
      });
    }

    return contacts.map((c) => ({
      ...c,
      invoiceCount: statsByContact.get(c.id)?.invoiceCount ?? 0,
      invoiceTotal: statsByContact.get(c.id)?.invoiceTotal ?? 0,
    }));
  }

  /** Best-effort structured parse of free-form text — used by the
   *  recipient form's "Paste anything" assist. The user still edits
   *  every field after; we never auto-save this. */
  @Post("parse")
  async parse(@Body() dto: ParseDto) {
    return parseContactText(dto.text);
  }

  @Post()
  async create(@Req() req: Request, @Body() dto: ContactDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    const data = normaliseDto(dto);
    return this.prisma.contact.create({
      data: {
        companyId,
        ...data,
        isEu: isEuCountry(data.countryCode),
      },
    });
  }

  @Get(":id")
  async byId(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const c = await this.prisma.contact.findFirst({
      where: { id, companyId, archivedAt: null },
    });
    if (!c) throw new NotFoundException();
    return c;
  }

  @Patch(":id")
  async update(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() dto: Partial<ContactDto>,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.contact.findFirst({
      where: { id, companyId, archivedAt: null },
    });
    if (!existing) throw new NotFoundException();

    const data = normaliseDto({
      name: dto.name ?? existing.name,
      taxId: dto.taxId ?? existing.taxId ?? undefined,
      countryCode: dto.countryCode ?? existing.countryCode ?? undefined,
      nature: dto.nature ?? existing.nature ?? undefined,
      esNoIva: dto.esNoIva ?? existing.esNoIva ?? undefined,
      email: dto.email ?? existing.email ?? undefined,
      addressLine1: dto.addressLine1 ?? existing.addressLine1 ?? undefined,
      addressLine2: dto.addressLine2 ?? existing.addressLine2 ?? undefined,
      postalCode: dto.postalCode ?? existing.postalCode ?? undefined,
      city: dto.city ?? existing.city ?? undefined,
      region: dto.region ?? existing.region ?? undefined,
      notes: dto.notes ?? existing.notes ?? undefined,
      currency: dto.currency ?? existing.currency ?? undefined,
    });

    return this.prisma.contact.update({
      where: { id },
      data: {
        ...data,
        isEu: isEuCountry(data.countryCode),
      },
    });
  }

  @Delete(":id")
  async archive(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const c = await this.prisma.contact.findFirst({
      where: { id, companyId, archivedAt: null },
    });
    if (!c) throw new NotFoundException();
    await this.prisma.contact.update({
      where: { id },
      data: { archivedAt: new Date() },
    });
    return { ok: true };
  }
}

interface NormalisedContact {
  name: string;
  taxId: string | null;
  countryCode: string | null;
  nature: string;
  esNoIva: boolean;
  email: string | null;
  addressLine1: string | null;
  addressLine2: string | null;
  postalCode: string | null;
  city: string | null;
  region: string | null;
  notes: string | null;
  currency: string | null;
}

function normaliseDto(
  dto: Partial<ContactDto> & { name: string },
): NormalisedContact {
  const trim = (v: string | undefined | null) => {
    const t = (v ?? "").trim();
    return t.length ? t : null;
  };
  const cc = trim(dto.countryCode)?.toUpperCase() ?? null;
  if (cc && cc.length !== 2) {
    throw new BadRequestException("countryCode must be ISO 3166-1 alpha-2");
  }
  const name = trim(dto.name);
  if (!name) throw new BadRequestException("name is required");
  const nature = dto.nature === "goods" ? "goods" : "service";
  const esNoIva = dto.esNoIva === true;
  let taxId = trim(dto.taxId)?.toUpperCase() ?? null;

  // NIF-IVA checksum guard for intra-EU clients (349-3), same as expenses.
  // The country lives in its own field, so users type the bare number —
  // normalise to the prefixed form (IT03074440805) before validating; the
  // prefixed form is also what the 349 and VIES need, so store it.
  const territory = classifyTerritory(cc, nature, new Date(), { esNoIva });
  if (territory === "EU" && taxId) {
    taxId = withCountryPrefix(taxId, cc);
    const check = validateNifIva(taxId);
    if (!check.valid) {
      throw new BadRequestException(
        `Invalid intra-EU VAT id "${taxId}"${check.reason ? ` (${check.reason})` : ""}.`,
      );
    }
    taxId = check.normalized;
  }

  return {
    name,
    taxId,
    countryCode: cc,
    nature,
    esNoIva,
    email: trim(dto.email),
    addressLine1: trim(dto.addressLine1),
    addressLine2: trim(dto.addressLine2),
    postalCode: trim(dto.postalCode),
    city: trim(dto.city),
    region: trim(dto.region),
    notes: trim(dto.notes),
    currency: trim(dto.currency)?.toUpperCase() ?? null,
  };
}

function isEuCountry(code: string | null): boolean {
  if (!code) return false;
  // ES is the issuer-home country here, so it doesn't count as
  // intra-community for the reverse-charge note logic.
  return classifyTerritory(code, "service", new Date()) === "EU";
}
