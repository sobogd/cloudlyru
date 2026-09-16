import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'crypto';
import { env } from '../config/env';

/**
 * Шифрование паролей почтовых аккаунтов.
 *
 * App-пароль — это ключ ко всей переписке, а лежит он в БД рядом с самими письмами:
 * дамп БД, реплика, случайный `select *` в логе — и он утёк. Поэтому в открытом виде
 * пароль не хранится нигде, кроме памяти процесса на время подключения к IMAP.
 *
 * Схема: AES-256-GCM с случайным IV на каждое шифрование, ключ — из MAIL_SECRET_KEY.
 * Формат строки: `v1:<iv>:<tag>:<ciphertext>`, всё в base64url. Версия в префиксе нужна,
 * чтобы смена схемы (или ключа) не превратилась в «нечитаемые строки без объяснений»:
 * старый формат можно распознать и мигрировать.
 */

const VERSION = 'v1';
const IV_BYTES = 12; // рекомендованный размер для GCM
const KEY_BYTES = 32;

/** Ключ из конфига: 64 hex-символа берём как есть, иначе выводим sha256 из строки. */
function key(): Buffer {
  const raw = env.MAIL_SECRET_KEY ?? '';
  if (!raw) {
    // Понятная ошибка вместо «Invalid key length» из недр crypto: такую строку видно в логе
    // статуса аккаунта, и она сразу говорит, что делать.
    throw new Error('MAIL_SECRET_KEY не задан — пароли почтовых аккаунтов не зашифровать');
  }
  if (/^[0-9a-fA-F]{64}$/.test(raw)) return Buffer.from(raw, 'hex');
  return createHash('sha256').update(raw, 'utf8').digest();
}

/** Готов ли сервер работать с почтовыми аккаунтами (есть ключ нужной длины). */
export function mailCryptoReady(): boolean {
  try {
    return key().length === KEY_BYTES;
  } catch {
    return false;
  }
}

/**
 * Зашифровать секрет аккаунта — так получается `MailAccount.secretEnc`.
 *
 * Это единственный правильный способ получить строку для этого поля: писателя у него в
 * репозитории нет (аккаунт заводит оператор, вручную вставляя строку в БД), поэтому здесь
 * важно сказать вслух: `secretEnc` — не «пароль», а результат этой функции. Вставленный
 * руками открытый пароль не сломается сразу — он сломается на расшифровке («неизвестный
 * формат секрета»), и разбираться придётся по логу синхронизации.
 */
export function encryptSecret(plain: string): string {
  if (!plain) throw new Error('пустой секрет шифровать нечего');
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv('aes-256-gcm', key(), iv);
  const data = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [VERSION, iv.toString('base64url'), tag.toString('base64url'), data.toString('base64url')].join(':');
}

/**
 * Расшифровать секрет аккаунта. Подмена любого байта строки ломает GCM-тег и даёт ошибку —
 * то есть подсунуть в БД «свой» пароль, не зная ключа, нельзя.
 */
export function decryptSecret(stored: string): string {
  const parts = String(stored ?? '').split(':');
  if (parts.length !== 4 || parts[0] !== VERSION) {
    throw new Error(`неизвестный формат секрета (ожидался ${VERSION}:iv:tag:data)`);
  }
  const [, ivB64, tagB64, dataB64] = parts;
  const decipher = createDecipheriv('aes-256-gcm', key(), Buffer.from(ivB64, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(dataB64, 'base64url')), decipher.final()]).toString('utf8');
}

/**
 * Сравнение строк за постоянное время. Нужно там, где сравниваются секреты (проверка
 * «пароль не менялся»), чтобы по времени ответа нельзя было подбирать посимвольно.
 */
export function secretEquals(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  if (ba.length !== bb.length) return false;
  return timingSafeEqual(ba, bb);
}
