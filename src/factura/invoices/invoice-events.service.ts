import { Injectable, Logger } from "@nestjs/common";
import { Prisma } from "@prisma/client";

import { PrismaService } from "../../prisma/prisma.service";

/** Closed set of event types written to the timeline. New values are
 *  added by extending the union — the DB column is plain string so
 *  no migration needed. */
export type InvoiceEventType =
  | "INVOICE_CREATED"
  | "INVOICE_UPDATED"
  | "PDF_GENERATED"
  | "VERIFACTU_SUBMIT_REQUEST"
  | "VERIFACTU_SUBMIT_RESPONSE"
  | "VERIFACTU_SUBMIT_REJECTED"
  | "VERIFACTU_SUBMIT_NETWORK_ERROR"
  | "VERIFACTU_REGISTRY_ROLLBACK"
  | "VERIFACTU_MANUAL_CONFIRM"
  | "VERIFACTU_MANUAL_CANCEL";

export type InvoiceEventOutcome = "ok" | "error" | "info";

export interface LogEventInput {
  invoiceId: string;
  companyId: string;
  type: InvoiceEventType;
  outcome: InvoiceEventOutcome;
  summary: string;
  /** Raw XML / parsed AEAT result / input DTO / whatever the caller
   *  considers forensically relevant. Stored verbatim. */
  payload?: unknown;
}

/** Thin wrapper around prisma.invoiceEvent.create. Two reasons it
 *  exists as a service rather than being inlined into callers:
 *
 *   1. Centralised error swallowing — a failed event write must
 *      never abort the user-facing flow. We log and move on.
 *   2. Future hooks: ship-to-stdout JSON logger, push to Sentry on
 *      outcome=error, etc. Adding those without touching every call
 *      site keeps the audit story consistent. */
@Injectable()
export class InvoiceEventsService {
  private readonly logger = new Logger(InvoiceEventsService.name);

  constructor(private readonly prisma: PrismaService) {}

  async log(input: LogEventInput): Promise<void> {
    try {
      await this.prisma.invoiceEvent.create({
        data: {
          invoiceId: input.invoiceId,
          companyId: input.companyId,
          type: input.type,
          outcome: input.outcome,
          summary: input.summary,
          payload:
            input.payload === undefined
              ? Prisma.JsonNull
              : (input.payload as Prisma.InputJsonValue),
        },
      });
    } catch (err) {
      // Audit failure isn't fatal — the user-facing operation already
      // succeeded (or already failed for its own reason). We log to
      // pm2 so this isn't silently swallowed forever.
      this.logger.warn(
        `Failed to log ${input.type} event for invoice ${input.invoiceId}: ${(err as Error).message}`,
      );
    }
  }
}
