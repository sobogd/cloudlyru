import { createSHA256 } from 'hash-wasm';

const BASE = '/api/v1';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(BASE + path, {
    credentials: 'include',
    ...init,
    headers: { ...(init?.body && typeof init.body === 'string' ? { 'Content-Type': 'application/json' } : {}), ...(init?.headers || {}) },
  });
  const text = await res.text();
  let data: unknown = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const msg = data && typeof data === 'object' && 'message' in data ? String((data as { message: unknown }).message) : `HTTP ${res.status}`;
    const err = new Error(msg) as Error & { status?: number; code?: string };
    err.status = res.status;
    // Код нужен вызывающему: по `cursor_stale` лента понимает, что запись-курсор исчезла,
    // и откатывается на предыдущую запись вместо «лента кончилась».
    if (data && typeof data === 'object' && 'code' in data) err.code = String((data as { code: unknown }).code);
    throw err;
  }
  return data as T;
}

// ===== типы =====
export interface FolderEntry { id: string; name: string; createdAt?: string; size?: number; mime?: string }
export interface FolderView { parentId: string; folders: FolderEntry[]; entries: FolderEntry[] }
export interface ShareInfo {
  token: string; url: string; kind: string; capability: string; targetId: string;
  hasPassword: boolean; expiresAt: string | null; createdAt: string;
}
export interface TrashItem { id: string; name: string; deletedAt: string; kind: 'folder' | 'file'; size?: number }
export interface TrashView { folders: TrashItem[]; entries: TrashItem[] }

// ===== auth =====
export interface UserInfo {
  id: string;
  login: string;
  rootFolderId: string | null;
  photoFolderId: string | null; // системная папка «Фото» (медиа-зона)
  phoneFolderId: string | null; // легаси-папка «Телефон», если она есть; сервер её больше не заводит
}
export const login = (login: string, password: string) =>
  request<{ user: UserInfo }>('/auth/login', { method: 'POST', body: JSON.stringify({ login, password }) });
export const me = () => request<UserInfo>('/auth/me');
export const logout = () => request<{ ok: boolean }>('/auth/logout', { method: 'POST' });

// ===== folders/files =====
export const listFolder = (parentId?: string) =>
  request<FolderView>(parentId ? `/folders/${parentId}/children` : '/folders');
export const mkdir = (name: string, parentId?: string) =>
  request<{ id: string }>('/folders', { method: 'POST', body: JSON.stringify({ name, ...(parentId ? { parentId } : {}) }) });
export const renameFolder = (id: string, name: string) =>
  request<unknown>(`/folders/${id}`, { method: 'PATCH', body: JSON.stringify({ name }) });
/** Переименование файла: сервер проверит имя (255 байт, без «/») и конфликт с тёзкой (409). */
export const renameFile = (id: string, name: string) =>
  request<unknown>(`/files/${id}`, { method: 'PATCH', body: JSON.stringify({ name }) });
export const deleteFolder = (id: string) => request<{ ok: boolean }>(`/folders/${id}`, { method: 'DELETE' });
export const deleteFile = (id: string) => request<{ ok: boolean }>(`/files/${id}`, { method: 'DELETE' });
/** Скачивание оригинала: сервис отдаёт его с Content-Disposition: attachment. */
export const fileUrl = (id: string) => `${BASE}/files/${id}/content`;
/** Показ файла на странице (миниатюры альбомов): сервис отдаёт только безопасные картинки. */
export const fileInlineUrl = (id: string) => `${BASE}/files/${id}/inline`;

// ===== метаданные для деталок =====
export interface FileMedia {
  capturedAt: string | null;
  latitude?: number;
  longitude?: number;
  make?: string;
  model?: string;
  width?: number;
  height?: number;
  /** Полный набор извлечённых тегов: EXIF для фото, ffprobe для видео */
  raw?: Record<string, unknown> | null;
}
export interface FileMeta {
  id: string; name: string; createdAt: string; folderId: string; zone: string; path: string;
  size: number; mime: string; ext?: string; sha256: string;
  /** Число страниц PDF (есть после того, как очередь отрисовала превью страниц). */
  pageCount?: number;
  media?: FileMedia | null;
}
export const fileMeta = (id: string) => request<FileMeta>(`/files/${id}`);

// ===== буфер копирования/вырезания =====
export interface ClipboardView {
  kind: 'file' | 'folder';
  mode: 'copy' | 'cut';
  id: string;
  name: string;
  /** false — цели больше нет (удалена или в корзине): вставка скажет об этом. */
  available: boolean;
  at: string | null;
}
/** Буфер живёт на сервере (один на аккаунт), поэтому виден с любого устройства. */
export const clipboard = () => request<ClipboardView | null>('/clipboard');
export const setClipboard = (kind: 'file' | 'folder', id: string, mode: 'copy' | 'cut') =>
  request<ClipboardView>('/clipboard', { method: 'POST', body: JSON.stringify({ kind, id, mode }) });
export const clearClipboard = () => request<{ ok: boolean }>('/clipboard', { method: 'DELETE' });
export const pasteClipboard = (folderId: string) =>
  request<{ ok: boolean; action: 'moved' | 'copied'; name: string }>('/clipboard/paste', {
    method: 'POST',
    body: JSON.stringify({ folderId }),
  });
export interface FolderMeta {
  id: string; name: string; zone: string; path: string;
  folders: number; entries: number; createdAt: string; updatedAt: string;
}
export const folderMeta = (id: string) => request<FolderMeta>(`/folders/${id}/meta`);

const CHUNK_BYTES = 5 * 1024 * 1024;
/** Часть при прямой загрузке в S3 (сервер уточняет размер в init). */
const FALLBACK_PART_BYTES = 16 * 1024 * 1024;
/** Сколько частей льём в S3 одновременно (память: concurrency × partSize). */
const DIRECT_CONCURRENCY = 3;
const HASH_CHUNK_BYTES = 8 * 1024 * 1024;
/** Сколько ждём байты одной части, прежде чем считать PUT в S3 зависшим. */
const PART_STALL_MS = 45_000;
/** Попыток на часть при «обычной» сетевой ошибке; зависшую часть пробуем ещё раз только один. */
const PART_ATTEMPTS = 3;
const PART_STALL_ATTEMPTS = 2;

export type UploadPhase = 'hash' | 'upload' | 'relay' | 'verify';

/** mime по расширению, если браузер не отдал type (HEIC/RAW и т.п.). */
export function guessMime(file: { name: string; type: string }): string {
  if (file.type) return file.type;
  const ext = file.name.split('.').pop()?.toLowerCase() ?? '';
  const map: Record<string, string> = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp',
    heic: 'image/heic', heif: 'image/heif', tif: 'image/tiff', tiff: 'image/tiff',
    mp4: 'video/mp4', mov: 'video/quicktime', m4v: 'video/x-m4v', webm: 'video/webm',
    mkv: 'video/x-matroska', avi: 'video/avi', '3gp': 'video/3gpp', ogv: 'video/ogg',
    pdf: 'application/pdf', txt: 'text/plain', zip: 'application/zip',
  };
  return map[ext] ?? 'application/octet-stream';
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** PUT чанка с ретраями: сеть/5xx — повтор до 3 раз; ответ сервера на дубликат — 200 (идемпотентно). */
async function putChunk(uploadId: string, part: number, buf: ArrayBuffer, signal?: AbortSignal): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    let res: Response;
    try {
      res = await fetch(`${BASE}/uploads/${uploadId}/chunks/${part}`, {
        method: 'PUT',
        credentials: 'include',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: buf,
        signal,
      });
    } catch (e) {
      if (signal?.aborted) throw new Error('загрузка отменена');
      if (attempt >= 3) throw new Error(`часть ${part}: сеть недоступна — ${(e as Error).message}`);
      await sleep(700 * attempt);
      continue;
    }
    if (res.ok) return;
    if (res.status >= 500 && attempt < 3) {
      await sleep(700 * attempt);
      continue;
    }
    let msg = `часть ${part}: HTTP ${res.status}`;
    try { const b = await res.clone().json(); if (b?.message) msg = `часть ${part}: ${b.message}`; } catch { /* ignore */ }
    throw new Error(msg);
  }
}

export async function uploadFile(
  file: File,
  folderId: string | undefined,
  onProgress?: (pct: number, phase: UploadPhase, note?: string) => void,
  signal?: AbortSignal,
): Promise<{ entry: { id: string }; deduped: boolean }> {
  const mime = guessMime(file);

  // sha256 считаем ДО загрузки: сервер по нему либо вообще не начнёт передачу
  // (объект с таким содержимым уже есть), либо использует его как ключ объекта в S3.
  const sha256 = await hashFile(file, signal, (p) => onProgress?.(p, 'hash'));
  // Хеш готов — фаза меняется сразу, иначе панель ещё десятки секунд показывает
  // «считаю sha256 · 100%», хотя байты уже уходят (первая часть идёт до первого события).
  onProgress?.(0, 'upload');

  let init = await initUpload(file, folderId, mime, sha256, 'direct');
  if (init.deduped && init.entry) return { entry: init.entry, deduped: true };
  let uploadId = init.uploadId as string;

  try {
    if (init.direct) {
      try {
        await uploadDirect(file, uploadId, init.partSize ?? FALLBACK_PART_BYTES, signal, onProgress);
      } catch (e) {
        // Браузер не смог ходить в S3 напрямую (нет CORS, сеть режет, S3 не отвечает) —
        // пересоздаём сессию и льём чанки через сервер: медленнее, но работает.
        if (!(e instanceof DirectUnavailable) || signal?.aborted) throw e;
        await abortUpload(uploadId);
        init = await initUpload(file, folderId, mime, sha256, 'relay');
        if (init.deduped && init.entry) return { entry: init.entry, deduped: true };
        uploadId = init.uploadId as string;
        onProgress?.(0, 'relay', e.message);
        await uploadChunks(file, uploadId, signal, onProgress, 'relay');
      }
    } else {
      await uploadChunks(file, uploadId, signal, onProgress);
    }
    // complete — сервер собирает multipart и перечитывает объект из S3, чтобы посчитать
    // sha256 по факту: на большом файле это заметная пауза, о ней надо сказать честно.
    onProgress?.(100, 'verify');
    return await request<{ entry: { id: string }; deduped: boolean }>(`/uploads/${uploadId}/complete`, {
      method: 'POST',
      body: JSON.stringify({ sha256 }),
    });
  } catch (e) {
    // подчистить незавершённую сессию на сервере (multipart abort), если она осталась
    await abortUpload(uploadId);
    throw e;
  }
}

/** Прямая загрузка в S3 не удалась так, что имеет смысл уйти на релей через сервер. */
class DirectUnavailable extends Error {}

/** Часть не отдала ни одного байта за отведённое время — запрос завис, а не «идёт медленно». */
class PartStalled extends Error {}

interface UploadInit {
  uploadId: string | null;
  deduped: boolean;
  direct: boolean;
  partSize?: number;
  entry?: { id: string };
}

function initUpload(
  file: File,
  folderId: string | undefined,
  mime: string,
  sha256: string,
  mode: 'direct' | 'relay',
): Promise<UploadInit> {
  return request<UploadInit>('/uploads', {
    method: 'POST',
    body: JSON.stringify({ folderId, name: file.name, size: file.size, mime, sha256, mode }),
  });
}

async function abortUpload(uploadId: string): Promise<void> {
  try {
    await fetch(`${BASE}/uploads/${uploadId}`, { method: 'DELETE', credentials: 'include' });
  } catch {
    /* ignore */
  }
}

/** sha256 файла инкрементально (hash-wasm, WASM ~ГБ/с) — файл целиком в память не читаем. */
async function hashFile(
  file: File,
  signal?: AbortSignal,
  onProgress?: (pct: number) => void,
): Promise<string> {
  const hasher = await createSHA256();
  hasher.init();
  for (let off = 0; off < file.size; off += HASH_CHUNK_BYTES) {
    if (signal?.aborted) throw new Error('загрузка отменена');
    const end = Math.min(file.size, off + HASH_CHUNK_BYTES);
    hasher.update(new Uint8Array(await file.slice(off, end).arrayBuffer()));
    onProgress?.(Math.round((end / file.size) * 100));
  }
  return hasher.digest('hex');
}

/** Presigned-ссылка на часть (подписывает сервер, байты идут мимо него). */
async function presignPart(uploadId: string, part: number): Promise<string> {
  try {
    const r = await request<{ url: string }>(`/uploads/${uploadId}/url/${part}`);
    return r.url;
  } catch (e) {
    const status = (e as { status?: number }).status;
    if (status === 404 || status === 405) {
      throw new DirectUnavailable('сервер не поддерживает прямую загрузку в S3');
    }
    throw e;
  }
}

/**
 * PUT части прямо в S3 по presigned-ссылке. Возвращает ETag (нужен для complete).
 *
 * Через XHR, а не fetch, по двум причинам: (1) нужен прогресс по байтам — иначе 16-МиБ
 * часть сутками «висит» без движения индикатора; (2) fetch без таймаута не отличит
 * мёртвый сокет от медленной сети, и загрузка замирает навсегда. Часть без байтов
 * дольше PART_STALL_MS считаем зависшей: повторяем один раз и уходим на релей.
 */
function putPartDirect(
  url: string,
  buf: ArrayBuffer,
  signal?: AbortSignal,
  onBytes?: (loaded: number) => void,
  onNote?: (note: string) => void,
): Promise<string> {
  let last: Error | null = null;
  const send = () => putPartOnce(url, buf, signal, onBytes, onNote);
  const loop = async (): Promise<string> => {
    for (let attempt = 1; ; attempt++) {
      if (signal?.aborted) throw new Error('загрузка отменена');
      try {
        return await send();
      } catch (e) {
        if (signal?.aborted) throw e;
        if (e instanceof DirectUnavailable) throw e;
        last = e as Error;
        const limit = e instanceof PartStalled ? PART_STALL_ATTEMPTS : PART_ATTEMPTS;
        if (attempt >= limit) break;
        onBytes?.(0); // прогресс обнуляем: часть переливаем с нуля
        onNote?.(`${last.message} — повторяю (попытка ${attempt + 1})`);
        await sleep(700 * attempt);
      }
    }
    throw new DirectUnavailable(`прямая загрузка в S3 не удалась: ${last?.message ?? 'неизвестная ошибка'}`);
  };
  return loop();
}

/** Одна попытка PUT части: прогресс по байтам + watchdog на «ни одного байта за 45 с». */
function putPartOnce(
  url: string,
  buf: ArrayBuffer,
  signal?: AbortSignal,
  onBytes?: (loaded: number) => void,
  onNote?: (note: string) => void,
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    let stalled = false;
    let lastTick = Date.now();
    let finished = false;

    const stop = () => {
      clearInterval(watchdog);
      signal?.removeEventListener('abort', onCancel);
    };
    const onCancel = () => xhr.abort();
    const watchdog = setInterval(() => {
      if (Date.now() - lastTick > PART_STALL_MS) {
        stalled = true;
        onNote?.(`S3 не отдал ни байта за ${Math.round(PART_STALL_MS / 1000)} с — прерываю`);
        xhr.abort();
      }
    }, 1000);

    const finish = (fn: () => void) => {
      if (finished) return;
      finished = true;
      stop();
      fn();
    };

    signal?.addEventListener('abort', onCancel, { once: true });
    xhr.open('PUT', url, true);
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.upload.onprogress = (e) => {
      lastTick = Date.now();
      onBytes?.(e.loaded);
    };
    xhr.onload = () =>
      finish(() => {
        if (xhr.status >= 200 && xhr.status < 300) {
          const etag = xhr.getResponseHeader('etag');
          if (!etag) {
            reject(new DirectUnavailable('S3 не отдал ETag — в CORS-правиле бакета нет ExposeHeaders: ETag'));
            return;
          }
          resolve(etag);
          return;
        }
        reject(new Error(`S3 ответил HTTP ${xhr.status}`));
      });
    // сюда попадает и сетевая ошибка, и CORS-отказ: и то и другое — повод попробовать ещё раз
    xhr.onerror = () => finish(() => reject(new Error('сеть до S3 недоступна (CORS или обрыв)')));
    xhr.ontimeout = () => finish(() => reject(new Error('таймаут S3')));
    xhr.onabort = () =>
      finish(() => {
        if (signal?.aborted) reject(new Error('загрузка отменена'));
        else if (stalled) reject(new PartStalled(`S3 не принял ни байта за ${Math.round(PART_STALL_MS / 1000)} с`));
        else reject(new Error('запрос к S3 прерван'));
      });
    xhr.send(buf);
  });
}

/** Части льём в S3 параллельно; ETag каждой части сообщаем серверу. */
async function uploadDirect(
  file: File,
  uploadId: string,
  partSize: number,
  signal?: AbortSignal,
  onProgress?: (pct: number, phase: UploadPhase, note?: string) => void,
): Promise<void> {
  const total = Math.max(1, Math.ceil(file.size / partSize));
  // Прогресс считаем по байтам, а не по «частям целиком»: внутри 16-МиБ части индикатор
  // обязан двигаться, иначе панель выглядит зависшей.
  const loaded = new Array<number>(total + 1).fill(0);
  let next = 1;

  const report = (note?: string) => {
    const sum = loaded.reduce((a, b) => a + b, 0);
    onProgress?.(Math.min(100, Math.floor((sum / file.size) * 100)), 'upload', note);
  };

  const worker = async () => {
    for (;;) {
      const part = next++;
      if (part > total) return;
      if (signal?.aborted) throw new Error('загрузка отменена');

      const start = (part - 1) * partSize;
      const end = Math.min(file.size, start + partSize);
      report(`часть ${part} из ${total}`);
      const url = await presignPart(uploadId, part);
      const buf = await file.slice(start, end).arrayBuffer();
      const etag = await putPartDirect(
        url,
        buf,
        signal,
        (n) => { loaded[part] = n; report(`часть ${part} из ${total}`); },
        (note) => report(note),
      );
      await request<unknown>(`/uploads/${uploadId}/parts/${part}`, {
        method: 'PUT',
        body: JSON.stringify({ etag, size: buf.byteLength }),
      });

      loaded[part] = buf.byteLength;
      report(`часть ${part} из ${total}`);
    }
  };

  await Promise.all(
    Array.from({ length: Math.min(DIRECT_CONCURRENCY, total) }, () => worker()),
  );
}

/** Фолбэк: чанки через сервер (сервер сам пишет их в S3 multipart-частями). */
async function uploadChunks(
  file: File,
  uploadId: string,
  signal?: AbortSignal,
  onProgress?: (pct: number, phase: UploadPhase, note?: string) => void,
  phase: UploadPhase = 'upload',
): Promise<void> {
  const parts = Math.max(1, Math.ceil(file.size / CHUNK_BYTES));
  for (let part = 1; part <= parts; part++) {
    const start = (part - 1) * CHUNK_BYTES;
    const end = Math.min(file.size, start + CHUNK_BYTES);
    const buf = await file.slice(start, end).arrayBuffer();
    await putChunk(uploadId, part, buf, signal);
    onProgress?.(Math.round((part / parts) * 100), phase, `часть ${part} из ${parts}`);
  }
}

// ===== trash =====
export const trash = () => request<TrashView>('/trash');
export const restoreItem = (kind: 'folder' | 'file', id: string) =>
  request<unknown>('/trash/restore', { method: 'POST', body: JSON.stringify({ type: kind, id }) });
export const purgeTrash = () => request<unknown>('/trash/purge', { method: 'POST', body: JSON.stringify({}) });

// ===== shares =====
export const listShares = () => request<ShareInfo[]>('/shares');
export const createShare = (body: { kind: 'folder' | 'file'; targetId: string; password?: string; capability?: string; expiresAt?: string | null }) =>
  request<ShareInfo>('/shares', { method: 'POST', body: JSON.stringify(body) });
export const revokeShare = (token: string) => request<{ ok: boolean }>(`/shares/${token}`, { method: 'DELETE' });

// ===== app-токены (WebDAV/клиенты) =====
export interface ApiTokenRow { id: string; label: string; scope: string; lastUsedAt: string | null; createdAt: string }
export const listTokens = () => request<ApiTokenRow[]>('/auth/tokens');
export const createToken = (label: string) => request<{ id: string; token: string; label: string }>('/auth/tokens', { method: 'POST', body: JSON.stringify({ label }) });
export const revokeToken = (id: string) => request<{ ok: boolean }>(`/auth/tokens/${id}`, { method: 'DELETE' });

// ===== M2: timeline / albums =====
/**
 * Строка ленты. Состояния задачи сборки здесь нет намеренно: сервер отдаёт его отдельной
 * ручкой (timelineStatus) только про незавершённые снимки — тянуть его для каждой записи
 * каждой страницы значит платить лишним запросом на строку.
 */
export interface TimelineItem { entryId: string; name: string; capturedAt: string | null; mime: string; sha256?: string; previewState: string; size: number }
/** Статус сборки превью (POST /timeline/status): отвечаем только про свои записи. */
export interface TimelineStatus {
  entryId: string;
  /** 'none' — превью ещё нет, 'done' — собраны, 'impossible' — собрать нельзя (см. previewError). */
  previewState: string;
  previewError: string | null;
  jobState: string | null;
  jobError: string | null;
}
// ===== Раздел «Медиа» (изолированные ручки /media/*) =====
/** Строка ленты «Медиа»: тот же контракт, что у TimelineItem, но из своего модуля. */
export interface MediaItem { entryId: string; name: string; capturedAt: string | null; mime: string; sha256?: string; previewState: string; jobState: string | null; size: number }
/** Общее число медиа — по нему клиент считает полную высоту скролла. */
export const mediaCount = () => request<number>('/media/count');
/** Срез ленты по смещению: элементы [offset, offset+limit) в порядке ленты. */
export const mediaRange = (offset: number, limit: number) =>
  request<MediaItem[]>(`/media/range?offset=${offset}&limit=${limit}`);
/** Индекс по месяцам для подписи у ползунка: строка на месяц, month=null — «без даты». */
export interface MediaMonthBucket { month: string | null; count: number }
export const mediaMonths = () => request<MediaMonthBucket[]>('/media/months');
/** Статусы превью по списку записей (только неготовые снимки). */
export interface MediaStatusItem { entryId: string; previewState: string; jobState: string | null }
export const mediaStatus = (entryIds: string[]) =>
  request<MediaStatusItem[]>('/media/status', { method: 'POST', body: JSON.stringify({ entryIds }) });
/** Метаданные кадра для панели «Инфо» в модалке. */
export interface MediaInfo {
  entryId: string;
  name: string;
  mime: string;
  size: number;
  sha256: string;
  capturedAt: string | null;
  width: number | null;
  height: number | null;
  make: string | null;
  model: string | null;
  latitude: number | null;
  longitude: number | null;
}
export const mediaInfo = (entryId: string) =>
  request<MediaInfo>(`/media/${encodeURIComponent(entryId)}`);

export interface AlbumInfo { id: string; name: string; createdAt: string; count: number }
export interface AlbumView extends AlbumInfo { items: Array<{ entryId: string; name: string; size: number; mime: string; capturedAt: string | null }> }

/**
 * Превью: любое `w` меньше 1080 — это миниатюра списка (квадрат 50×50), 1080 и выше — полный
 * экран. Отдельного превью на 512 px на сервере нет, поэтому значение по умолчанию — как у сетки.
 */
export const previewUrl = (sha: string, w = 512) => `/api/v1/previews/${sha}?w=${w}`;
/** Страница PDF: превью, отрисованное сервером (нумерация с единицы). */
export const pdfPageUrl = (sha: string, page: number) => `/api/v1/previews/${sha}?page=${page}`;
/** Превью видео (1080, AV1); original=true — сам файл: фолбэк для браузеров без AV1. */
export const videoPreviewUrl = (sha: string, original = false) =>
  `/api/v1/video-preview/${sha}${original ? '?src=original' : ''}`;
/** Миниатюра 50×50 для списка файлов (по id записи, sha256 в списке нет). */
export const thumbUrl = (entryId: string) => `${BASE}/files/${entryId}/thumb`;
export interface QueueStatus {
  /** Конвертация на паузе: состояние хранится в БД, живёт до снятия. */
  paused: boolean;
  /** Сколько задач осталось: ожидают и считаются сейчас. Готовая задачу строку не оставляет. */
  remaining: number;
  processing: number;
  /** Упавшие задачи: строка остаётся, пока её не разберут. */
  errors: number;
  /** Из чего состоит остаток: фото разбираются пачкой и быстро, видео идёт по одному и часами. */
  remainingByKind: { photo: number; video: number; pdf: number };
  /** Свободно байт на диске сервера (null — сервер не смог посчитать). */
  diskFree: number | null;
  /** Места мало — конвертация стоит, пока не освободится. */
  diskLow: boolean | null;
}
export const queueStatus = () => request<QueueStatus>('/queue/status');
/** Пересобрать превью упавшего файла: задача конвертации ставится в очередь заново. */
export const retryPreview = (entryId: string) =>
  request<{ ok: boolean }>('/queue/retry', { method: 'POST', body: JSON.stringify({ entryId }) });
/** Пересчёт: найти файлы, у которых превью нет, и поставить им задачи. */
export const rebuildPreviews = () =>
  request<{ queued: number; impossible: number; deduped: number }>('/queue/rebuild', { method: 'POST', body: JSON.stringify({}) });
/**
 * Полная очистка очереди: удаляются все строки задач, включая упавшие. Собранные превью
 * не трогаются — после очистки очередь пуста, пока не нажали «Пересчитать».
 */
export const clearQueue = () =>
  request<{ removed: number; resumed: number }>('/queue/clear', { method: 'POST', body: JSON.stringify({}) });
/** Пауза конвертации (мягкая: текущая задача докачивается, новые не берутся). */
export const setQueuePaused = (paused: boolean) =>
  request<{ paused: boolean }>('/queue/pause', { method: 'POST', body: JSON.stringify({ paused }) });
/** Ошибки конвертации: постранично, с именем файла. */
export interface QueueErrorRow {
  id: string; kind: string; error: string; attempts: number; finishedAt: string | null;
  entryId: string | null; name: string | null;
}
export const queueErrors = (opts: { limit?: number; offset?: number } = {}) => {
  const q = new URLSearchParams();
  q.set('limit', String(opts.limit ?? 50));
  q.set('offset', String(opts.offset ?? 0));
  return request<{ total: number; items: QueueErrorRow[] }>(`/queue/errors?${q}`);
};
/** Вернуть в очередь все упавшие задачи. */
export const retryQueueErrors = () =>
  request<{ retried: number }>('/queue/errors/retry', { method: 'POST', body: JSON.stringify({}) });
/**
 * День календаря «Фото»: обложка (один снимок дня) и сколько снимков в этот день всего.
 * `day` — 'YYYY-MM-DD' по дате съёмки, как она записана в файле.
 */
export interface TimelineDayItem {
  day: string;
  count: number;
  cover: TimelineItem;
}
/**
 * Дни диапазона месяцев для календаря: строка на день, где есть снимки. Календарь листается
 * месяцами вручную, поэтому месяцы тянем пачкой (удержание стрелки не ждёт запрос на каждый
 * месяц) — 12 месяцев это ~365 строк, всё равно меньше одной страницы ленты.
 */
/**
 * Дни диапазона месяцев для календаря: строка на день, где есть снимки. Месяцы тянем пачкой
 * (`from`..`to`), а `signal` нужен листанию: нажатие стрелки отменяет запрос прошлого месяца,
 * чтобы ответ устаревшего месяца не перетёр уже открытый.
 */
export const timelineDays = (from: string, to: string, signal?: AbortSignal) =>
  request<TimelineDayItem[]>(`/timeline/days?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`, { signal });
/** Края листания календаря: самый новый и самый старый месяцы со снимками (null — снимков нет). */
export const timelineMonths = () =>
  request<{ newest: string | null; oldest: string | null }>('/timeline/months');
/**
 * Соседний снимок для полноэкранного просмотра: `entryId` — текущий кадр, `dir` — 'next' (старее)
 * или 'prev' (новее). Одним запросом, без загрузки дня или месяца; на краю ленты вернётся null.
 */
export const neighborPhoto = (entryId: string, dir: 'next' | 'prev') =>
  request<TimelineItem | null>(`/timeline/neighbor?entryId=${encodeURIComponent(entryId)}&dir=${dir}`);
/**
 * Окно вокруг кадра: `before` снимков новее, `after` старее, сам кадр в середине. Порядок ответа —
 * как у ленты (от свежих к старым), поэтому «следующий» кадр лежит правее по массиву. Просмотр
 * берёт ±20 и листает внутри окна без сети; когда кадр подходит к краю, окно добирается от края.
 */
export const timelineWindow = (entryId: string, before = 20, after = 20) =>
  request<TimelineItem[]>(
    `/timeline/window?entryId=${encodeURIComponent(entryId)}&before=${before}&after=${after}`,
  );
/** Статусы сборки превью по списку записей: спрашиваем только про незавершённые снимки. */
export const timelineStatus = (entryIds: string[]) =>
  request<TimelineStatus[]>('/timeline/status', { method: 'POST', body: JSON.stringify({ entryIds }) });
export const listAlbums = () => request<AlbumInfo[]>('/albums');
export const getAlbum = (id: string) => request<AlbumView>(`/albums/${id}`);
export const createAlbum = (name: string) => request<AlbumInfo>('/albums', { method: 'POST', body: JSON.stringify({ name }) });
export const addAlbumItems = (id: string, entryIds: string[]) =>
  request<{ ok: boolean; inAlbum: number }>(`/albums/${id}/items`, { method: 'POST', body: JSON.stringify({ entryIds }) });
export const deleteAlbum = (id: string) => request<{ ok: boolean }>(`/albums/${id}`, { method: 'DELETE' });
export const removeAlbumItem = (id: string, entryId: string) =>
  request<{ ok: boolean }>(`/albums/${id}/items/${entryId}`, { method: 'DELETE' });

// ===== разархивирование архивов (фоновая задача в сервисе) =====
export interface UnzipJob {
  id: string;
  entryId: string;
  state: 'pending' | 'processing' | 'done' | 'failed' | 'cancelled';
  totalEntries: number;
  doneEntries: number;
  totalBytes: number;
  doneBytes: number;
  skippedEntries: number;
  currentName: string | null;
  error: string | null;
  targetFolderId: string | null;
  percent: number;
  createdAt: string;
  startedAt: string | null;
  finishedAt: string | null;
}
export const startUnzip = (entryId: string) =>
  request<UnzipJob>('/unzip', { method: 'POST', body: JSON.stringify({ entryId }) });
export const unzipStatus = (id: string) => request<UnzipJob>(`/unzip/${id}`);
export const latestUnzip = (entryId: string) =>
  request<UnzipJob | null>(`/unzip?entryId=${encodeURIComponent(entryId)}`);
export const cancelUnzip = (id: string) => request<UnzipJob>(`/unzip/${id}/cancel`, { method: 'POST' });
