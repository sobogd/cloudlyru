import { IsIn, IsOptional, IsString, MaxLength, IsNumber, Min, Max } from "class-validator";
import { Type } from "class-transformer";

export class CreateCompanyDto {
  @IsString()
  @MaxLength(120)
  name!: string;

  @IsOptional()
  @IsString()
  @MaxLength(50)
  taxId?: string;
}

export class UpdateCompanyDto {
  @IsOptional() @IsString() @MaxLength(120) name?: string;
  @IsOptional() @IsString() @MaxLength(120) legalName?: string;
  @IsOptional() @IsString() @MaxLength(50)  taxId?: string;
  @IsOptional() @IsString() @MaxLength(50)  vatId?: string;
  @IsOptional() @IsString() @MaxLength(160) addressLine1?: string;
  @IsOptional() @IsString() @MaxLength(160) addressLine2?: string;
  @IsOptional() @IsString() @MaxLength(80)  city?: string;
  @IsOptional() @IsString() @MaxLength(20)  postalCode?: string;
  @IsOptional() @IsString() @MaxLength(80)  region?: string;
  @IsOptional() @IsString() @MaxLength(2)   country?: string;
  @IsOptional() @IsString() @MaxLength(160) bankName?: string;
  @IsOptional() @IsString() @MaxLength(40)  iban?: string;
  @IsOptional() @IsString() @MaxLength(20)  swift?: string;
  @IsOptional() @Type(() => Number) @IsNumber() @Min(0) @Max(50) defaultIrpfRate?: number;
  @IsOptional()
  @IsString()
  @IsIn([
    "profesional",
    "empresarial",
    "modulos_empresarial",
    "modulos_agricola",
    "alquiler",
  ])
  activityType?: string;
  /** ISO date string (YYYY-MM-DD). Stored as @db.Date on the model. */
  @IsOptional() @IsString() @MaxLength(10) activityStartDate?: string;
  @IsOptional() @Type(() => Number) @IsNumber() @Min(0) @Max(3) onboardingStep?: number;
  @IsOptional() @Type(() => Number) @IsNumber() @Min(0) @Max(999_999) invoiceNumberOffset?: number;
  /** ISO 4217 default invoice currency for the account. */
  @IsOptional() @IsString() @MaxLength(3) baseCurrency?: string;
}
