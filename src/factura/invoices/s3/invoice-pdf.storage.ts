import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { Injectable, Logger } from "@nestjs/common";
import { facturaS3Client, invoicesBucket } from "./../../s3-client";

// One process-wide S3 client. Lazy because in dev / CI / first-run boot
// the S3_* env vars may be empty — we still want the API to come up,
// and only fail on actual upload/download calls.
function getClient(): S3Client {
  // Клиент и креды — общие для всего фактурного раздела (см. src/factura/s3-client.ts):
  // секреты S3 в облаке уже есть, дублировать их ради второго бакета незачем.
  return facturaS3Client();
}

function bucket(): string {
  // Бакет фактур свой (документы и PDF лежат там с самого начала), креды — общие.
  return invoicesBucket();
}

/** Object-key layout. One folder per company keeps usage attributable
 *  for billing / audit, and the year segment makes lifecycle policies
 *  (archive after 7 years) trivial to express on the bucket side.
 *
 *  Example: pdfs/cmp123/2026/00007-FACT-2026-00007.pdf */
export function invoicePdfKey(args: {
  companyId: string;
  serialYear: number;
  serialIndex: number;
  number: string;
}): string {
  const idx = String(args.serialIndex).padStart(5, "0");
  return `pdfs/${args.companyId}/${args.serialYear}/${idx}-${args.number}.pdf`;
}

@Injectable()
export class InvoicePdfStorageService {
  private readonly logger = new Logger(InvoicePdfStorageService.name);

  /** Upload a freshly rendered PDF buffer. Sets a stable Content-Disposition
   *  with the invoice number so a "Save as…" from the presigned URL gives
   *  the customer a human-readable filename. */
  async upload(args: {
    key: string;
    body: Buffer;
    invoiceNumber: string;
  }): Promise<void> {
    await getClient().send(
      new PutObjectCommand({
        Bucket: bucket(),
        Key: args.key,
        Body: args.body,
        ContentType: "application/pdf",
        ContentDisposition: `inline; filename="${args.invoiceNumber}.pdf"`,
        CacheControl: "private, max-age=0, no-store",
      }),
    );
    this.logger.log(`uploaded ${args.key} (${args.body.length} bytes)`);
  }

  /** True if the object exists in S3. Used by the repair cron to decide
   *  whether a row with a non-null pdfS3Key is actually backed by an
   *  object (e.g. a half-completed write may have left the row pointing
   *  at a key that never finalised). */
  async exists(key: string): Promise<boolean> {
    try {
      await getClient().send(new HeadObjectCommand({ Bucket: bucket(), Key: key }));
      return true;
    } catch (err) {
      const status = (err as { $metadata?: { httpStatusCode?: number } })?.$metadata
        ?.httpStatusCode;
      if (status === 404 || status === 403) return false;
      throw err;
    }
  }

  /** Delete an object. Best-effort — S3 returns success even on a
   *  missing key, so callers can use this to clean up orphans without
   *  guarding with a HEAD first. Errors are surfaced so the caller can
   *  log them; we don't swallow because a persistent permission failure
   *  would otherwise accumulate orphans silently. */
  async delete(key: string): Promise<void> {
    await getClient().send(
      new DeleteObjectCommand({ Bucket: bucket(), Key: key }),
    );
    this.logger.log(`deleted ${key}`);
  }

  /** Short-lived presigned GET URL. Used by `GET /invoices/:id/pdf` to
   *  hand the browser a direct download link without proxying the bytes
   *  through the NestJS process. */
  async getPresignedUrl(key: string, ttlSeconds = 300): Promise<string> {
    const cmd = new GetObjectCommand({ Bucket: bucket(), Key: key });
    return getSignedUrl(getClient(), cmd, { expiresIn: ttlSeconds });
  }
}
