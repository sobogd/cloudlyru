import { createHash, randomBytes } from 'crypto';
import { badRequest } from './errors';

export function sha256Hex(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}

export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// Мусор в теле запроса — это 400, а не 500: обычный Error превращался в «Internal server error»,
// и клиент (в том числе мобильный) считал сервер сломанным вместо «я отправил не то»
export function asString(v: unknown, field: string): string {
  if (typeof v !== 'string' || v.length === 0) throw badRequest(`field ${field} must be non-empty string`);
  return v;
}

export function asOptionalString(v: unknown, field: string): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw badRequest(`field ${field} must be a string`);
  return v;
}

/** Валидация имён папок/файлов: запрет разделителей пути и управляющих символов. */
export function assertSafeName(name: string): void {
  // именно badRequest: обычный Error превращался в 500, и клиент считал сервер сломанным
  if (!name || name.length > 255) throw badRequest('invalid name length');
  if (name.includes('/') || name.includes('\\') || name.includes('\0')) {
    throw badRequest('name contains path separators');
  }
  if (name === '.' || name === '..') throw badRequest('invalid name');
}

/**
 * Дата из ISO-строки для клиентов синхронизации (mtime файла на устройстве).
 * null и '' — «снять значение», undefined — поле не передано или мусор (менять не надо).
 */
export function parseOptionalDate(v: unknown): Date | null | undefined {
  if (v === null || v === '') return null;
  if (typeof v !== 'string') return undefined;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? undefined : d;
}
