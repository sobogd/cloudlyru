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
    const err = new Error(msg) as Error & { status?: number };
    err.status = res.status;
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
  size: number; mime: string; ext?: string; sha256: string; masterMime?: string | null;
  media?: FileMedia | null;
}
export const fileMeta = (id: string) => request<FileMeta>(`/files/${id}`);
export interface FolderMeta {
  id: string; name: string; zone: string; path: string;
  folders: number; entries: number; createdAt: string; updatedAt: string;
}
export const folderMeta = (id: string) => request<FolderMeta>(`/folders/${id}/meta`);

const CHUNK_BYTES = 5 * 1024 * 1024;

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
  onProgress?: (pct: number) => void,
  signal?: AbortSignal,
): Promise<{ entry: { id: string }; deduped: boolean }> {
  const mime = guessMime(file);
  const init = await request<{ uploadId: string; chunkMaxBytes: number }>('/uploads', {
    method: 'POST',
    body: JSON.stringify({ folderId, name: file.name, size: file.size, mime }),
  });
  const uploadId = init.uploadId;
  const parts = Math.max(1, Math.ceil(file.size / CHUNK_BYTES));
  try {
    for (let part = 1; part <= parts; part++) {
      const start = (part - 1) * CHUNK_BYTES;
      const end = Math.min(file.size, start + CHUNK_BYTES);
      const buf = await file.slice(start, end).arrayBuffer();
      await putChunk(uploadId, part, buf, signal);
      onProgress?.(Math.round((part / parts) * 100));
    }
    return await request<{ entry: { id: string }; deduped: boolean }>(`/uploads/${uploadId}/complete`, { method: 'POST' });
  } catch (e) {
    // подчистить незавершённую сессию на сервере (multipart abort), если она осталась
    try { await fetch(`${BASE}/uploads/${uploadId}`, { method: 'DELETE', credentials: 'include' }); } catch { /* ignore */ }
    throw e;
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

// ===== M2: timeline / trips / albums =====
export interface TimelineItem { entryId: string; name: string; capturedAt: string | null; latitude?: number; longitude?: number; mime: string; sha256?: string; masterMime?: string | null; masterReady: boolean; jobState?: string | null; jobProgress?: number; jobError?: string | null; size: number }
export interface TripPoint { capturedAt: string; latitude: number; longitude: number; entryId: string }
export interface Trip { id: string; start: string; end: string; title: string; count: number; points: TripPoint[] }
export interface AlbumInfo { id: string; name: string; createdAt: string; count: number }
export interface AlbumView extends AlbumInfo { items: Array<{ entryId: string; name: string; size: number; mime: string; capturedAt: string | null }> }

export const previewUrl = (sha: string, w = 512) => `/api/v1/previews/${sha}?w=${w}`;
export const videoPreviewUrl = (sha: string) => `/api/v1/video-preview/${sha}`;
export interface QueueStatus {
  byState: Record<string, number>;
  processing: { id: string; kind: string; sha256: string; startedMinAgo: number; progress: number } | null;
  recent: Array<{ id: string; kind: string; state: string; error: string | null; updatedAt: string; sha256: string; progress: number; masterReady: boolean }>;
}
export const queueStatus = () => request<QueueStatus>('/queue/status');
export const timeline = () => request<TimelineItem[]>('/timeline');
export const trips = () => request<Trip[]>('/trips');
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
