import { createHash, Hash } from 'crypto';
import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { FilesService } from '../files/files.service';
import { MediaService } from '../media/media.service';
import { QueueService } from '../queue/queue.service';
import { AuthService } from '../auth/auth.service';
import {
  CHUNK_MAX_BYTES,
  DIRECT_PART_BYTES,
  MAX_FILE_BYTES,
  MAX_UPLOAD_SESSIONS_PER_USER,
  PART_URL_TTL_SEC,
  STORAGE_HOST,
} from '../config/env';
import { assertSafeName, parseOptionalDate, randomToken } from '../common/utils';
import { ZONE_PHOTOS, isHiddenZone } from '../common/zones';
import { badRequest, conflict, notFound, payloadTooLarge, tooMany } from '../common/errors';

/**
 * Номер первой недополученной части в диапазоне 1..total. Если принято всё — total + 1:
 * клиенту больше нечего отправлять, и это видно по его же арифметике частей.
 */
export function firstMissingPart(received: number[], total: number): number {
  const have = new Set(received);
  for (let i = 1; i <= total; i++) if (!have.has(i)) return i;
  return total + 1;
}

/** Принятая часть multipart: ETag отдаёт S3, клиент передаёт его серверу. */
/** Минимальный размер части multipart в S3 (кроме последней). */
const MIN_RELAY_PART_BYTES = 5 * 1024 * 1024;
/** Больше частей S3 в одном multipart не принимает. */
const MAX_PARTS = 10_000;
/**
 * Сессия с принятыми частями, которую не трогали столько времени, считается брошенной: её
 * обновляет каждая принятая часть (и релей, и прямая загрузка — регистрацией ETag), поэтому
 * «час тишины» означает, что клиент про неё забыл, а не то, что он медленно льёт.
 */
const IDLE_SESSION_MS = 60 * 60 * 1000;

interface StoredPart {
  partNumber: number;
  etag: string;
  size?: number;
}

interface LiveSession {
  /** Инкрементальный sha256 — только для релея (чанки идут через сервер по порядку). */
  hash: Hash;
  /**
   * Покрывает ли `hash` ВЕСЬ поток байтов сессии. false — сессия продолжена после рестарта
   * (или её начал другой процесс): хвост чанков в хэше, а начало — нет, поэтому такой хэш
   * использовать нельзя, и `complete` считает sha256 по объекту в S3.
   */
  hashValid: boolean;
  /** digest() вызывается один раз, а complete может повториться (ретрай клиента) — кэшируем. */
  sha256?: string;
  /** multipart уже финализирован — повторный complete не должен финализировать снова. */
  finalized?: boolean;
}

type SessionRow = {
  id: string;
  userId: string;
  s3UploadId: string;
  uploadKey: string;
  folderId: string | null;
  name: string;
  size: bigint;
  mime: string;
  parts: unknown;
  declaredSha256: string | null;
  direct: boolean;
  replace: boolean;
  replaceTrashed: boolean;
  clientMtime: Date | null;
  expectedSha256: string | null;
  expectedUpdatedAt: Date | null;
  completedAt: Date | null;
  result: unknown;
};

/** Результат завершённой загрузки — то же, что отдаётся клиенту и лежит в сессии. */
interface FinishResult {
  entry: { id: string };
  asset: { sha256: string; size: number; mime: string };
  deduped: boolean;
  replaced: boolean;
  zone: string;
}

/** sha256 в нижнем регистре; всё, что не 64 hex-символа, — не хэш. */
function normalizeSha(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(s) ? s : undefined;
}

/** Машинный код ошибки из ApiError (в теле ответа лежит `code`): нужен, чтобы не глотать лишнее. */
function errorCode(e: unknown): string | undefined {
  const getResponse = (e as { getResponse?: () => unknown })?.getResponse;
  if (typeof getResponse !== 'function') return undefined;
  const res = getResponse.call(e);
  if (res && typeof res === 'object' && typeof (res as { code?: unknown }).code === 'string') {
    return (res as { code: string }).code;
  }
  return undefined;
}

/** ETag из ответа S3 приходит в кавычках; weak-префикс и пробелы не нужны. */
function normalizeEtag(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().replace(/^W\//, '');
  if (!s) return undefined;
  return s.startsWith('"') && s.endsWith('"') ? s : `"${s.replace(/"/g, '')}"`;
}

function storedParts(raw: unknown): StoredPart[] {
  if (!Array.isArray(raw)) return [];
  const out: StoredPart[] = [];
  for (const p of raw) {
    if (!p || typeof p !== 'object') continue;
    const partNumber = Number((p as { partNumber?: unknown }).partNumber);
    const etag = (p as { etag?: unknown }).etag;
    if (!Number.isInteger(partNumber) || partNumber <= 0 || typeof etag !== 'string') continue;
    const size = (p as { size?: unknown }).size;
    out.push({ partNumber, etag, size: typeof size === 'number' ? size : undefined });
  }
  return out.sort((a, b) => a.partNumber - b.partNumber);
}

/**
 * Загрузка файла — прямая в S3 (браузер → S3), сервер только подписывает ссылки на части
 * и ведёт дерево. Схема:
 *   1. клиент считает sha256 файла (инкрементально, WASM), POST /uploads {sha256, size, ...};
 *      сервер, если объект с таким содержимым уже есть, вообще не начинает загрузку (дедуп
 *      0 байт) и сразу создаёт запись в дереве;
 *   2. клиент берёт presigned-ссылку на часть (GET /uploads/:id/url/:n), льёт часть прямо в S3
 *      и сообщает серверу ETag (PUT /uploads/:id/parts/:n). Части можно слать параллельно;
 *   3. POST /uploads/:id/complete — сервер собирает multipart по ETag'ам, проверяет размер,
 *      считает sha256 по факту (ключ объекта content-addressed: доверять хэшу клиента нельзя,
 *      ошибка клиента отравила бы дедуп для всего хранилища), дедупит и кладёт запись в дерево.
 * Релей-путь (PUT /uploads/:id/chunks/:n — чанки через сервер) сохранён как фолбэк: он нужен
 * там, где браузер не может ходить в S3 (нет CORS и т.п.).
 *
 * Части в обоих путях пишутся в БД, поэтому рестарт сервиса сессию не убивает: `nextPart`
 * считается по частям из БД, и докачка продолжается. Чего рестарт не переживает — состояние
 * инкрементального хэша релея (оно в памяти): у продолженной после рестарта сессии хэш
 * помечается неполным (`hashValid: false`), и `complete` пересчитывает sha256 по объекту в S3
 * (полное чтение, как при прямой загрузке), а не доверяет хвосту потока.
 */
@Injectable()
export class UploadsService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(UploadsService.name);
  private readonly live = new Map<string, LiveSession>();
  /** Сессия без единого запроса дольше этого — брошена (вкладку закрыли, сеть умерла). */
  private readonly STALE_MS = 6 * 60 * 60 * 1000;
  /** Как часто подчищаем брошенные сессии (раньше — только при старте сервиса). */
  private readonly SWEEP_MS = 15 * 60 * 1000;
  /** Сколько держим завершённую сессию, чтобы отдать тот же ответ на ретрай complete. */
  private readonly DONE_KEEP_MS = 60 * 60 * 1000;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
    private readonly files: FilesService,
    private readonly auth: AuthService,
    private readonly media: MediaService,
    private readonly queue: QueueService,
  ) {}

  async onModuleInit() {
    await this.sweepStale();
    this.timer = setInterval(() => void this.sweepStale(), this.SWEEP_MS);
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * Чистка брошенных сессий загрузки: без неё незавершённый multipart в S3 остаётся
   * висеть (оплачиваемый мусор), а записи в БД копятся. Раньше это делалось только
   * при старте сервиса, то есть после закрытой вкладки мусор мог жить сутками.
   */
  private async sweepStale(userId?: string): Promise<void> {
    try {
      const stale = await this.prisma.uploadSession.findMany({
        where: {
          ...(userId ? { userId } : {}),
          // брошенные ИЛИ завершённые больше часа назад (завершённые храним, чтобы ретрай
          // complete после потерянного ответа получил тот же ответ, а не 404)
          OR: [
            { updatedAt: { lt: new Date(Date.now() - this.STALE_MS) } },
            { completedAt: { not: null, lt: new Date(Date.now() - this.DONE_KEEP_MS) } },
          ],
        },
      });
      for (const s of stale) {
        await this.s3.abortMultipartUpload(s.uploadKey, s.s3UploadId).catch(() => undefined);
        await this.s3.deleteObject(s.uploadKey).catch(() => undefined);
        await this.prisma.uploadSession.delete({ where: { id: s.id } }).catch(() => undefined);
        this.live.delete(s.id);
      }
      if (stale.length) this.logger.log(`Очищено зависших upload-сессий: ${stale.length}`);
    } catch (e) {
      this.logger.warn(`cleanup uploads: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * Потолок одновременных НЕЗАВЕРШЁННЫХ сессий на пользователя: телефон с ретраями иначе
   * наплодит незавершённых multipart'ов (каждый висит в S3 до очистки и держит запись в БД).
   *
   * Завершённые сессии (completedAt) в счёт не входят, хотя и живут ещё час: они нужны только
   * для идемпотентного повтора `complete` и места не занимают. Раньше они попадали в подсчёт,
   * и путь «лимит превышен» срабатывал при обычной пакетной загрузке десятков мелких файлов.
   *
   * Вытесняем только заведомо брошенное: сначала сессии без единой принятой части, затем —
   * с частями, но не трогавшиеся больше часа (сессию обновляет каждая принятая часть, в том
   * числе при загрузке прямо в S3). Живую загрузку не вытесняем никогда: раньше под нож
   * попадала самая старая по updatedAt, то есть как раз идущая — её следующий чанк получал
   * 404, и клиент начинал файл заново. Если вытеснять нечего, честно просим подождать.
   */
  private async assertSessionQuota(userId: string): Promise<void> {
    const open = { userId, completedAt: null };
    let active = await this.prisma.uploadSession.count({ where: open });
    if (active < MAX_UPLOAD_SESSIONS_PER_USER) return;
    // Сначала убираем заведомо брошенные: сессия без единой части, о которой забыли
    // (клиент начал загрузку и не смог отправить байты — например, хранилище недоступно),
    // не должна навсегда занимать место и блокировать новые загрузки.
    await this.sweepAbandoned(userId);
    await this.sweepStale(userId);
    active = await this.prisma.uploadSession.count({ where: open });
    if (active < MAX_UPLOAD_SESSIONS_PER_USER) return;
    // Место всё равно занято — освобождаем принудительно, начиная с самой старой брошенной:
    // блокировать клиента насмерть хуже, чем отменить чужую загрузку (части в S3 всё равно
    // не собраны и объектом не стали).
    const idleCutoff = new Date(Date.now() - IDLE_SESSION_MS);
    const victim =
      (await this.prisma.uploadSession.findFirst({
        where: { ...open, partCount: 0 },
        orderBy: { updatedAt: 'asc' },
      })) ??
      (await this.prisma.uploadSession.findFirst({
        where: { ...open, updatedAt: { lt: idleCutoff } },
        orderBy: { updatedAt: 'asc' },
      }));
    if (!victim) {
      // Все незавершённые сессии обновлялись только что — значит это живые загрузки, и любая
      // из них кому-то нужна. Отвечаем понятной ошибкой с задержкой, а не убиваем чужую работу.
      this.logger.warn(`лимит сессий загрузки: ${active} активных, вытеснять нечего — прошу подождать`);
      throw tooMany('слишком много незавершённых загрузок — дождитесь завершения текущих', 'too_many_uploads', 300);
    }
    this.logger.warn(`лимит сессий загрузки: отменяю брошенную (${victim.name}) ради новой`);
    await this.cleanup(victim as SessionRow);
  }

  /** Сессии без принятых частей, о которых забыли: считаем брошенными через 15 минут. */
  private async sweepAbandoned(userId: string): Promise<void> {
    const cutoff = new Date(Date.now() - 15 * 60 * 1000);
    const abandoned = await this.prisma.uploadSession
      .findMany({ where: { userId, partCount: 0, updatedAt: { lt: cutoff } } })
      .catch(() => []);
    for (const row of abandoned) {
      await this.s3.abortMultipartUpload(row.uploadKey, row.s3UploadId).catch(() => undefined);
      await this.s3.deleteObject(row.uploadKey).catch(() => undefined);
      await this.prisma.uploadSession.delete({ where: { id: row.id } }).catch(() => undefined);
      this.live.delete(row.id);
    }
    if (abandoned.length) this.logger.log(`Отменено брошенных сессий загрузки: ${abandoned.length}`);
  }

  /** Папка-приёмник: только своя (чужой folderId — это запись в чужое дерево). */
  private async resolveFolder(folderId: string | undefined, userId: string): Promise<string> {
    if (folderId) {
      const folder = await this.prisma.folder.findUnique({ where: { id: folderId } });
      if (!folder || folder.deletedAt) throw notFound('folder not found');
      if (!(await this.auth.folderOwnedBy(userId, folder.id))) throw notFound('folder not found');
      // в «Почту» файлы кладёт только почтовый модуль: обычная загрузка туда разошлась бы
      // с письмом (запись без MailAttachment) и осталась бы невидимой в обоих разделах
      if (isHiddenZone(folder.zone)) throw notFound('folder not found');
      return folder.id;
    }
    return this.auth.rootFolderId(userId);
  }

  private async requireSession(uploadId: string, userId: string): Promise<SessionRow> {
    const row = await this.prisma.uploadSession.findUnique({ where: { id: uploadId } });
    if (!row || row.userId !== userId) throw notFound('upload not found');
    return row as SessionRow;
  }

  /** Загрузка уже завершена: части в неё доливать нельзя, но complete обязан быть повторяемым. */
  private assertNotCompleted(row: SessionRow): void {
    if (row.completedAt) throw conflict('upload already completed', 'upload_completed');
  }

  /** Сколько частей ожидается при прямой загрузке (последняя может быть короче). */
  private partCount(size: number): number {
    return Math.max(1, Math.ceil(size / DIRECT_PART_BYTES));
  }

  private assertPartNumber(size: number, partNumber: number): void {
    if (!Number.isInteger(partNumber) || partNumber <= 0) throw badRequest('invalid part number');
    const total = this.partCount(size);
    if (partNumber > total) {
      throw badRequest(`part ${partNumber} out of range — файл разбит на ${total} частей`);
    }
  }

  /** Сумма размеров уже принятых частей (неизвестные размеры считаем нулём). */
  private receivedBytes(parts: StoredPart[]): number {
    return parts.reduce((n, p) => n + (p.size ?? 0), 0);
  }

  /**
   * Записать/перезаписать часть в сессии (идемпотентно по номеру части).
   *
   * Части приходят параллельно (клиент льёт три части в S3 сразу), а parts — одна
   * JSON-колонка. Без блокировки строки два одновременных запроса читают один и тот же
   * parts, и запись второго затирает часть первого: в дерево уходит «missing part N —
   * загрузка неполная» при формально успешной загрузке (на проде так терялась часть 5
   * у видео из 13 частей). Поэтому читаем-и-пишем под SELECT ... FOR UPDATE.
   */
  private async savePart(row: SessionRow, part: StoredPart): Promise<StoredPart[]> {
    return this.prisma.$transaction(async (tx) => {
      const locked = await tx.$queryRaw<Array<{ id: string }>>`
        SELECT id FROM "UploadSession" WHERE id = ${row.id} FOR UPDATE`;
      if (!locked.length) throw notFound('upload not found');

      const fresh = await tx.uploadSession.findUnique({
        where: { id: row.id },
        select: { parts: true },
      });
      const parts = storedParts(fresh?.parts).filter((p) => p.partNumber !== part.partNumber);
      parts.push(part);
      parts.sort((a, b) => a.partNumber - b.partNumber);
      await tx.uploadSession.update({
        where: { id: row.id },
        data: { parts: parts as unknown as Prisma.InputJsonValue, partCount: parts.length },
      });
      row.parts = parts;
      return parts;
    });
  }

  /** Прервать multipart, убрать tmp-объект и сессию (при ошибке загрузки). */
  private async cleanup(row: SessionRow): Promise<void> {
    await this.s3.abortMultipartUpload(row.uploadKey, row.s3UploadId).catch(() => undefined);
    // multipart мог быть уже собран (ошибка нашли после completeMultipartUpload) —
    // тогда abort не сработает, и объект надо удалить явно, иначе он останется мусором
    await this.s3.deleteObject(row.uploadKey).catch(() => undefined);
    this.live.delete(row.id);
    try {
      await this.prisma.uploadSession.delete({ where: { id: row.id } });
    } catch {
      /* уже удалена */
    }
  }

  async init(
    body: {
      folderId?: string;
      name: string;
      size: number;
      mime: string;
      sha256?: string;
      mode?: string;
      replace?: unknown;
      replaceTrashed?: unknown;
      clientMtime?: unknown;
      expectedSha256?: unknown;
      expectedUpdatedAt?: unknown;
    },
    userId: string,
  ) {
    const name = String(body.name ?? '');
    const size = Number(body.size);
    const mime = String(body.mime ?? 'application/octet-stream');
    // перезапись существующего имени (зеркалирование): иначе каждый изменённый файл — 409
    const replace = body.replace === true || body.replace === 'true';
    // имя занято СВОЕЙ ЖЕ записью из корзины: клиент синхронизации просит занять его
    // (восстановить и перезаписать). Без флага поведение прежнее — 409 in_trash
    const replaceTrashed = body.replaceTrashed === true || body.replaceTrashed === 'true';
    const clientMtime = parseOptionalDate(body.clientMtime) ?? null;
    // предполётное условие перезаписи: клиент называет версию, которую заменяет
    const expect =
      body.expectedSha256 === undefined && body.expectedUpdatedAt === undefined
        ? undefined
        : {
            sha256: body.expectedSha256 === null ? null : normalizeSha(body.expectedSha256),
            updatedAt: parseOptionalDate(body.expectedUpdatedAt) ?? null,
          };
    if (expect && expect.sha256 === undefined && expect.updatedAt == null) {
      throw badRequest('invalid expectedSha256/expectedUpdatedAt');
    }
    if (expect && !replace && !replaceTrashed) {
      // без replace сервер создаёт новую запись, и условие «я заменяю версию X» теряет смысл
      throw badRequest('expectedSha256/expectedUpdatedAt требуют replace: true');
    }
    assertSafeName(name);
    // 0 байт — обычный файл («Загрузки» телефона полны пустых файлов): раньше он отвергался,
    // и такой файл не уезжал в облако никогда. BigInt требует целого, поэтому проверяем
    // и целость: дробный size раньше падал 500'кой на BigInt(size) ниже.
    if (!Number.isInteger(size) || size < 0) throw badRequest('invalid size');
    if (size > MAX_FILE_BYTES) throw payloadTooLarge('file too large');
    const direct = body.mode !== 'relay' && this.s3.configured;
    // Прямая загрузка идёт частями DIRECT_PART_BYTES, поэтому их число известно уже здесь:
    // S3 не принимает multipart больше 10 000 частей, и упереться в это после многочасовой
    // заливки нельзя — отвергаем сразу (это конфиг, а не ошибка клиента).
    if (direct && Math.ceil(size / DIRECT_PART_BYTES) > MAX_PARTS) {
      throw badRequest('файл слишком велик для текущего размера части: увеличьте UPLOAD_DIRECT_PART_MB');
    }
    // У релея размер части выбирает клиент, и на init он его не сообщает: отвергать здесь
    // «по минимально допустимым 5 МБ» значило бы отказывать и тем, кто льёт крупными частями.
    // Поэтому предел проверяется на первой же части — см. putChunk.
    const folderId = await this.resolveFolder(body.folderId, userId);
    // предусловие проверяем сразу: иначе клиент зальёт гигабайты, а на complete получит 409
    if (expect) await this.files.assertExpectedVersion(folderId, name, expect, { allowTrashed: replaceTrashed });
    // и отдельно имя из корзины: воскрешать удалённое сами не будем, но клиент должен узнать
    // об этом ДО передачи байтов (раньше 409 приходил только на complete). С replaceTrashed
    // запись из корзины — своя, и клиент явно разрешил её занять
    if (!replaceTrashed) await this.files.assertNameNotInTrash(folderId, name);
    const declared = normalizeSha(body.sha256);

    // Дедуп до передачи байтов: клиент посчитал sha256, объект с таким содержимым уже лежит
    // в S3 (и размер совпадает) — заливать нечего, создаём только запись в дереве.
    // ВАЖНО: дедуп разрешён только для содержимого, которое у пользователя уже есть.
    // Иначе по чужому sha256+size (их раздают /timeline и листинги) можно было получить
    // ссылку на чужой файл, не передав ни одного байта.
    if (declared) {
      const asset = await this.prisma.asset.findUnique({ where: { sha256: declared } });
      if (asset && Number(asset.size) === size && (await this.auth.ownsAsset(userId, asset.id))) {
        // Дедуп годится, только если содержимое реально можно отдать: оригинал на месте или
        // превью уже собраны (состояние лежит на ассете). Иначе получилась бы запись, которую
        // нечем показать и нечем пересобрать — такой файл лучше залить байтами заново
        // (дедуп никуда не девается, просто не в этом случае).
        const rawAlive = await this.s3.headObject(S3Service.assetKey(declared)).catch(() => false);
        if (rawAlive || asset.previewState === 'done') {
          const done = await this.finish({
            userId,
            folderId,
            name,
            size,
            mime,
            sha256: declared,
            assetId: asset.id,
            deduped: true,
            replace,
            restoreDeleted: replaceTrashed,
            clientMtime,
            expect,
          });
          return { ...done, uploadId: null, direct: false, nextPart: 1 };
        }
      }
    }

    await this.assertSessionQuota(userId);

    const tmpKey = `files/tmp/${randomToken(16)}`;
    const s3UploadId = await this.s3.createMultipartUpload(tmpKey);
    const session = await this.prisma.uploadSession.create({
      data: {
        userId,
        s3UploadId,
        uploadKey: tmpKey,
        folderId,
        name,
        size: BigInt(size),
        mime,
        parts: [] as unknown as Prisma.InputJsonValue,
        declaredSha256: declared ?? null,
        direct,
        replace,
        replaceTrashed,
        clientMtime,
        expectedSha256: expect?.sha256 ?? null,
        expectedUpdatedAt: expect?.updatedAt ?? null,
      },
    });

    this.live.set(session.id, { hash: createHash('sha256'), hashValid: true });
    return {
      uploadId: session.id,
      folderId,
      name,
      size,
      deduped: false,
      direct,
      partSize: DIRECT_PART_BYTES,
      chunkMaxBytes: CHUNK_MAX_BYTES,
      partUrlTtlSec: PART_URL_TTL_SEC,
      nextPart: 1,
      storageHost: STORAGE_HOST,
    };
  }

  async status(uploadId: string, userId: string) {
    const row = await this.requireSession(uploadId, userId);
    const parts = storedParts(row.parts);
    const received = parts.map((p) => p.partNumber);
    // Первая НЕДОСТАЮЩАЯ часть, а не «сколько принято»: части идут параллельно, и при обрыве
    // одной из них счётчик сдвинулся бы за дырку — клиент продолжил бы с дыркой и complete
    // вечно отвечал бы «missing part N».
    //
    // Общее число частей известно только у прямой загрузки (размер части задаёт сервер). У релея
    // размер части выбирает клиент, поэтому считаем по фактически принятым: иначе `partCount`
    // по 16 МБ занижал бы итог, и клиент с чанками по 5 МБ получил бы nextPart, указывающий
    // внутрь уже принятого.
    const total = row.direct
      ? this.partCount(Number(row.size))
      : received.length
        ? Math.max(...received)
        : 0;
    return {
      uploadId,
      direct: row.direct,
      partSize: DIRECT_PART_BYTES,
      chunkMaxBytes: CHUNK_MAX_BYTES,
      nextPart: firstMissingPart(received, total),
      receivedParts: parts.length,
      parts: received,
      size: Number(row.size),
      name: row.name,
      folderId: row.folderId,
    };
  }

  /** Presigned-ссылка на часть: клиент заливает по ней байты прямо в S3, минуя сервер. */
  async partUrl(uploadId: string, partNumber: number, userId: string) {
    const row = await this.requireSession(uploadId, userId);
    this.assertNotCompleted(row);
    this.assertPartNumber(Number(row.size), partNumber);
    const url = await this.s3.presignedUploadPart(
      row.uploadKey,
      row.s3UploadId,
      partNumber,
      PART_URL_TTL_SEC,
    );
    return {
      url,
      partNumber,
      expiresAt: new Date(Date.now() + PART_URL_TTL_SEC * 1000).toISOString(),
    };
  }

  /**
   * ETag части, залитой клиентом прямо в S3 (сервер — источник истины по частям).
   *
   * `size` клиент сообщает сам, в S3 за него не смотрим: по этим размерам `complete` проверяет,
   * что части покрывают объявленный размер файла (раньше ошибка всплывала только после сборки
   * multipart — «в S3 N байт, ожидалось M», уже потеряв всю заливку).
   */
  async registerPart(
    uploadId: string,
    partNumber: number,
    etag: unknown,
    size: unknown,
    userId: string,
  ) {
    const row = await this.requireSession(uploadId, userId);
    this.assertNotCompleted(row);
    this.assertPartNumber(Number(row.size), partNumber);
    const clean = normalizeEtag(etag);
    if (!clean) throw badRequest('etag required');
    // Часть залита в S3 мимо сервера: инкрементальный хэш релея после этого покрывает не весь
    // поток, и sha256 по нему считаться не должен (см. hashValid). Для прямой сессии хэш и так
    // не ведётся — там sha256 всегда считается по объекту.
    const live = this.live.get(uploadId);
    if (live && !row.direct) live.hashValid = false;
    const parts = await this.savePart(row, {
      partNumber,
      etag: clean,
      size: typeof size === 'number' && Number.isFinite(size) ? size : undefined,
    });
    return { uploadId, partNumber, receivedParts: parts.length, parts: parts.map((p) => p.partNumber) };
  }

  /**
   * Чанк через сервер (фолбэк, если браузер не может ходить в S3). Части строго по порядку.
   *
   * Состояние инкрементального хэша живёт в памяти, поэтому после рестарта (деплой, pm2 reload,
   * OOM) продолжить релей «как раньше» нельзя: раньше такой чанк получал 409
   * `upload_session_lost` и клиент начинал файл заново. Теперь сессию продолжает новый
   * LiveSession с `hashValid: false` — части из БД на месте (докачка с `nextPart` работает), а
   * `complete` пересчитывает sha256 по объекту в S3, не доверяя хэшу хвоста.
   */
  async putChunk(uploadId: string, partNumber: number, chunk: Buffer, userId: string) {
    if (chunk.length > CHUNK_MAX_BYTES) throw payloadTooLarge('chunk too large');
    const row = await this.requireSession(uploadId, userId);
    this.assertNotCompleted(row);
    const size = Number(row.size);
    if (partNumber > MAX_PARTS) {
      throw badRequest(`part ${partNumber} out of range — S3 принимает не больше ${MAX_PARTS} частей`);
    }
    const before = storedParts(row.parts);
    const uploaded = this.receivedBytes(before);
    // «Последняя ли это часть» считается по достигнутому объёму, а не по partCount(DIRECT_PART_BYTES):
    // клиент релея сам выбирает размер чанка, и по константе сервера его короткий хвост выглядел
    // не последней частью — загрузка падала на «часть N меньше 5 МБ» уже в самом конце.
    const isLast = uploaded + chunk.length >= size;
    // S3 требует не меньше 5 МБ на часть, кроме последней: иначе complete падал бы 500'кой
    if (!isLast && chunk.length < MIN_RELAY_PART_BYTES) {
      throw badRequest(`часть ${partNumber} меньше 5 МБ — S3 такую не примет`);
    }
    // Предел S3 — 10 000 частей на multipart. Размер части релея выбирает клиент, поэтому
    // ловим несовместимость на ПЕРВОЙ же части (а не на complete после многочасовой заливки):
    // при таких чанках частей выйдет больше предела, и собрать файл не получится вообще.
    // Короткий последний чанк не проверяем — по нему оценка числа частей была бы завышена.
    if (!isLast && chunk.length > 0 && Math.ceil(size / chunk.length) > MAX_PARTS) {
      throw badRequest(
        `части по ${chunk.length} байт дадут больше ${MAX_PARTS} частей, а S3 столько не принимает: ` +
          `льёте частями от ${Math.ceil(size / MAX_PARTS)} байт`,
      );
    }

    const live = this.live.get(uploadId) ?? this.resumeRelay(uploadId, before.length);
    const expected = before.length + 1;
    if (partNumber < expected) {
      // идемпотентность: повторный/дублирующийся чанк — считаем успешным
      return {
        uploadId,
        nextPart: expected,
        duplicate: true,
        receivedBytes: uploaded,
      };
    }
    if (partNumber > expected) {
      throw badRequest(`missing part ${expected} (got ${partNumber}) — upload out of order`);
    }

    const etag = await this.s3.uploadPart(row.uploadKey, row.s3UploadId, partNumber, chunk);
    live.hash.update(chunk);
    const parts = await this.savePart(row, { partNumber, etag, size: chunk.length });
    // receivedBytes — объём принятого, а не «номер части × длину последнего чанка»: чанки
    // бывают разного размера (последний короче), и от такого умножения клиент показывал
    // прогресс больше файла или врал на многогигабайтной загрузке.
    return { uploadId, nextPart: partNumber + 1, receivedBytes: this.receivedBytes(parts) };
  }

  /**
   * Сессия релея после рестарта процесса: части лежат в БД, а инкрементального хэша нет.
   * Заводим новый и помечаем его неполным — `complete` по такому хэшу sha256 не считает.
   */
  private resumeRelay(uploadId: string, alreadyParts: number): LiveSession {
    const live: LiveSession = { hash: createHash('sha256'), hashValid: false };
    this.live.set(uploadId, live);
    this.logger.warn(
      `сессия загрузки ${uploadId} продолжена после рестарта (частей уже ${alreadyParts}): ` +
        'инкрементальный хэш потерян, sha256 будет пересчитан по объекту в S3',
    );
    return live;
  }

  /**
   * Собрать загрузку: объект в S3 → запись в дереве.
   *
   * Повторный вызов идемпотентен (и это часть контракта: клиент на плохой сети повторяет
   * `complete` после потерянного ответа) — пока `finish` не отработал, tmp-объект остаётся
   * на месте, поэтому повтор проходит по тому же пути, а не упирается в «объекта нет в S3».
   * Дорогая часть повтора — sha256: он считается полным чтением объекта из S3 (см. шаг 3),
   * это осознанная цена за то, что ключ объекта content-addressed и доверять хэшу клиента
   * нельзя (для 50 ГБ это десятки минут трафика из бакета).
   */
  async complete(uploadId: string, userId: string, body: { sha256?: unknown } = {}) {
    const row = await this.requireSession(uploadId, userId);
    // повторный complete (ретрай после потерянного ответа) — отдаём тот же результат
    if (row.completedAt && row.result) return row.result;
    const live = this.live.get(uploadId);
    const size = Number(row.size);
    const mime = row.mime;

    const parts = storedParts(row.parts);
    // Пустой файл: части могло не быть ни одной (передавать нечего), а multipart без частей
    // S3 не собирает — кладём пустой объект одним PUT. Если клиент прислал пустую часть
    // (телефон так и делает), собираем multipart как обычно.
    const emptyWithoutParts = !parts.length && size === 0;
    if (!parts.length && !emptyWithoutParts) throw badRequest('no parts uploaded');
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].partNumber !== i + 1) {
        throw badRequest(`missing part ${i + 1} — загрузка неполная`);
      }
    }
    // Сумму зарегистрированных размеров сверяем ДО финализации: клиент заявляет размер части
    // сам, и если он меньше факта, ошибка иначе всплывёт только после сборки multipart в S3
    // («в S3 N байт, ожидалось M» — уже потратив всю заливку). Недобор — отказ сразу, с числом
    // недостающих байт; перебор оставляем проверке размера по факту (шаг 2), чтобы объявленный
    // клиентом размер не мог отвергнуть корректную загрузку.
    const declaredBytes = this.receivedBytes(parts);
    if (!emptyWithoutParts && parts.every((p) => (p.size ?? 0) > 0) && declaredBytes < size) {
      throw badRequest(
        `части покрывают ${declaredBytes} байт из ${size} — не хватает ${size - declaredBytes}, загрузка неполная`,
      );
    }

    // 1. Собираем объект. Повторный complete (сетевой ретрай клиента или рестарт сервиса
    //    между финализацией и записью в дерево) идемпотентен.
    if (emptyWithoutParts) {
      await this.s3.putObject(row.uploadKey, Buffer.alloc(0), mime);
      // multipart-сессия пустому файлу не нужна: объект записан одним PUT, а брошенная
      // сессия висела бы в S3 до ручной уборки (части в неё никто не загружал)
      await this.s3.abortMultipartUpload(row.uploadKey, row.s3UploadId).catch(() => undefined);
    } else if (!live?.finalized) {
      try {
        await this.s3.completeMultipartUpload(
          row.uploadKey,
          row.s3UploadId,
          parts.map((p) => ({ PartNumber: p.partNumber, ETag: p.etag })),
        );
        if (live) live.finalized = true;
      } catch (e) {
        // multipart уже собран (NoSuchUpload) — решает проверка размера ниже
        if (!(await this.s3.headObject(row.uploadKey))) throw e;
      }
    }

    // 2. Размер по факту в S3: недолитая загрузка не должна попасть в дерево.
    //    headObject отдельно от objectSize: у отсутствующего объекта размер тоже 0,
    //    и пустой файл (size 0) прошёл бы сверку, вообще не доехав до S3.
    if (!(await this.s3.headObject(row.uploadKey))) {
      const replayed = await this.replayFinish(row);
      if (replayed) return replayed;
      await this.cleanup(row);
      throw badRequest('объекта нет в S3 — загрузка неполная');
    }
    const realSize = await this.s3.objectSize(row.uploadKey);
    if (realSize !== size) {
      await this.cleanup(row);
      throw badRequest(`в S3 ${realSize} байт, ожидалось ${size} — загрузка неполная`);
    }

    // 3. sha256. При релее хэш посчитан по ходу чанков; при прямой загрузке сервер байтов
    //    не видел — считаем хэш по объекту в S3. Ключ content-addressed, поэтому заявленный
    //    клиентом хэш только проверяется, но никогда не используется «на веру».
    const claimed = normalizeSha(body.sha256) ?? normalizeSha(row.declaredSha256);
    // Инкрементальный хэш верен только для релея, который шёл в этом же процессе целиком
    // (hashValid): при прямой загрузке сервер байтов не видел и digest() отдал бы sha256
    // пустого буфера, а у продолженной после рестарта сессии хэш покрывает только хвост —
    // в обоих случаях sha256 считается по объекту в S3, иначе файл получил бы чужое
    // содержимое и отравил бы дедуп для всего хранилища.
    const incremental = !row.direct && live?.hashValid !== false ? live?.hash.digest('hex') : undefined;
    let sha256 = live?.sha256 ?? (row.direct ? undefined : incremental);
    if (live && sha256) live.sha256 = sha256;
    if (!sha256 || (claimed && claimed !== sha256)) {
      const computed = await this.s3.hashObject(row.uploadKey);
      if (claimed && claimed !== computed) {
        await this.cleanup(row);
        throw badRequest('содержимое не совпало с заявленным sha256', 'upload_hash_mismatch');
      }
      sha256 = computed;
    }

    const finalKey = S3Service.assetKey(sha256);
    const existingAsset = await this.prisma.asset.findUnique({ where: { sha256 } });

    let assetId: string;
    let deduped = false;
    if (existingAsset) {
      // содержимое уже в S3 — multipart не перекладываем, tmp удаляем
      deduped = true;
      assetId = existingAsset.id;
    } else {
      // финализируем tmp-объект и перекладываем под content-addressed ключ (server-side copy)
      if (!(await this.s3.headObject(finalKey))) {
        await this.s3.copyObject(row.uploadKey, finalKey);
      }
      assetId = await this.files.ensureAsset(sha256, size, mime, this.extOf(row.name));
    }

    const done = await this.finish({
      userId,
      folderId: row.folderId,
      name: row.name,
      size,
      mime,
      sha256,
      assetId,
      deduped,
      replace: row.replace,
      restoreDeleted: row.replaceTrashed,
      clientMtime: row.clientMtime,
      expect:
        row.expectedSha256 === null && row.expectedUpdatedAt === null
          ? undefined
          : { sha256: row.expectedSha256, updatedAt: row.expectedUpdatedAt },
    });

    // tmp-объект убираем ТОЛЬКО после успешного finish: если запись в дерево упала
    // (конфликт версий, гонка в БД, ошибка Prisma), повторный complete должен пройти тот же
    // путь и завершиться успехом — а не ответить «объекта нет в S3» и удалить сессию, потеряв
    // уже залитые байты (они лежат под finalKey, но клиент по такому ответу начинает заново).
    await this.s3.deleteObject(row.uploadKey).catch(() => undefined);

    // сессию не удаляем: сохраняем результат, чтобы ретрай complete был идемпотентным
    await this.prisma.uploadSession.update({
      where: { id: uploadId },
      data: { completedAt: new Date(), result: done as unknown as Prisma.InputJsonValue },
    });
    this.live.delete(uploadId);
    return done;
  }

  async abort(uploadId: string, userId: string) {
    const row = await this.requireSession(uploadId, userId);
    await this.cleanup(row);
    return { ok: true };
  }

  /**
   * Повтор complete, когда tmp-объекта уже нет, а сессия ещё жива: значит предыдущий вызов
   * успел собрать объект и записать запись в дерево, но не успел отметить сессию завершённой
   * (обрыв на последнем запросе, ошибка БД). Отдаём тот же результат, а не «загрузка
   * неполная»: иначе клиент по контракту начинает файл заново, хотя он уже в облаке.
   *
   * Запись ищем по паре (папка, имя) и требуем совпадения sha256 с объявленным клиентом: без
   * объявленного хэша отличить свою запись от чужой одноимённой нельзя, и тогда отвечаем как
   * раньше — «объекта нет в S3». Сессию при этом ещё не удалял cleanup (tmp пропал после
   * успешного finish), поэтому путать этот случай с «загрузку отменили» не приходится.
   */
  private async replayFinish(row: SessionRow): Promise<FinishResult | null> {
    const declared = normalizeSha(row.declaredSha256);
    if (!declared) return null;
    const folderId = row.folderId ?? (await this.auth.rootFolderId(row.userId));
    const existing = await this.prisma.fileEntry.findFirst({
      where: { folderId, name: row.name, deletedAt: null },
      include: { asset: { select: { sha256: true, size: true, mime: true } } },
    });
    if (!existing || existing.asset.sha256 !== declared) return null;
    const done: FinishResult = {
      entry: { id: existing.id },
      asset: { sha256: declared, size: Number(existing.asset.size), mime: existing.asset.mime },
      deduped: true,
      replaced: Boolean(row.replace),
      zone: existing.zone,
    };
    await this.prisma.uploadSession
      .update({ where: { id: row.id }, data: { completedAt: new Date(), result: done as unknown as Prisma.InputJsonValue } })
      .catch(() => undefined);
    this.live.delete(row.id);
    this.logger.warn(`complete ${row.id}: tmp-объекта нет, но запись уже в дереве — отдаю результат прошлого вызова`);
    return done;
  }

  /**
   * Общая концовка: запись в дерево + медиа-часть. Используется и прямой загрузкой
   * (complete), и дедупом до передачи байтов (init).
   */
  private async finish(params: {
    userId: string;
    folderId: string | null;
    name: string;
    size: number;
    mime: string;
    sha256: string;
    assetId: string;
    deduped: boolean;
    replace?: boolean;
    /** Имя занято своей же записью из корзины (кроме WebDAV — только по флагу replaceTrashed). */
    restoreDeleted?: boolean;
    clientMtime?: Date | null;
    expect?: { sha256?: string | null; updatedAt?: Date | null };
  }): Promise<FinishResult> {
    const folderId = params.folderId ?? (await this.auth.rootFolderId(params.userId));
    let entry: { id: string; deduped: boolean; zone: string; replaced: boolean };
    try {
      entry = await this.files.createEntry(folderId, params.name, params.assetId, {
        userId: params.userId,
        replace: params.replace,
        restoreDeleted: params.restoreDeleted,
        clientMtime: params.clientMtime ?? null,
        expect: params.expect,
        asset: { sha256: params.sha256, size: params.size, mime: params.mime },
      });
    } catch (e) {
      // Успехом считаем ТОЛЬКО повторный complete, то есть конфликт имени, когда рядом уже
      // лежит живая запись с тем же содержимым. Раньше здесь глоталась любая ошибка, если
      // такая запись находилась: расхождение версий (`stale_version`) и запись из корзины
      // (`in_trash`) превращались в «успех с replaced: false», и клиент синхронизации молча
      // получал не то, что просил («замени версию X» — а версия другая).
      const existing = await this.prisma.fileEntry.findFirst({
        where: { folderId, name: params.name, deletedAt: null },
      });
      if (errorCode(e) === 'conflict' && params.expect === undefined && existing?.assetId === params.assetId) {
        entry = { id: existing.id, deduped: true, zone: existing.zone, replaced: false };
      } else {
        throw e;
      }
    }

    // Метаданные сохраняем для любых фото и видео, независимо от зоны: зона решает, где файл
    // лежит и строятся ли для него превью, но не то, знаем ли мы дату съёмки, координаты, камеру
    // и параметры кадра. Повторную загрузку того же содержимого не пересобираем.
    await this.media.captureAny(params.assetId, params.sha256, params.size, params.mime).catch(() => undefined);

    // Тяжёлое (превью и конвертация) — по-прежнему только для медиа-зоны «Фото»
    if (entry.zone === ZONE_PHOTOS) {
      // Файл в медиа-зоне обязан быть виден в ленте. У RAW камер и скриншотов без EXIF даты
      // съёмки нет, и раньше такая запись просто не появлялась в «Фото». Ставим дату загрузки —
      // тем же способом, каким её получают видео; настоящая дата съёмки (если разбор её нашёл)
      // не перетирается.
      await this.media.fillDateAndGeo(params.assetId, new Date(), null).catch(() => undefined);
      await this.queue.enqueue(params.assetId, params.sha256, params.mime);
    }

    return {
      entry: { id: entry.id },
      asset: { sha256: params.sha256, size: params.size, mime: params.mime },
      deduped: params.deduped,
      replaced: entry.replaced,
      zone: entry.zone,
    };
  }

  private extOf(name: string): string | undefined {
    const i = name.lastIndexOf('.');
    if (i <= 0 || i === name.length - 1) return undefined;
    return name.slice(i + 1).toLowerCase().slice(0, 16);
  }
}
