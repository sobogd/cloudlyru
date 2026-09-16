-- Фактуры (перенесено из отдельного сервиса iq-factura).
--
-- Только создание: enum Role и 13 таблиц с теми же именами, что были в базе `iq_factura`.
-- Данные переезжают отдельным шагом (pg_dump --data-only), поэтому имена, типы и индексы
-- обязаны совпадать с источником один в один — иначе восстановление не сойдётся.
--
-- Почему файл отредактирован руками: `prisma migrate dev` добавил в него ещё и «ремонт»
-- расхождения истории миграций со схемой — DROP TABLE "Device"/"DeviceCommand"/"DeviceEntry"
-- (407 строк в проде) и DROP INDEX "MediaMeta_capturedAt_idx". Это не часть переноса фактур:
-- удалять чужие данные и индекс миграцией раздела — заведомо не то, чего ждёт владелец.
-- Расхождение остаётся как было, отдельным решением.

-- CreateEnum
CREATE TYPE "Role" AS ENUM ('OWNER', 'ADMIN', 'MEMBER');

-- CreateTable
CREATE TABLE "users" (
    "id" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "otp" TEXT,
    "otpExpiresAt" TIMESTAMP(3),
    "otpAttempts" INTEGER NOT NULL DEFAULT 0,
    "sessionToken" TEXT,
    "preferredLocale" TEXT,
    "pendingCompanyName" TEXT,
    "pendingTaxId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "sessions" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "userAgent" TEXT,
    "ip" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),

    CONSTRAINT "sessions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "users_companies" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "role" "Role" NOT NULL DEFAULT 'OWNER',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "users_companies_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "companies" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "legalName" TEXT,
    "taxId" TEXT,
    "vatId" TEXT,
    "addressLine1" TEXT,
    "addressLine2" TEXT,
    "city" TEXT,
    "postalCode" TEXT,
    "region" TEXT,
    "country" TEXT,
    "bankName" TEXT,
    "iban" TEXT,
    "swift" TEXT,
    "defaultIrpfRate" DECIMAL(5,2),
    "activityType" TEXT,
    "activityStartDate" DATE,
    "invoiceNumberOffset" INTEGER NOT NULL DEFAULT 0,
    "baseCurrency" TEXT NOT NULL DEFAULT 'EUR',
    "onboardingStep" INTEGER NOT NULL DEFAULT 0,
    "verifactuCertCipher" BYTEA,
    "verifactuCertNonce" BYTEA,
    "verifactuCertTag" BYTEA,
    "verifactuCertNif" TEXT,
    "verifactuCertExpiry" TIMESTAMP(3),
    "verifactuCertSubject" TEXT,
    "verifactuCertIssuer" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "companies_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "bank_accounts" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "label" TEXT,
    "bankName" TEXT,
    "iban" TEXT,
    "swift" TEXT,
    "currency" TEXT,
    "isDefault" BOOLEAN NOT NULL DEFAULT false,
    "archivedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "bank_accounts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "contacts" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "taxId" TEXT,
    "countryCode" TEXT,
    "isEu" BOOLEAN NOT NULL DEFAULT false,
    "nature" TEXT NOT NULL DEFAULT 'service',
    "esNoIva" BOOLEAN NOT NULL DEFAULT false,
    "email" TEXT,
    "currency" TEXT,
    "addressLine1" TEXT,
    "addressLine2" TEXT,
    "postalCode" TEXT,
    "city" TEXT,
    "region" TEXT,
    "notes" TEXT,
    "archivedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "contacts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "invoices" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "contactId" TEXT,
    "bankAccountId" TEXT,
    "number" TEXT,
    "serialYear" INTEGER NOT NULL,
    "serialIndex" INTEGER,
    "series" TEXT NOT NULL DEFAULT 'FACT',
    "issueDate" DATE NOT NULL,
    "dueDate" DATE,
    "contactSnapshot" JSONB NOT NULL,
    "emitterSnapshot" JSONB NOT NULL,
    "currency" TEXT NOT NULL DEFAULT 'EUR',
    "language" TEXT NOT NULL DEFAULT 'en',
    "nature" TEXT NOT NULL DEFAULT 'service',
    "vatRate" DECIMAL(5,2) NOT NULL,
    "irpfRate" DECIMAL(5,2) NOT NULL DEFAULT 0,
    "netAmount" DECIMAL(12,2) NOT NULL,
    "vatAmount" DECIMAL(12,2) NOT NULL,
    "irpfAmount" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "totalAmount" DECIMAL(12,2) NOT NULL,
    "toPayAmount" DECIMAL(12,2) NOT NULL,
    "netAmountEur" DECIMAL(12,2),
    "vatAmountEur" DECIMAL(12,2),
    "totalAmountEur" DECIMAL(12,2),
    "fxRate" DECIMAL(18,8),
    "fxRateDate" DATE,
    "status" TEXT NOT NULL DEFAULT 'DRAFT',
    "paid" BOOLEAN NOT NULL DEFAULT false,
    "paidAt" TIMESTAMP(3),
    "paymentMethod" TEXT,
    "description" TEXT NOT NULL,
    "notes" TEXT,
    "legalNoteCode" TEXT,
    "pdfS3Key" TEXT,
    "pdfGeneratedAt" TIMESTAMP(3),
    "pdfSha256" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "invoices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "invoice_events" (
    "id" TEXT NOT NULL,
    "invoiceId" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "outcome" TEXT NOT NULL,
    "summary" TEXT NOT NULL,
    "payload" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "invoice_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "invoice_lines" (
    "id" TEXT NOT NULL,
    "invoiceId" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "description" TEXT NOT NULL,
    "quantity" DECIMAL(12,2) NOT NULL DEFAULT 1,
    "unit" TEXT,
    "unitPrice" DECIMAL(12,2) NOT NULL,
    "total" DECIMAL(12,2) NOT NULL,
    "totalEur" DECIMAL(12,2),

    CONSTRAINT "invoice_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "expenses" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "supplierName" TEXT NOT NULL,
    "supplierTaxId" TEXT,
    "supplierCountryCode" TEXT,
    "supplierIsEu" BOOLEAN NOT NULL DEFAULT false,
    "nature" TEXT NOT NULL DEFAULT 'service',
    "supplierEsNoIva" BOOLEAN NOT NULL DEFAULT false,
    "issueDate" DATE NOT NULL,
    "kind" TEXT NOT NULL DEFAULT 'invoice',
    "category" TEXT,
    "description" TEXT,
    "notes" TEXT,
    "currency" TEXT NOT NULL DEFAULT 'EUR',
    "netAmount" DECIMAL(12,2) NOT NULL,
    "vatRate" DECIMAL(5,2) NOT NULL DEFAULT 21,
    "vatAmount" DECIMAL(12,2) NOT NULL,
    "irpfRate" DECIMAL(5,2) NOT NULL DEFAULT 0,
    "irpfAmount" DECIMAL(12,2) NOT NULL DEFAULT 0,
    "totalAmount" DECIMAL(12,2) NOT NULL,
    "netAmountEur" DECIMAL(12,2),
    "vatAmountEur" DECIMAL(12,2),
    "totalAmountEur" DECIMAL(12,2),
    "fxRate" DECIMAL(18,8),
    "fxRateDate" DATE,
    "deductibleVatPct" DECIMAL(5,2) NOT NULL DEFAULT 100,
    "deductibleForIrpf" BOOLEAN NOT NULL DEFAULT true,
    "reverseCharge" BOOLEAN NOT NULL DEFAULT false,
    "fileS3Key" TEXT,
    "fileMime" TEXT,
    "fileName" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "expenses_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "filed_declarations" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "year" INTEGER NOT NULL,
    "quarter" INTEGER NOT NULL,
    "justificante" TEXT,
    "submittedAt" DATE,
    "casillas" JSONB NOT NULL DEFAULT '{}',
    "resultPaid" DECIMAL(12,2),
    "compensarNext" DECIMAL(12,2),
    "fileS3Key" TEXT,
    "fileMime" TEXT,
    "fileName" TEXT,
    "notes" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "filed_declarations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "support_messages" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "message" TEXT NOT NULL,
    "isAdmin" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "support_messages_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "verifactu_registries" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "invoiceId" TEXT NOT NULL,
    "sequenceNumber" INTEGER NOT NULL,
    "previousHash" TEXT NOT NULL,
    "currentHash" TEXT NOT NULL,
    "hashInput" TEXT NOT NULL,
    "tipoFactura" TEXT NOT NULL DEFAULT 'F1',
    "qrUrl" TEXT NOT NULL,
    "aeatStatus" TEXT NOT NULL DEFAULT 'PENDING',
    "aeatSubmittedAt" TIMESTAMP(3),
    "aeatResponseCode" TEXT,
    "aeatResponseRaw" JSONB,
    "aeatRetryCount" INTEGER NOT NULL DEFAULT 0,
    "signedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "verifactu_registries_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "users_email_key" ON "users"("email");

-- CreateIndex
CREATE UNIQUE INDEX "sessions_tokenHash_key" ON "sessions"("tokenHash");

-- CreateIndex
CREATE INDEX "sessions_userId_idx" ON "sessions"("userId");

-- CreateIndex
CREATE INDEX "users_companies_companyId_idx" ON "users_companies"("companyId");

-- CreateIndex
CREATE UNIQUE INDEX "users_companies_userId_companyId_key" ON "users_companies"("userId", "companyId");

-- CreateIndex
CREATE INDEX "bank_accounts_companyId_idx" ON "bank_accounts"("companyId");

-- CreateIndex
CREATE INDEX "bank_accounts_companyId_archivedAt_idx" ON "bank_accounts"("companyId", "archivedAt");

-- CreateIndex
CREATE INDEX "contacts_companyId_idx" ON "contacts"("companyId");

-- CreateIndex
CREATE INDEX "contacts_companyId_archivedAt_idx" ON "contacts"("companyId", "archivedAt");

-- CreateIndex
CREATE INDEX "invoices_companyId_issueDate_idx" ON "invoices"("companyId", "issueDate");

-- CreateIndex
CREATE INDEX "invoices_companyId_paid_idx" ON "invoices"("companyId", "paid");

-- CreateIndex
CREATE UNIQUE INDEX "invoices_companyId_number_key" ON "invoices"("companyId", "number");

-- CreateIndex
CREATE UNIQUE INDEX "invoices_companyId_serialYear_serialIndex_key" ON "invoices"("companyId", "serialYear", "serialIndex");

-- CreateIndex
CREATE INDEX "invoice_events_invoiceId_createdAt_idx" ON "invoice_events"("invoiceId", "createdAt");

-- CreateIndex
CREATE INDEX "invoice_events_companyId_createdAt_idx" ON "invoice_events"("companyId", "createdAt");

-- CreateIndex
CREATE INDEX "invoice_events_companyId_type_idx" ON "invoice_events"("companyId", "type");

-- CreateIndex
CREATE INDEX "invoice_lines_invoiceId_idx" ON "invoice_lines"("invoiceId");

-- CreateIndex
CREATE INDEX "expenses_companyId_issueDate_idx" ON "expenses"("companyId", "issueDate");

-- CreateIndex
CREATE INDEX "filed_declarations_companyId_year_idx" ON "filed_declarations"("companyId", "year");

-- CreateIndex
CREATE UNIQUE INDEX "filed_declarations_companyId_model_year_quarter_key" ON "filed_declarations"("companyId", "model", "year", "quarter");

-- CreateIndex
CREATE INDEX "support_messages_companyId_createdAt_idx" ON "support_messages"("companyId", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "verifactu_registries_invoiceId_key" ON "verifactu_registries"("invoiceId");

-- CreateIndex
CREATE INDEX "verifactu_registries_companyId_signedAt_idx" ON "verifactu_registries"("companyId", "signedAt");

-- CreateIndex
CREATE INDEX "verifactu_registries_aeatStatus_aeatRetryCount_idx" ON "verifactu_registries"("aeatStatus", "aeatRetryCount");

-- CreateIndex
CREATE UNIQUE INDEX "verifactu_registries_companyId_sequenceNumber_key" ON "verifactu_registries"("companyId", "sequenceNumber");

-- AddForeignKey
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "users_companies" ADD CONSTRAINT "users_companies_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "users_companies" ADD CONSTRAINT "users_companies_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "bank_accounts" ADD CONSTRAINT "bank_accounts_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "contacts" ADD CONSTRAINT "contacts_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "invoices" ADD CONSTRAINT "invoices_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "invoices" ADD CONSTRAINT "invoices_contactId_fkey" FOREIGN KEY ("contactId") REFERENCES "contacts"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "invoices" ADD CONSTRAINT "invoices_bankAccountId_fkey" FOREIGN KEY ("bankAccountId") REFERENCES "bank_accounts"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "invoice_events" ADD CONSTRAINT "invoice_events_invoiceId_fkey" FOREIGN KEY ("invoiceId") REFERENCES "invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "invoice_lines" ADD CONSTRAINT "invoice_lines_invoiceId_fkey" FOREIGN KEY ("invoiceId") REFERENCES "invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "expenses" ADD CONSTRAINT "expenses_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "filed_declarations" ADD CONSTRAINT "filed_declarations_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "support_messages" ADD CONSTRAINT "support_messages_companyId_fkey" FOREIGN KEY ("companyId") REFERENCES "companies"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "support_messages" ADD CONSTRAINT "support_messages_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "verifactu_registries" ADD CONSTRAINT "verifactu_registries_invoiceId_fkey" FOREIGN KEY ("invoiceId") REFERENCES "invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE;
