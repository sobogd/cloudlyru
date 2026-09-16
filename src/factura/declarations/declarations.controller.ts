import {
  BadRequestException,
  Controller,
  Get,
  Query,
  Req,
  UseGuards,
} from "@nestjs/common";
import type { Request } from "express";
import { FacturaContextGuard, type AuthedRequest } from "../factura-context";
import { DeclarationsService } from "./declarations.service";

/** Quarterly-declarations helper. Reads the company's issued invoices and
 *  logged expenses for the requested quarter and returns the figures for
 *  Modelos 303 / 130 / 349 — which apply and what goes in each box. It is
 *  an assistant, not an official filing channel. */
@Controller("declarations")
@UseGuards(FacturaContextGuard)
export class DeclarationsController {
  constructor(private readonly declarations: DeclarationsService) {}

  @Get()
  async get(
    @Req() req: Request,
    @Query("year") yearRaw?: string,
    @Query("quarter") quarterRaw?: string,
  ) {
    const { companyId } = (req as AuthedRequest).authUser;
    const year = Number(yearRaw);
    const quarter = Number(quarterRaw);
    if (!Number.isInteger(year) || year < 2000 || year > 2100) {
      throw new BadRequestException("year must be a 4-digit year");
    }
    if (![1, 2, 3, 4].includes(quarter)) {
      throw new BadRequestException("quarter must be 1, 2, 3 or 4");
    }
    return this.declarations.compute(companyId, year, quarter as 1 | 2 | 3 | 4);
  }
}
