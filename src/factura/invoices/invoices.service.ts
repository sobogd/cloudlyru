import { Injectable, Logger } from "@nestjs/common";
import { Prisma, Invoice, InvoiceLine, VerifactuRegistry } from "@prisma/client";
import crypto from "node:crypto";

import { PrismaService } from "../../prisma/prisma.service";
import { InvoiceEventsService } from "./invoice-events.service";
import { PdfRendererService, type InvoiceForPdf } from "./pdf/pdf-renderer.service";
import type { PdfLanguage } from "./pdf/i18n";
import {
  invoicePdfKey,
  InvoicePdfStorageService,
} from "./s3/invoice-pdf.storage";

type InvoiceWithLines = Invoice & {
  lines: InvoiceLine[];
  verifactuRegistry?: VerifactuRegistry | null;
  bankAccount?: {
    bankName: string | null;
    iban: string | null;
    swift: string | null;
  } | null;
};

/** Coordinates PDF generation and S3 upload for an invoice. Kept on its
 *  own so the controller stays a thin HTTP shell and the cron repair job
 *  can call exactly the same code path. */
@Injectable()
export class InvoicesService {
  private readonly logger = new Logger(InvoicesService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly renderer: PdfRendererService,
    private readonly storage: InvoicePdfStorageService,
    private readonly events: InvoiceEventsService,
  ) {}

  /** Render + upload the PDF for an invoice and persist its S3 key + hash.
   *  Idempotent: callable from the create flow AND from the repair cron;
   *  the second caller just rewrites the same bytes since the renderer is
   *  pure over snapshots and the issueDate-pinned CreationDate. */
  async generateAndStorePdf(invoiceId: string): Promise<void> {
    const inv = await this.prisma.invoice.findUnique({
      where: { id: invoiceId },
      include: {
        lines: { orderBy: { sortOrder: "asc" } },
        verifactuRegistry: true,
        bankAccount: true,
      },
    });
    if (!inv) {
      this.logger.warn(`generateAndStorePdf: invoice ${invoiceId} not found`);
      return;
    }
    await this.renderAndStore(inv);
  }

  /** Internal — accepts the loaded invoice (with lines) so the create
   *  path can pass through the row it just inserted without an extra
   *  round-trip. */
  async renderAndStore(inv: InvoiceWithLines): Promise<void> {
    // DRAFTs have no allocated number yet — render with a placeholder
    // so the user gets a preview PDF. The real FACT-YYYY-NNNNN is
    // stamped on the regenerated PDF after a successful AEAT submit.
    const displayNumber = inv.number ?? "DRAFT";
    const payload: InvoiceForPdf = {
      number: displayNumber,
      issueDate: inv.issueDate,
      dueDate: inv.dueDate,
      language: assertLanguage(inv.language),
      currency: inv.currency,
      vatRate: Number(inv.vatRate),
      irpfRate: Number(inv.irpfRate),
      netAmount: Number(inv.netAmount),
      vatAmount: Number(inv.vatAmount),
      irpfAmount: Number(inv.irpfAmount),
      totalAmount: Number(inv.totalAmount),
      toPayAmount: Number(inv.toPayAmount),
      notes: inv.notes,
      legalNoteCode: inv.legalNoteCode,
      contactSnapshot: inv.contactSnapshot as never,
      emitterSnapshot: inv.emitterSnapshot as never,
      bankAccount: inv.bankAccount
        ? {
            bankName: inv.bankAccount.bankName,
            iban: inv.bankAccount.iban,
            swift: inv.bankAccount.swift,
          }
        : null,
      lines: inv.lines.map((l) => ({
        description: l.description,
        quantity: Number(l.quantity),
        unit: l.unit,
        unitPrice: Number(l.unitPrice),
        total: Number(l.total),
      })),
      verifactu: inv.verifactuRegistry
        ? {
            qrUrl: inv.verifactuRegistry.qrUrl,
            chainHashTail: inv.verifactuRegistry.currentHash.slice(-8),
          }
        : undefined,
    };

    const buffer = await this.renderer.render(payload);
    const sha256 = crypto.createHash("sha256").update(buffer).digest("hex");
    // S3 key uses the invoice id when number isn't allocated yet so
    // draft PDFs land in a stable spot; once a real number is
    // allocated post-submit, the next render lands at a NEW key under
    // the FACT-YYYY-NNNNN naming and the draft-keyed PDF becomes an
    // orphan we clean up below.
    const key = invoicePdfKey({
      companyId: inv.companyId,
      serialYear: inv.serialYear,
      serialIndex: inv.serialIndex ?? 0,
      number: inv.number ?? `draft-${inv.id}`,
    });

    await this.storage.upload({
      key,
      body: buffer,
      invoiceNumber: displayNumber,
    });

    const previousKey = inv.pdfS3Key;

    await this.prisma.invoice.update({
      where: { id: inv.id },
      data: {
        pdfS3Key: key,
        pdfSha256: sha256,
        pdfGeneratedAt: new Date(),
      },
    });

    // Delete the prior PDF if the key moved (draft → numbered). We log
    // and swallow delete errors — the row already points at the fresh
    // object, so a stuck orphan in S3 is a billing annoyance rather
    // than a correctness problem.
    if (previousKey && previousKey !== key) {
      try {
        await this.storage.delete(previousKey);
      } catch (err) {
        this.logger.warn(
          `Failed to delete orphan PDF ${previousKey}: ${(err as Error).message}`,
        );
      }
    }

    await this.events.log({
      invoiceId: inv.id,
      companyId: inv.companyId,
      type: "PDF_GENERATED",
      outcome: "info",
      summary: `PDF rendered — ${buffer.length} bytes${inv.verifactuRegistry ? " (with QR)" : " (no QR — DRAFT)"}`,
      payload: { pdfS3Key: key, sha256, bytes: buffer.length },
    });
  }
}

/** Defensive cast: the column is a plain TEXT, but the renderer expects
 *  the discriminated union. Unknown language strings fall back to "en"
 *  so a malformed row still produces a readable PDF. */
function assertLanguage(raw: string): PdfLanguage {
  // Legacy rows may carry "en_eu" — collapse to "en" since the EU
  // intracomunitaria distinction now lives on legalNoteCode, not on
  // the document language.
  return raw === "es" ? "es" : "en";
}

// Re-export so the controller doesn't have to import the Prisma type
// directly when handling raw create payloads from the existing flow.
export type { InvoiceWithLines };
export type CreateInvoiceData = Prisma.InvoiceCreateInput;
