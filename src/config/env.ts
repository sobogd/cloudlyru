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
  COOKIE_NAME: z.string().default('cl_session'),

  ADMIN_LOGIN: z.string().default('admin'),
  ADMIN_PASSWORD: z.string().min(1).default('admin'),

  S3_FILES_ACCESS_KEY: z.string().default(''),
  S3_FILES_SECRET_KEY: z.string().default(''),
  S3_FILES_ENDPOINT: z.string().url().default('https://nbg1.your-objectstorage.com'),
  S3_FILES_REGION: z.string().default('nbg1'),
  S3_FILES_BUCKET: z.string().default('cloudlyru'),
  S3_FILES_FORCE_PATH_STYLE: booleanish.default('true'),

  UPLOAD_CHUNK_MAX_MB: z.coerce.number().positive().default(20),
  MAX_FILE_SIZE_MB: z.coerce.number().positive().default(51200),
  TRASH_RETENTION_DAYS: z.coerce.number().int().positive().default(30),

  CONVERT_ENABLED: z.string().default('false'),
  CONVERT_MEM_MB: z.coerce.number().int().positive().default(1536),
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
export const MAX_FILE_BYTES = Math.floor(env.MAX_FILE_SIZE_MB * 1024 * 1024);
export const TRASH_RETENTION_MS = env.TRASH_RETENTION_DAYS * 24 * 60 * 60 * 1000;
