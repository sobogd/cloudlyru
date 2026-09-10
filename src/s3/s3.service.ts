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
  HeadObjectCommand,
  UploadPartCopyCommand,
} from '@aws-sdk/client-s3';
import { createWriteStream } from 'fs';
import { createReadStream } from 'fs';
import { createHash } from 'crypto';
import { stat } from 'fs/promises';
import { pipeline } from 'stream/promises';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env } from '../config/env';

export interface S3Part {
  PartNumber: number;
  ETag: string;
}

/** Открытый объект S3: тело потоком + параметры ответа (для отдачи клиенту через API). */
export interface S3ObjectStream {
  body: NodeJS.ReadableStream;
  contentLength?: number;
  contentRange?: string;
  contentType?: string;
  etag?: string;
  lastModified?: Date;
}

/** Нормализация префикса ключей: ' dev/test/ ' → 'dev/test/'. */
function normalizePrefix(raw: string): string {
  const p = raw.trim().replace(/^\/+/, '').replace(/\/+$/, '');
  return p ? `${p}/` : '';
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

  /** Одиночный CopyObject в S3 работает только до 5 ГБ — больше копируем частями. */
  private static readonly COPY_SINGLE_MAX = 5 * 1024 * 1024 * 1024;
  private static readonly COPY_PART_SIZE = 512 * 1024 * 1024;
  private static readonly COPY_CONCURRENCY = 4;
  /** Размер части при потоковой загрузке (multipart). */
  private static readonly STREAM_PART_SIZE = 32 * 1024 * 1024;
  /** Окно чтения при подсчёте sha256 объекта: 4 × 16 МБ в полёте (~64 МБ памяти). */
  private static readonly HASH_RANGE = 16 * 1024 * 1024;
  private static readonly HASH_CONCURRENCY = 4;

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
        // Без этого SDK добавляет в presigned-URL контрольную сумму (x-amz-checksum-crc32),
        // посчитанную от пустого тела: браузер, заливающий в эту ссылку реальные байты,
        // получает от S3 отказ по checksum. Для presigned-загрузок checksum не нужен.
        requestChecksumCalculation: 'WHEN_REQUIRED',
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

  /** Настроен ли S3 (иначе прямая загрузка и файловые операции невозможны). */
  get configured(): boolean {
    return this.client !== null;
  }

  bucket = env.S3_FILES_BUCKET;

  /**
   * Префикс ключей в бакете: прод — пусто, dev/тесты — свой. Наружу (в БД, в API,
   * в ответах) ключи всегда ходят без префикса, он добавляется только здесь,
   * на границе с S3.
   */
  private readonly prefix = normalizePrefix(env.S3_FILES_PREFIX);

  /** Ключ для S3 (с префиксом инстанса). */
  private k(key: string): string {
    return this.prefix + key;
  }

  /** Обратно к «чистому» ключу (префикс убираем — вызывающие про него не знают). */
  private un(key: string): string {
    return this.prefix && key.startsWith(this.prefix) ? key.slice(this.prefix.length) : key;
  }

  static assetKey(sha256: string): string {
    return `files/${sha256}`;
  }

  async createMultipartUpload(key: string): Promise<string> {
    const cmd = new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: this.k(key) });
    const out = await this.s3().send(cmd);
    if (!out.UploadId) throw new Error('S3: no UploadId');
    return out.UploadId;
  }

  async uploadPart(key: string, uploadId: string, partNumber: number, body: Buffer): Promise<string> {
    const cmd = new UploadPartCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      UploadId: uploadId,
      PartNumber: partNumber,
      Body: body,
    });
    const out = await this.s3().send(cmd);
    if (!out.ETag) throw new Error('S3: no ETag');
    return out.ETag;
  }

  async abortMultipartUpload(key: string, uploadId: string): Promise<void> {
    const cmd = new AbortMultipartUploadCommand({ Bucket: this.bucket, Key: this.k(key), UploadId: uploadId });
    await this.s3().send(cmd);
  }

  async completeMultipartUpload(key: string, uploadId: string, parts: S3Part[]): Promise<void> {
    const cmd = new CompleteMultipartUploadCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      UploadId: uploadId,
      MultipartUpload: { Parts: parts },
    });
    await this.s3().send(cmd);
  }

  async deleteObject(key: string): Promise<void> {
    const cmd = new DeleteObjectCommand({ Bucket: this.bucket, Key: this.k(key) });
    await this.s3().send(cmd);
  }

  /**
   * Пакетное удаление (для purge корзины); ошибки отдельных ключей не роняют остальные.
   * Возвращает ключи (без префикса), которые S3 НЕ удалил: вызывающий решает, что с ними
   * делать. Раньше ошибки молча проглатывались, и БД расходилась с бакетом без следов в логе.
   */
  async deleteObjects(keys: string[]): Promise<string[]> {
    if (!keys.length) return [];
    const chunks: string[][] = [];
    for (let i = 0; i < keys.length; i += 1000) chunks.push(keys.slice(i, i + 1000));
    const failed: string[] = [];
    for (const chunk of chunks) {
      const cmd = new DeleteObjectsCommand({
        Bucket: this.bucket,
        Delete: { Objects: chunk.map((Key) => ({ Key: this.k(Key) })) },
      });
      const out = await this.s3().send(cmd);
      for (const err of out.Errors ?? []) if (err.Key) failed.push(this.un(err.Key));
      if (out.Errors?.length) {
        const sample = out.Errors.slice(0, 5).map((e) => `${e.Key} (${e.Code ?? '?'})`).join(', ');
        this.logger.warn(`[s3] не удалено объектов: ${out.Errors.length} — ${sample}`);
      }
    }
    return failed;
  }

  /** Скачать объект целиком в память (для EXIF-парсинга; maxBytes-страховка). */
  async getObjectBytes(key: string, maxBytes = 150 * 1024 * 1024): Promise<Buffer> {
    const cmd = new GetObjectCommand({ Bucket: this.bucket, Key: this.k(key) });
    const out = await this.s3().send(cmd);
    if (!out.Body) throw new Error('S3: empty body');
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const c of out.Body as AsyncIterable<Uint8Array>) {
      total += c.length;
      if (total > maxBytes) throw new Error('object too large to buffer');
      chunks.push(Buffer.from(c));
    }
    return Buffer.concat(chunks);
  }

  /**
   * Server-side copy (для перекладывания tmp-объекта в content-addressed ключ).
   *
   * ВАЖНО: одиночный CopyObject в S3 работает только до 5 ГБ (иначе EntityTooLarge) —
   * из-за этого падали загрузки крупных файлов (например архивов Takeout по 53 ГБ).
   * Объекты больше порога копируем частями через UploadPartCopy.
   */
  async copyObject(srcKey: string, dstKey: string): Promise<void> {
    const size = await this.objectSize(srcKey);
    if (size <= S3Service.COPY_SINGLE_MAX) {
      const cmd = new CopyObjectCommand({
        Bucket: this.bucket,
        Key: this.k(dstKey),
        CopySource: `${this.bucket}/${this.k(srcKey)}`,
      });
      await this.s3().send(cmd);
      return;
    }

    const partCount = Math.ceil(size / S3Service.COPY_PART_SIZE);
    const uploadId = await this.createMultipartUpload(dstKey);
    try {
      const parts: S3Part[] = new Array(partCount);
      let next = 0;
      const worker = async () => {
        for (;;) {
          const i = next++;
          if (i >= partCount) return;
          const start = i * S3Service.COPY_PART_SIZE;
          const end = Math.min(size, start + S3Service.COPY_PART_SIZE) - 1;
          const out = await this.s3().send(
            new UploadPartCopyCommand({
              Bucket: this.bucket,
              Key: this.k(dstKey),
              UploadId: uploadId,
              PartNumber: i + 1,
              CopySource: `${this.bucket}/${this.k(srcKey)}`,
              CopySourceRange: `bytes=${start}-${end}`,
            }),
          );
          const etag = out.CopyPartResult?.ETag;
          if (!etag) throw new Error(`S3: no ETag on copy part ${i + 1}`);
          parts[i] = { PartNumber: i + 1, ETag: etag };
        }
      };
      await Promise.all(
        Array.from({ length: Math.min(S3Service.COPY_CONCURRENCY, partCount) }, () => worker()),
      );
      await this.completeMultipartUpload(dstKey, uploadId, parts);
      this.logger.log(`[s3] multipart-copy ${srcKey} → ${dstKey} (${(size / 1e9).toFixed(2)} ГБ, частей ${partCount})`);
    } catch (e) {
      await this.abortMultipartUpload(dstKey, uploadId).catch(() => undefined);
      throw e;
    }
  }

  /** Размер объекта (HeadObject); 0 — если объекта нет. */
  async objectSize(key: string): Promise<number> {
    const out = await this.s3().send(new HeadObjectCommand({ Bucket: this.bucket, Key: this.k(key) }));
    return Number(out.ContentLength ?? 0);
  }

  /** Прочитать диапазон байт объекта (Range-запрос). Нужно для чтения ZIP из S3 без скачивания. */
  async readRange(key: string, start: number, endInclusive: number): Promise<Buffer> {
    const cmd = new GetObjectCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      Range: `bytes=${start}-${endInclusive}`,
    });
    const out = await this.s3().send(cmd);
    if (!out.Body) throw new Error('S3: empty body');
    const body = out.Body as { transformToByteArray?: () => Promise<Uint8Array> };
    if (typeof body.transformToByteArray === 'function') {
      return Buffer.from(await body.transformToByteArray());
    }
    const chunks: Buffer[] = [];
    for await (const c of out.Body as AsyncIterable<Uint8Array>) chunks.push(Buffer.from(c));
    return Buffer.concat(chunks);
  }

  /**
   * Залить поток в объект multipart-загрузкой (без знания размера заранее и без диска).
   * Буфер одной части переиспользуется — копирование однократное.
   */
  async uploadStream(key: string, stream: NodeJS.ReadableStream, _contentType: string): Promise<number> {
    const PART = S3Service.STREAM_PART_SIZE;
    const uploadId = await this.createMultipartUpload(key);
    const parts: S3Part[] = [];
    let buf = Buffer.allocUnsafe(PART);
    let off = 0;
    let total = 0;
    let partNumber = 0;
    const push = async (body: Buffer) => {
      partNumber += 1;
      const etag = await this.uploadPart(key, uploadId, partNumber, body);
      parts.push({ PartNumber: partNumber, ETag: etag });
    };
    try {
      for await (const raw of stream as AsyncIterable<Buffer | string>) {
        const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
        total += chunk.length;
        let pos = 0;
        while (pos < chunk.length) {
          const take = Math.min(PART - off, chunk.length - pos);
          chunk.copy(buf, off, pos, pos + take);
          off += take;
          pos += take;
          if (off === PART) {
            await push(buf);
            buf = Buffer.allocUnsafe(PART);
            off = 0;
          }
        }
      }
      if (off > 0) await push(buf.subarray(0, off));
      if (!parts.length) await push(Buffer.alloc(0));
      await this.completeMultipartUpload(key, uploadId, parts);
      return total;
    } catch (e) {
      await this.abortMultipartUpload(key, uploadId).catch(() => undefined);
      throw e;
    }
  }

  /** Однократная PUT-запись объекта (для file-drop и мелких файлов ≤ 5 ГБ). */
  async putObject(key: string, body: Buffer, contentType: string): Promise<void> {
    const cmd = new PutObjectCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      Body: body,
      ContentType: contentType,
    });
    await this.s3().send(cmd);
  }

  /** Существует ли объект (HeadObject). */
  async headObject(key: string): Promise<boolean> {
    try {
      await this.s3().send(new HeadObjectCommand({ Bucket: this.bucket, Key: this.k(key) }));
      return true;
    } catch {
      return false;
    }
  }

  /** Скачать объект в локальный файл (для воркера конвертации). */
  async downloadToFile(key: string, filePath: string): Promise<void> {
    const cmd = new GetObjectCommand({ Bucket: this.bucket, Key: this.k(key) });
    const out = await this.s3().send(cmd);
    if (!out.Body) throw new Error('S3: empty body');
    await pipeline(out.Body as NodeJS.ReadableStream, createWriteStream(filePath));
  }

  /** Залить локальный файл (Content-Length из stat). */
  async putFile(key: string, filePath: string, contentType: string): Promise<void> {
    const size = (await stat(filePath)).size;
    const cmd = new PutObjectCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      Body: createReadStream(filePath),
      ContentType: contentType,
      ContentLength: size,
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
      Key: this.k(key),
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
      Key: this.k(key),
      ResponseContentType: mime,
      ResponseContentDisposition: 'attachment',
    });
    return getSignedUrl(this.s3(), cmd, { expiresIn: 15 * 60 });
  }

  /**
   * Presigned-ссылка на загрузку ОДНОЙ части multipart напрямую из браузера в S3.
   * Подписаны конкретный ключ, uploadId и номер части, срок — минуты: утечка ссылки
   * даёт возможность записать одну часть одного ещё не собранного файла, и не более.
   */
  async presignedUploadPart(
    key: string,
    uploadId: string,
    partNumber: number,
    expiresInSec: number,
  ): Promise<string> {
    const cmd = new UploadPartCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      UploadId: uploadId,
      PartNumber: partNumber,
    });
    return getSignedUrl(this.s3(), cmd, { expiresIn: expiresInSec });
  }

  /**
   * sha256 объекта, посчитанный чтением из S3. Нужен для прямой загрузки: сервер байтов
   * не видел, а ключ объекта content-addressed — поэтому хэш берётся из самих данных, а не
   * из того, что объявил клиент.
   *
   * Читаем не одним потоком, а окном параллельных Range-запросов: sha256 последователен,
   * но байты можно возить заранее. Один поток из Hetzner идёт десятками МБ/с, из-за чего
   * на десятках ГБ запрос complete вылезал за таймауты nginx (300 с).
   */
  async hashObject(key: string): Promise<string> {
    const size = await this.objectSize(key);
    const hash = createHash('sha256');
    if (size <= 0) return hash.digest('hex');

    const ranges = Math.ceil(size / S3Service.HASH_RANGE);
    const fetchRange = (i: number): Promise<Buffer> => {
      const start = i * S3Service.HASH_RANGE;
      const end = Math.min(size, start + S3Service.HASH_RANGE) - 1;
      return this.readRange(key, start, end);
    };

    const inFlight = new Map<number, Promise<Buffer>>();
    const window = Math.min(S3Service.HASH_CONCURRENCY, ranges);
    for (let i = 0; i < window; i++) inFlight.set(i, fetchRange(i));

    for (let i = 0; i < ranges; i++) {
      const buf = await inFlight.get(i)!;
      inFlight.delete(i);
      hash.update(buf);
      const next = i + window;
      if (next < ranges) inFlight.set(next, fetchRange(next));
    }
    return hash.digest('hex');
  }

  /**
   * Открыть объект потоком — для отдачи клиенту через сам сервис (без presigned-ссылок
   * наружу: ссылка на S3 живёт без авторизации и утекает в историю браузера/логи).
   * Range пробрасывается в S3 как есть: без него не работает перемотка в <video>.
   */
  async getObjectStream(key: string, range?: string): Promise<S3ObjectStream> {
    const cmd = new GetObjectCommand({
      Bucket: this.bucket,
      Key: this.k(key),
      ...(range ? { Range: range } : {}),
    });
    const out = await this.s3().send(cmd);
    if (!out.Body) throw new Error('S3: empty body');
    return {
      body: out.Body as NodeJS.ReadableStream,
      contentLength: out.ContentLength,
      contentRange: out.ContentRange,
      contentType: out.ContentType,
      etag: out.ETag,
      lastModified: out.LastModified,
    };
  }
}
