import { Injectable, Logger } from "@nestjs/common";
import { Cron, CronExpression } from "@nestjs/schedule";

import { PrismaService } from "../../prisma/prisma.service";
import { InvoicesService } from "./invoices.service";

/** Sweeps for invoices whose PDF generation failed at create time. Runs
 *  every 5 minutes and only touches invoices older than 5 minutes — the
 *  delay avoids racing with an in-flight first-attempt that just lost a
 *  network blip mid-upload. */
@Injectable()
export class InvoicesRepairCron {
  private readonly logger = new Logger(InvoicesRepairCron.name);
  private running = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly invoices: InvoicesService,
  ) {}

  @Cron(CronExpression.EVERY_5_MINUTES)
  async sweep(): Promise<void> {
    if (this.running) return; // skip overlap if the previous run is still working
    this.running = true;
    try {
      const cutoff = new Date(Date.now() - 5 * 60 * 1000);
      const stale = await this.prisma.invoice.findMany({
        where: { pdfS3Key: null, createdAt: { lt: cutoff } },
        select: { id: true, number: true },
        take: 25,
        orderBy: { createdAt: "asc" },
      });
      if (stale.length === 0) return;
      this.logger.log(`repairing ${stale.length} invoice(s) without PDF`);
      for (const inv of stale) {
        try {
          await this.invoices.generateAndStorePdf(inv.id);
        } catch (err) {
          this.logger.warn(
            `repair failed for ${inv.id} (${inv.number}): ${(err as Error).message}`,
          );
        }
      }
    } finally {
      this.running = false;
    }
  }
}
