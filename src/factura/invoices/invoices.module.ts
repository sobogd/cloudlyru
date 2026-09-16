import { Module } from "@nestjs/common";
import { InvoicesController } from "./invoices.controller";
import { InvoicesService } from "./invoices.service";
import { InvoicesRepairCron } from "./invoices.repair.cron";
import { PdfRendererService } from "./pdf/pdf-renderer.service";
import { InvoicePdfStorageService } from "./s3/invoice-pdf.storage";
import { VerifactuService } from "./verifactu/verifactu.service";
import { VerifactuSubmitService } from "./verifactu/submit.service";
import { InvoiceEventsService } from "./invoice-events.service";

@Module({
  controllers: [InvoicesController],
  providers: [
    InvoicesService,
    PdfRendererService,
    InvoicePdfStorageService,
    InvoicesRepairCron,
    VerifactuService,
    VerifactuSubmitService,
    InvoiceEventsService,
  ],
})
export class InvoicesModule {}
