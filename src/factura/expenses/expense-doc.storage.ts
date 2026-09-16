import { Injectable, Logger } from "@nestjs/common";
import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { randomBytes } from "node:crypto";
import type { Readable } from "node:stream";
import { facturaS3Client, invoicesBucket } from "./../s3-client";

// Mirrors invoices/s3/invoice-pdf.storage.ts — same env + S3-compatible
// (Hetzner) client, but for the arbitrary image/PDF a user attaches to an
// expense. Lazy singleton client so the app boots without S3 configured.
function getClient(): S3Client {
  // Клиент и креды — общие для всего фактурного раздела (см. src/factura/s3-client.ts):
  // секреты S3 в облаке уже есть, дублировать их ради второго бакета незачем.
  return facturaS3Client();
}

function bucket(): string {
  // Бакет фактур свой (документы и PDF лежат там с самого начала), креды — общие.
  return invoicesBucket();
}

const EXT_BY_MIME: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "image/heif": "heif",
  "application/pdf": "pdf",
};

@Injectable()
export class ExpenseDocStorageService {
  private readonly logger = new Logger(ExpenseDocStorageService.name);

  /** Key scheme: expenses/<companyId>/<random>.<ext>. The expense id isn't
   *  known yet at first upload (create flow), so a random token keeps keys
   *  unique and stable across a re-upload replacing the previous file. */
  key(companyId: string, mimeType: string): string {
    const ext = EXT_BY_MIME[mimeType] ?? "bin";
    return `expenses/${companyId}/${randomBytes(12).toString("hex")}.${ext}`;
  }

  async upload(args: {
    key: string;
    body: Buffer;
    mimeType: string;
    fileName?: string;
  }): Promise<void> {
    await getClient().send(
      new PutObjectCommand({
        Bucket: bucket(),
        Key: args.key,
        Body: args.body,
        ContentType: args.mimeType,
        ContentDisposition: args.fileName
          ? `inline; filename="${args.fileName.replace(/"/g, "")}"`
          : "inline",
        CacheControl: "private, max-age=0, no-store",
      }),
    );
    this.logger.log(`uploaded ${args.key} (${args.body.length} bytes)`);
  }

  async delete(key: string): Promise<void> {
    await getClient()
      .send(new DeleteObjectCommand({ Bucket: bucket(), Key: key }))
      .catch((e) => this.logger.warn(`delete ${key} failed: ${e.message}`));
  }

  async getPresignedUrl(key: string, ttlSeconds = 300): Promise<string> {
    const cmd = new GetObjectCommand({ Bucket: bucket(), Key: key });
    return getSignedUrl(getClient(), cmd, { expiresIn: ttlSeconds });
  }

  /** Stream the object's bytes (for proxying through the API so the browser
   *  fetches from our own origin — avoids S3 CORS for pdf.js page rendering). */
  async getObject(
    key: string,
  ): Promise<{ body: Readable; contentType?: string; contentLength?: number }> {
    const out = await getClient().send(
      new GetObjectCommand({ Bucket: bucket(), Key: key }),
    );
    return {
      body: out.Body as Readable,
      contentType: out.ContentType,
      contentLength: out.ContentLength,
    };
  }
}
