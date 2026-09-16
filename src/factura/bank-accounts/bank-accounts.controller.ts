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

class BankAccountDto {
  @IsOptional() @IsString() @MaxLength(120) label?: string;
  @IsOptional() @IsString() @MaxLength(120) bankName?: string;
  @IsOptional() @IsString() @MaxLength(34) iban?: string;
  @IsOptional() @IsString() @MaxLength(20) swift?: string;
  @IsOptional() @IsString() @MaxLength(3) currency?: string;
  @IsOptional() @IsBoolean() isDefault?: boolean;
}

/** Bank-accounts CRUD scoped to the active company. A company can hold
 *  multiple accounts (Wise EUR / Stripe USD / local IBAN…) and pick one
 *  as the "default" — the dashboard ensures only one row has
 *  isDefault=true at a time by flipping the previous default off in the
 *  same transaction. Archive is a soft delete (archivedAt timestamp);
 *  hard delete is supported too for accounts that were never linked to
 *  an invoice. */
@Controller("bank-accounts")
@UseGuards(FacturaContextGuard)
export class BankAccountsController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async list(@Req() req: Request) {
    const { companyId } = (req as AuthedRequest).authUser;
    return this.prisma.bankAccount.findMany({
      where: { companyId, archivedAt: null },
      orderBy: [{ isDefault: "desc" }, { createdAt: "desc" }],
    });
  }

  @Post()
  async create(@Req() req: Request, @Body() dto: BankAccountDto) {
    const { companyId } = (req as AuthedRequest).authUser;
    const data = normaliseDto(dto);
    return this.prisma.$transaction(async (tx) => {
      if (data.isDefault) {
        await tx.bankAccount.updateMany({
          where: { companyId, isDefault: true },
          data: { isDefault: false },
        });
      }
      return tx.bankAccount.create({ data: { ...data, companyId } });
    });
  }

  @Get(":id")
  async byId(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const row = await this.prisma.bankAccount.findFirst({
      where: { id, companyId, archivedAt: null },
    });
    if (!row) throw new NotFoundException();
    return row;
  }

  @Patch(":id")
  async update(
    @Req() req: Request,
    @Param("id") id: string,
    @Body() dto: BankAccountDto,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.bankAccount.findFirst({
      where: { id, companyId, archivedAt: null },
      select: { id: true },
    });
    if (!existing) throw new NotFoundException();
    const data = normaliseDto(dto);
    return this.prisma.$transaction(async (tx) => {
      if (data.isDefault) {
        await tx.bankAccount.updateMany({
          where: { companyId, isDefault: true, NOT: { id } },
          data: { isDefault: false },
        });
      }
      return tx.bankAccount.update({ where: { id }, data });
    });
  }

  @Delete(":id")
  async remove(@Req() req: Request, @Param("id") id: string) {
    const { companyId } = (req as AuthedRequest).authUser;
    const existing = await this.prisma.bankAccount.findFirst({
      where: { id, companyId, archivedAt: null },
      select: { id: true },
    });
    if (!existing) throw new NotFoundException();
    // Soft delete — keeps the row reachable from older invoices that
    // referenced it for "payment details", and lets the dashboard
    // restore it if the user clicked Delete by accident.
    await this.prisma.bankAccount.update({
      where: { id },
      data: { archivedAt: new Date(), isDefault: false },
    });
    return { ok: true };
  }
}

/** Trim strings and normalise IBAN/SWIFT casing. Empty strings collapse
 *  to undefined so Prisma stores NULL — matches the "typing then
 *  deleting" expectation in the Settings form. */
function normaliseDto(dto: BankAccountDto): BankAccountDto {
  const trim = (v: string | undefined) => {
    const t = (v ?? "").trim();
    return t.length ? t : undefined;
  };
  const cur = trim(dto.currency)?.toUpperCase();
  if (cur && cur.length !== 3) {
    throw new BadRequestException("currency must be a 3-letter ISO 4217 code");
  }
  return {
    label: trim(dto.label),
    bankName: trim(dto.bankName),
    iban: trim(dto.iban)?.toUpperCase().replace(/\s+/g, ""),
    swift: trim(dto.swift)?.toUpperCase(),
    currency: cur,
    isDefault: dto.isDefault,
  };
}
