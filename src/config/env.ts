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
  // Потолок размера файла, для которого вообще ставится задача конвертации. Задача качает
  // объект из S3 целиком во временный каталог, поэтому один огромный файл (или много
  // заявленных «картинками» мелочей) выедает диск и очередь. Крупнее — файл остаётся как
  // есть, без превью: скачать оригинал по-прежнему можно.
  CONVERT_MAX_MB: z.coerce.number().positive().default(10240),
  // Сколько фото-задач считать одновременно. Фото упираются в ядра (AVIF-энкод, heif-convert),
  // видео и PDF всегда идут по одному. На 2 ядрах смысл есть в 2, на 4 — в 3-4.
  // Пустая строка = «не задано»: dotenv не перезаписывает переменные, уже пришедшие в
  // окружение процесса, поэтому пустое значение из деплоя иначе валило старт приложения.
  CONVERT_PHOTO_PARALLEL: z.preprocess(
    (v) => (v === '' || v === undefined || v === null ? 1 : v),
    z.coerce.number().int().min(1).max(8),
  ),
  // Пускать видео параллельно фото. По умолчанию нет: AV1 занимает все ядра, и фото рядом
  // с ним идут в разы медленнее. Имеет смысл на машине с большим числом ядер.
  CONVERT_VIDEO_ALONGSIDE_PHOTOS: z.string().default('false'),
  // Хранить оригинал в S3 после успешной конвертации (по умолчанию — да).
  // Оригинал нужен, чтобы пересобрать мастер с лучшими параметрами/метаданными:
  // сами метаданные (ICC, gain map, MPF, MakerNotes) после конвертации невосстановимы.
  KEEP_ORIGINALS: booleanish.default('true'),

  // ===== Почта =====
  // Ключ шифрования паролей почтовых аккаунтов (AES-256-GCM). Годится и hex на 64 символа
  // (openssl rand -hex 32), и любая строка-парольная фраза — тогда ключ выводится sha256.
  // Сами app-пароли в окружении не живут: их вводят в веб-интерфейсе, и они ложатся в БД
  // зашифрованными этим ключом.
  MAIL_SECRET_KEY: z.string().default(''),
  MAIL_SYNC_ENABLED: booleanish.default('false'),
  // Плановый проход по папкам, секунды: мгновенный приход даёт IDLE, а это — страховка
  // на случай разорванного соединения и потерянных событий.
  MAIL_SYNC_INTERVAL_SEC: z.coerce.number().int().positive().default(300),
  // Нижняя граница истории, дни: старше не забираем вовсе. 0 — без ограничения (история
  // идёт назад, пока она есть). Интерфейс живой сразу в любом случае: письма приходят
  // от свежих к старым, поэтому первые экраны заполняются на первом же проходе.
  MAIL_BACKFILL_DAYS: z.coerce.number().int().nonnegative().default(0),
  // Сколько писем истории добирать за один проход. У Gmail лимит на скачивание по IMAP
  // (порядка 2.5 ГБ в сутки на аккаунт), поэтому история идёт порциями, а не залпом.
  MAIL_BACKFILL_PER_PASS: z.coerce.number().int().positive().default(200),
  // Потолок трафика одного прохода, МБ: предохранитель от «одна папка на 40 ГБ».
  MAIL_PASS_BUDGET_MB: z.coerce.number().positive().default(300),
  // Удаление писем с сервера после того, как они сохранены у нас. Безвозвратно — включать
  // только после проверенного восстановления из бэкапа.
  MAIL_PURGE_ENABLED: booleanish.default('false'),
  // Карантин между «сохранено у нас» и «удалено с сервера», часы (7 суток по умолчанию).
  MAIL_PURGE_QUARANTINE_HOURS: z.coerce.number().int().positive().default(168),
  // Сколько писем удалять за один прогон: порциями безопаснее — видно результат и можно
  // остановиться, не разбирая последствия на всём ящике сразу.
  MAIL_PURGE_PER_RUN: z.coerce.number().int().positive().default(200),
  // Предохранитель: если под удаление попадает больше этой доли ящика (в процентах) и писем
  // больше сотни, прогон отказывается работать. Защита от ошибки в отборе, а не от человека.
  MAIL_PURGE_MAX_SHARE: z.coerce.number().positive().max(100).default(50),
  // Адреса, письма от которых не удаляем никогда: коды входа, оповещения о безопасности,
  // восстановление доступа. Потерять их — значит потерять доступ к самому аккаунту.
  MAIL_PURGE_PROTECT_SENDERS: z
    .string()
    .default('accounts.google.com,google.com,apple.com,id.apple.com,icloud.com'),
  // Сколько последних писем в папке-мусорке просматривать за прогон при добивании удалённого.
  MAIL_PURGE_TRASH_SCAN: z.coerce.number().int().positive().default(2000),
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
    // Синхронизация без ключа означала бы пароли аккаунтов в открытом виде в БД, поэтому
    // это отказ старта, а не предупреждение. При выключенной синхронизации ключ не нужен.
    if (e.MAIL_SYNC_ENABLED && !e.MAIL_SECRET_KEY) missing.push('MAIL_SECRET_KEY');
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
export const CONVERT_MAX_BYTES = Math.floor(env.CONVERT_MAX_MB * 1024 * 1024);
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
