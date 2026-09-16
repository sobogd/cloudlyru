import { Body, Controller, Post, Req, UseGuards } from "@nestjs/common";
import type { Request } from "express";
import { IsOptional, IsString, MaxLength } from "class-validator";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { PrismaService } from "../../prisma/prisma.service";
import { validateNifIva } from "./nif-validation";
import { checkViesApprox } from "./vies-client";

class VatCheckDto {
  @IsString() @MaxLength(40) vat!: string;
}

/** VAT-id verification used by the contact / expense forms. Two layers:
 *  a local checksum (instant, offline — catches typos and OCR errors) and,
 *  when the checksum passes, an online VIES lookup (confirms the number is
 *  actually registered, and returns a `requestIdentifier` we keep as proof).
 *  VIES is frequently down, so its errors are soft — the UI shows "could not
 *  verify online", never blocks. */
@Controller("tax")
@UseGuards(FacturaContextGuard)
export class TaxController {
  constructor(private readonly prisma: PrismaService) {}

  @Post("vat-check")
  async vatCheck(@Req() req: Request, @Body() dto: VatCheckDto) {
    const vat = (dto.vat || "").trim().toUpperCase();
    const checksum = validateNifIva(vat);
    if (!checksum.valid) {
      return { checksum, vies: null };
    }

    // Use the tenant's own VAT id as the requester so VIES issues a
    // consultation identifier (legal proof of the check on this date).
    const { companyId } = (req as AuthedRequest).authUser;
    const company = await this.prisma.company.findUnique({
      where: { id: companyId },
      select: { vatId: true, taxId: true },
    });
    const requesterVat = (company?.vatId || "").trim().toUpperCase() || undefined;

    const vies = await checkViesApprox(
      checksum.normalized,
      new Date().toISOString(),
      requesterVat,
    );
    return { checksum, vies };
  }
}
