import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import {
  S3Client,
  CreateMultipartUploadCommand,
  UploadPartCommand,
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  DeleteObjectCommand,
  DeleteObjectsCommand,
  CopyObjectCommand,
  PutObjectCommand,
  GetObjectCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env } from '../config/env';

export interface S3Part {
  PartNumber: number;
  ETag: string;
}

/**
 * Обёртка над Hetzner Object Storage (S3-совместимый).
 * Ключи объектов: files/<sha256> (content-addressed, дедуп), db/* — дампы БД.
 * В dev (пустые ключи) методы кидают понятную ошибку — S3 не трогаем.
 */
@Injectable()
export class S3Service implements OnModuleDestroy {
  private readonly logger = new Logger(S3Service.name);
  private readonly client: S3Client | null;

  constructor() {
    if (env.S3_FILES_ACCESS_KEY && env.S3_FILES_SECRET_KEY) {
      this.client = new S3Client({
        region: env.S3_FILES_REGION,
        endpoint: env.S3_FILES_ENDPOINT,
        forcePathStyle: env.S3_FILES_FORCE_PATH_STYLE,
        credentials: {
          accessKeyId: env.S3_FILES_ACCESS_KEY,
          secretAccessKey: env.S3_FILES_SECRET_KEY,
        },
      });
    } else {
      this.client = null;
      this.logger.warn('S3 не сконфигурирован (пустые ключи) — файловые операции будут падать');
    }
  }

  onModuleDestroy() {
    this.client?.destroy();
  }

  private s3(): S3Client {
    if (!this.client) throw new Error('S3 not configured: set S3_FILES_ACCESS_KEY / S3_FILES_SECRET_KEY');
    return this.client;
  }

  bucket = env.S3_FILES_BUCKET;

  static assetKey(sha256: string): string {
    return `files/${sha256}`;
  }

  async createMultipartUpload(key: string): Promise<string> {
    const cmd = new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: key });
    const out = await this.s3().send(cmd);
    if (!out.UploadId) throw new Error('S3: no UploadId');
    return out.UploadId;
  }

  async uploadPart(key: string, uploadId: string, partNumber: number, body: Buffer): Promise<string> {
    const cmd = new UploadPartCommand({
      Bucket: this.bucket,
      Key: key,
      UploadId: uploadId,
      PartNumber: partNumber,
      Body: body,
    });
    const out = await this.s3().send(cmd);
    if (!out.ETag) throw new Error('S3: no ETag');
    return out.ETag;
  }

  async abortMultipartUpload(key: string, uploadId: string): Promise<void> {
    const cmd = new AbortMultipartUploadCommand({ Bucket: this.bucket, Key: key, UploadId: uploadId });
    await this.s3().send(cmd);
  }

  async completeMultipartUpload(key: string, uploadId: string, parts: S3Part[]): Promise<void> {
    const cmd = new CompleteMultipartUploadCommand({
      Bucket: this.bucket,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: parts },
    });
    await this.s3().send(cmd);
  }

  async deleteObject(key: string): Promise<void> {
    const cmd = new DeleteObjectCommand({ Bucket: this.bucket, Key: key });
    await this.s3().send(cmd);
  }

  /** Пакетное удаление (для purge корзины); ошибки отдельных ключей не роняют остальные. */
  async deleteObjects(keys: string[]): Promise<void> {
    if (!keys.length) return;
    const chunks: string[][] = [];
    for (let i = 0; i < keys.length; i += 1000) chunks.push(keys.slice(i, i + 1000));
    for (const chunk of chunks) {
      const cmd = new DeleteObjectsCommand({
        Bucket: this.bucket,
        Delete: { Objects: chunk.map((Key) => ({ Key })) },
      });
      const out = await this.s3().send(cmd);
      if (out.Errors?.length) {
        // best-effort: пропускаем ошибки, логируем
        // eslint-disable-next-line no-console
        console.warn(`[s3] deleteObjects partial errors: ${out.Errors.length}`);
      }
    }
  }

  /** Server-side copy (для перекладывания tmp-объекта в content-addressed ключ). */
  async copyObject(srcKey: string, dstKey: string): Promise<void> {
    const cmd = new CopyObjectCommand({ Bucket: this.bucket, Key: dstKey, CopySource: `${this.bucket}/${srcKey}` });
    await this.s3().send(cmd);
  }

  /** Однократная PUT-запись объекта (для file-drop и мелких файлов ≤ 5 ГБ). */
  async putObject(key: string, body: Buffer, contentType: string): Promise<void> {
    const cmd = new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: body,
      ContentType: contentType,
    });
    await this.s3().send(cmd);
  }

  /** Стримовая PUT-запись (WebDAV, большие файлы). */
  async putObjectStream(
    key: string,
    body: NodeJS.ReadableStream,
    contentType: string,
    contentLength?: number,
  ): Promise<void> {
    const cmd = new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: body as never,
      ContentType: contentType,
      ...(contentLength ? { ContentLength: contentLength } : {}),
    });
    await this.s3().send(cmd);
  }

  /** Временная presigned-ссылка на скачивание (TTL 15 мин). */
  async presignedGet(key: string, mime: string): Promise<string> {
    const cmd = new GetObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ResponseContentType: mime,
      ResponseContentDisposition: 'attachment',
    });
    return getSignedUrl(this.s3(), cmd, { expiresIn: 15 * 60 });
  }
}
