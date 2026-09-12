import { z } from 'zod';

const booleanish = z
  .string()
  .optional()
  .transform((v) => v === undefined || v === '' || v === 'true' || v === '1');

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(8305),
  BASE_URL: z.string().url().default('http://127.0.0.1:8305'),
  DATABASE_URL: z.string().min(1),
  SESSION_SECRET: z.string().min(16).default('dev-only-secret-change-me'),
  SESSION_TTL_DAYS: z.coerce.number().int().positive().default(30),
  // Срок жизни app-токена (WebDAV/клиенты), дней. Раньше токены были бессрочными.
  API_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(180),
  COOKIE_NAME: z.string().default('cl_session'),

  ADMIN_LOGIN: z.string().default('admin'),
  ADMIN_PASSWORD: z.string().min(1).default('admin'),

  S3_FILES_ACCESS_KEY: z.string().default(''),
  S3_FILES_SECRET_KEY: z.string().default(''),
  S3_FILES_ENDPOINT: z.string().url().default('https://nbg1.your-objectstorage.com'),
  S3_FILES_REGION: z.string().default('nbg1'),
  S3_FILES_BUCKET: z.string().default('cloudlyru'),
  // Префикс всех ключей приложения в бакете. Прод живёт без префикса (пусто),
  // а локальный/тестовый инстанс задаёт свой — иначе он пишет в прод-бакет, а его
  // строки живут в отдельной БД: при её пересоздании объекты остаются «зомби»,
  // которые приложению уже не видны (чистятся deploy/scripts/sweep-orphans.mjs).
  S3_FILES_PREFIX: z.string().default(''),
  S3_FILES_FORCE_PATH_STYLE: booleanish.default('true'),

  UPLOAD_CHUNK_MAX_MB: z.coerce.number().positive().default(20),
  // Размер части при прямой загрузке в S3 (браузер → S3 мимо сервера). Части идут
  // параллельно, поэтому крупная часть = меньше round-trip'ов на высоком пинге.
  UPLOAD_DIRECT_PART_MB: z.coerce.number().positive().default(16),
  // Срок жизни presigned-ссылки на часть, минуты.
  UPLOAD_PART_URL_TTL_MIN: z.coerce.number().positive().default(15),
  MAX_FILE_SIZE_MB: z.coerce.number().positive().default(51200),
  // Потолок одновременных незавершённых загрузок на пользователя (мобильный клиент с
  // ретраями иначе наплодит висящих multipart'ов в S3).
  MAX_UPLOAD_SESSIONS_PER_USER: z.coerce.number().int().positive().default(16),
  TRASH_RETENTION_DAYS: z.coerce.number().int().positive().default(30),

  CONVERT_ENABLED: z.string().default('false'),
  CONVERT_MEM_MB: z.coerce.number().int().positive().default(1536),
  // Сколько фото-задач считать одновременно. Фото упираются в ядра (AVIF-энкод, heif-convert),
  // видео и PDF всегда идут по одному. На 2 ядрах смысл есть в 2, на 4 — в 3-4.
  CONVERT_PHOTO_PARALLEL: z.coerce.number().int().min(1).max(8).default(1),
  // Хранить оригинал в S3 после успешной конвертации (по умолчанию — да).
  // Оригинал нужен, чтобы пересобрать мастер с лучшими параметрами/метаданными:
  // сами метаданные (ICC, gain map, MPF, MakerNotes) после конвертации невосстановимы.
  KEEP_ORIGINALS: booleanish.default('true'),
});

export type Env = z.infer<typeof envSchema>;

function load(): Env {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    // eslint-disable-next-line no-console
    console.error('[env] invalid configuration:', parsed.error.flatten().fieldErrors);
    throw new Error('Invalid environment configuration');
  }
  const e = parsed.data;
  if (e.NODE_ENV === 'production') {
    const missing: string[] = [];
    if (!e.S3_FILES_ACCESS_KEY) missing.push('S3_FILES_ACCESS_KEY');
    if (!e.S3_FILES_SECRET_KEY) missing.push('S3_FILES_SECRET_KEY');
    if (missing.length) {
      throw new Error(`[env] production требует: ${missing.join(', ')}`);
    }
  }
  return e;
}

export const env: Env = load();

export const CHUNK_MAX_BYTES = Math.floor(env.UPLOAD_CHUNK_MAX_MB * 1024 * 1024);
export const DIRECT_PART_BYTES = Math.floor(env.UPLOAD_DIRECT_PART_MB * 1024 * 1024);
export const PART_URL_TTL_SEC = Math.floor(env.UPLOAD_PART_URL_TTL_MIN * 60);
export const MAX_FILE_BYTES = Math.floor(env.MAX_FILE_SIZE_MB * 1024 * 1024);
export const MAX_UPLOAD_SESSIONS_PER_USER = env.MAX_UPLOAD_SESSIONS_PER_USER;
export const TRASH_RETENTION_MS = env.TRASH_RETENTION_DAYS * 24 * 60 * 60 * 1000;

/**
 * Хост объектного хранилища. Отдаём клиенту при старте загрузки: телефон должен уметь
 * показать, что именно не разрешается в DNS, ещё до первой попытки залить байты.
 */
export const STORAGE_HOST = (() => {
  try {
    return new URL(env.S3_FILES_ENDPOINT).host;
  } catch {
    return '';
  }
})();
