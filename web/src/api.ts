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
export interface UserInfo { id: string; login: string; rootFolderId: string | null }
export interface FolderEntry { id: string; name: string; createdAt?: string; size?: number; mime?: string }
export interface FolderView { parentId: string; folders: FolderEntry[]; entries: FolderEntry[] }
export interface ShareInfo {
  token: string; url: string; kind: string; capability: string; targetId: string;
  hasPassword: boolean; expiresAt: string | null; createdAt: string;
}
export interface TrashItem { id: string; name: string; deletedAt: string; kind: 'folder' | 'file'; size?: number }
export interface TrashView { folders: TrashItem[]; entries: TrashItem[] }

// ===== auth =====
export const login = (login: string, password: string) =>
  request<{ user: UserInfo }>('/auth/login', { method: 'POST', body: JSON.stringify({ login, password }) });
export const me = () => request<{ id: string; login: string; rootFolderId: string | null }>('/auth/me');
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
export const fileUrl = (id: string) => `${BASE}/files/${id}/content`;

export async function uploadFile(file: File, folderId: string | undefined, onProgress?: (pct: number) => void) {
  const CHUNK = 5 * 1024 * 1024;
  const init = await request<{ uploadId: string; chunkMaxBytes: number }>('/uploads', {
    method: 'POST',
    body: JSON.stringify({ folderId, name: file.name, size: file.size, mime: file.type || 'application/octet-stream' }),
  });
  const parts = Math.max(1, Math.ceil(file.size / CHUNK));
  for (let i = 0; i < parts; i++) {
    const start = i * CHUNK;
    const buf = await file.slice(start, Math.min(file.size, start + CHUNK)).arrayBuffer();
    const res = await fetch(`${BASE}/uploads/${init.uploadId}/chunks/${i + 1}`, {
      method: 'PUT',
      credentials: 'include',
      headers: { 'Content-Type': 'application/octet-stream' },
      body: buf,
    });
    if (!res.ok) throw new Error(`chunk ${i + 1} failed: HTTP ${res.status}`);
    onProgress?.(Math.round(((i + 1) / parts) * 100));
  }
  return request<{ entry: { id: string }; deduped: boolean }>(`/uploads/${init.uploadId}/complete`, { method: 'POST' });
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
