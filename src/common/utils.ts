import { createHash, randomBytes } from 'crypto';

export function sha256Hex(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}

export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

export function asString(v: unknown, field: string): string {
  if (typeof v !== 'string' || v.length === 0) throw new Error(`field ${field} must be non-empty string`);
  return v;
}

export function asOptionalString(v: unknown, field: string): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw new Error(`field ${field} must be a string`);
  return v;
}

/** Валидация имён папок/файлов: запрет разделителей пути и управляющих символов. */
export function assertSafeName(name: string): void {
  if (!name || name.length > 255) throw new Error('invalid name length');
  if (name.includes('/') || name.includes('\\') || name.includes('\0')) {
    throw new Error('name contains path separators');
  }
  if (name === '.' || name === '..') throw new Error('invalid name');
}
