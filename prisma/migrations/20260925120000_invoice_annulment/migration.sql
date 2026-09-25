-- Аннуляция фактур (VeriFactu RegistroAnulacion, RD 1007/2023).
--
-- Invoice.annulledAt помечает отправленную фактуру как аннулированную (движок деклараций
-- её пропускает). VerifactuRegistry получает дискриминатор kind и ссылку annulledInvoiceId,
-- чтобы запись об аннулировании стояла в цепочке отдельной строкой, не привязанной к новой
-- фактуре: ALTA-строка остаётся, ANULACION-строка ссылается на неё.

-- AlterTable: invoices
ALTER TABLE "invoices" ADD COLUMN "annulledAt" TIMESTAMP(3);

-- AlterTable: verifactu_registries
ALTER TABLE "verifactu_registries" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'ALTA';
ALTER TABLE "verifactu_registries" ALTER COLUMN "invoiceId" DROP NOT NULL;
ALTER TABLE "verifactu_registries" ADD COLUMN "annulledInvoiceId" TEXT;

-- AddForeignKey
ALTER TABLE "verifactu_registries" ADD CONSTRAINT "verifactu_registries_annulledInvoiceId_fkey" FOREIGN KEY ("annulledInvoiceId") REFERENCES "invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- CreateIndex (one annulment per invoice)
CREATE UNIQUE INDEX "verifactu_registries_annulledInvoiceId_key" ON "verifactu_registries"("annulledInvoiceId");
