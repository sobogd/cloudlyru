import { z } from 'zod';

const booleanish = z
  .string()
  .optional()
  .transform((v) => v === undefined || v === '' || v === 'true' || v === '1');

/**
 * «Выключатель», который остаётся СТРОКОЙ 'true'/'false'. Так сделано потому, что потребители
 * сравнивают его именно со строкой (`src/queue/queue.service.ts`): boolean здесь молча выключил
 * бы конвертацию навсегда, потому что `false !== 'true'`. Значение '1' понимаем наравне с 'true'
 * — как это делают booleanish-настройки (MAIL_SYNC_ENABLED, KEEP_ORIGINALS); раньше '1' молча
 * означал «выключено». Пустая строка остаётся «выключено» (в отличие от booleanish, где пусто =
 * «не задано»): инвертировать смысл пустого значения на проде никто не просил, а включить
 * конвертацию там, где бинарей может не быть, — худший сюрприз.
 */
const boolString = (def: 'true' | 'false') =>
  z
    .string()
    .optional()
    .transform((v) => (v === 'true' || v === '1' ? 'true' : 'false'))
    .default(def);

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(8305),
  BASE_URL: z.string().url().default('http://127.0.0.1:8305'),
  DATABASE_URL: z.string().min(1),
  // Отдельного секрета для сессий здесь нет намеренно: сессия — это 32 случайных байта, а в БД
  // лежит их sha256 (auth.service), подписывать нечего. Переменная SESSION_SECRET стояла тут,
  // в .env.example и в деплое, но код не читал её ни разу — деплой при этом выглядел так, будто
  // сессии защищены ключом. Если однажды понадобится подписанная cookie, секрет заводится
  // вместе с кодом, который его читает, а не заранее.
  SESSION_TTL_DAYS: z.coerce.number().int().positive().default(30),
  // Срок жизни app-токена (WebDAV/клиенты), дней. Раньше токены были бессрочными.
  API_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(180),
  COOKIE_NAME: z.string().default('cl_session'),

  // Своя ручка уровня логирования: по умолчанию в проде нужны только события и ошибки, а
  // 'debug'/'verbose' (в том числе полный лог запросов) включаются на время разбора.
  LOG_LEVEL: z.enum(['error', 'warn', 'log', 'debug', 'verbose']).default('log'),

  // Дефолты 'admin'/'admin' — только для локального запуска и тестов: в проде они запрещены
  // проверкой в load() ниже, потому что на пустой БД первый владелец создаётся именно этим
  // паролем (AuthService.onModuleInit).
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
  // Размер части при прямой загрузке в S3 (клиент → S3 мимо сервера). Клиент шлёт части
  // последовательно, поэтому крупная часть = меньше round-trip'ов на высоком пинге, но больше
  // памяти на клиенте и дольше повтор одной части. Значение уходит клиенту в `chunkMaxBytes`
  // при `init`, поэтому сервер и клиент всегда считают части одинаково.
  UPLOAD_DIRECT_PART_MB: z.coerce.number().positive().default(16),
  // Срок жизни presigned-ссылки на часть, минуты.
  UPLOAD_PART_URL_TTL_MIN: z.coerce.number().positive().default(15),
  MAX_FILE_SIZE_MB: z.coerce.number().positive().default(51200),
  // Потолок одновременных незавершённых загрузок на пользователя (мобильный клиент с
  // ретраями иначе наплодит висящих multipart'ов в S3).
  MAX_UPLOAD_SESSIONS_PER_USER: z.coerce.number().int().positive().default(16),
  TRASH_RETENTION_DAYS: z.coerce.number().int().positive().default(30),

  CONVERT_ENABLED: boolString('false'),
  // Лимит виртуальной памяти (RLIMIT_AS) на один внешний процесс задачи. Это именно адресное
  // пространство, а не RSS: libaom резервирует арены на потоки, и на 1536 МБ процесс упирался
  // в потолок при реальных ~0.5 ГБ (VmPeak = 99.6% лимита) — то есть лимит давил не на память,
  // а на параллелизм энкодера. 3072 — с запасом для любого энкодера (H.264 в разы скромнее),
  // и с оглядкой на соседей по машине: на 4 vCPU/8 ГБ рядом живут Postgres и другие сервисы.
  CONVERT_MEM_MB: z.coerce.number().int().positive().default(3072),
  // Кодек полноэкранного превью видео. h264 — libx264 veryfast: на 4 ядрах он упирается
  // в декодер исходника (замер на проде: 8.7 с на 5 с 4K50-ролика против ~200 с у libaom
  // в good-режиме) и играется везде, включая Safari и iOS без AV1. av1 — libaom в
  // realtime-режиме: файл меньше, энкод в разы дороже. Пустая строка = не задано.
  CONVERT_VIDEO_CODEC: z.preprocess(
    (v) => (v === '' || v === undefined || v === null ? 'h264' : v),
    z.enum(['h264', 'av1']),
  ),
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
  CONVERT_VIDEO_ALONGSIDE_PHOTOS: boolString('false'),
  // Хранить оригинал в S3 после успешной конвертации (по умолчанию — да).
  // Оригинал нужен, чтобы пересобрать мастер с лучшими параметрами/метаданными:
  // сами метаданные (ICC, gain map, MPF, MakerNotes) после конвертации невосстановимы.
  KEEP_ORIGINALS: booleanish.default('true'),

  // ===== Почта =====
  // Ключ шифрования паролей почтовых аккаунтов (AES-256-GCM). Годится и hex на 64 символа
  // (openssl rand -hex 32), и любая строка-парольная фраза — тогда ключ выводится sha256.
  // Сами app-пароли в окружении не живут: они ложатся в БД зашифрованными этим ключом.
  MAIL_SECRET_KEY: z.string().default(''),
  // Токен ручки приёма почты от своего SMTP-сервера. Ручка без сессии (её дёргает Postfix),
  // поэтому единственная защита — этот токен плюс запрет пути в nginx. Пусто — приём закрыт.
  MAIL_INBOUND_TOKEN: z.string().default(''),
  MAIL_SYNC_ENABLED: booleanish.default('false'),
  // Плановый проход по папкам, секунды: мгновенный приход даёт IDLE, а это — страховка
  // на случай разорванного соединения и потерянных событий.
  MAIL_SYNC_INTERVAL_SEC: z.coerce.number().int().positive().default(120),
  // Нижняя граница истории, дни: старше не забираем вовсе. 0 — без ограничения (история
  // идёт назад, пока она есть). Интерфейс живой сразу в любом случае: письма приходят
  // от свежих к старым, поэтому первые экраны заполняются на первом же проходе.
  MAIL_BACKFILL_DAYS: z.coerce.number().int().nonnegative().default(0),
  // Сколько писем истории добирать за один проход. У Gmail лимит на скачивание по IMAP
  // (порядка 2.5 ГБ в сутки на аккаунт), поэтому история идёт порциями, а не залпом.
  MAIL_BACKFILL_PER_PASS: z.coerce.number().int().positive().default(200),
  // Потолок трафика на ОДНУ папку, МБ. Счётчик заводится внутри обхода папки, а не перед
  // обходом всех, поэтому фактический потолок прохода — это значение, умноженное на число
  // папок и аккаунтов; для Gmail с его суточным лимитом на скачивание это важно помнить.
  // Потолок «на проход/аккаунт» требует счётчика в src/mail — там же, где заводится budget.
  MAIL_PASS_BUDGET_MB: z.coerce.number().positive().default(300),
  // Поисковый индекс для старых писем: полного тела в БД нет, поэтому архив разбирается
  // заново из .eml в S3 — порциями и фоном, пока не закончится (src/mail/mail-index.service.ts).
  // Выключать есть смысл только на время отладки: без индекса поиск не находит старые письма.
  MAIL_SEARCH_INDEX_ENABLED: booleanish.default('true'),
  MAIL_SEARCH_INDEX_BATCH: z.coerce.number().int().positive().default(100),
  MAIL_SEARCH_INDEX_INTERVAL_SEC: z.coerce.number().int().positive().default(60),

  // Лимит по умолчанию для ручек, которые не помечены @RateLimit, запросов в минуту на IP.
  // Гард частоты глобальный именно из-за отсутствия такого потолка у целых разделов
  // (файлы, WebDAV, /apk). Значение заведомо выше рабочих лимитов существующих ручек
  // (самый щедрый из явных — 3000/мин у превью), а 0 полностью выключает дефолт и
  // оставляет только явные @RateLimit: это аварийный выход, если лимит кому-то помешает.
  RATE_LIMIT_DEFAULT_PER_MIN: z.coerce.number().int().nonnegative().default(1200),

  // ===== Фактуры (раздел перенесён из отдельного сервиса iq-factura) =====
  // Компания-эмитент. В прежнем сервисе она выбиралась из связки пользователь↔компания
  // (`users_companies`) и могла переключаться заголовком x-company-id; здесь владелец один
  // и компания одна, поэтому её id зафиксирован в конфиге. Пусто — фактурные ручки не смогут
  // определить компанию, остальное облако работает как обычно.
  FACTURA_COMPANY_ID: z.string().default(''),
  // Бакет с PDF инвойсов и сканами расходов/деклараций. Креды и endpoint берутся общие
  // (S3_FILES_*): проверено, что те же ключи Hetzner открывают этот бакет, а объекты в нём
  // адресованы по companyId — поэтому перенос данных ключи не меняет.
  S3_INVOICES_BUCKET: z.string().default('iq-factura-invoices'),
  // Ключ Gemini: разбор сканов расходов и поданных деклараций, разбор вставленного текста
  // в контрагента. Пусто — разбор отключается (ручки отвечают без заполненных полей),
  // остальная работа с фактурами от него не зависит.
  GEMINI_API_KEY: z.string().default(''),
  // ===== Раздел «Чат»: локальная модель на маке =====
  //
  // Модель работает не на сервере, а на домашнем маке (LM Studio), и приходит сюда через
  // reverse-SSH туннель мака: на VPS открыт только loopback-порт 18812. Поэтому запросы всё
  // равно делает сервер, а не приложение: история чатов живёт в БД, причины отказов видны в
  // логах pm2, и в сборку приложения ничего не вшивается.
  //
  // Адрес — не секрет и не настройка вкуса: это тот же порт, что в agents/run-dsh-tunnel.sh
  // на маке. Менять его нужно вместе с туннелем, иначе раздел отвечает «локальная модель
  // недоступна».
  LLM_BASE_URL: z.string().url().default('http://127.0.0.1:18812'),
  // Ключ к LM Studio: нужен только если в самом LM Studio включено требование ключа. Обычно пусто.
  LLM_API_KEY: z.string().default(''),
  // Модель по умолчанию для новых чатов. Идентификатор — тот, что отдаёт LM Studio
  // (`GET /api/v0/models`), а не название файла на диске: смена кванта или каталога модели
  // меняет его, поэтому значение живёт в окружении, а не в коде.
  LLM_MODEL: z.string().default('qwen/qwen3.5-9b'),
  // `reasoning_effort` для запроса: none | low | medium | high. Пусто — параметр не отправляется.
  //
  // Значение `none` не украшение: без него модель тратит на «размышления» почти весь ответ, а
  // человек всё это время ждёт первого видимого слова. Замеры на маке: у gemma-4-e4b впустую
  // уходило около 90% токенов (443 из 502), у qwen3.5-9b без этого параметра в «размышления»
  // ушли все 300 выданных токенов и текстового ответа не было вовсе, а с `none` — 28 токенов,
  // 1.8 с и верный ответ по-русски.
  //
  // Параметр не из стандарта OpenAI, его понимает LM Studio. Другие способы выключить
  // размышления: у llama.cpp это флаг сервера `--chat-template-kwargs '{"enable_thinking":false}'`,
  // у vLLM/SGLang — поле `chat_template_kwargs` в запросе. Проверено, что LM Studio это поле
  // игнорирует (модель всё равно ушла в размышления), поэтому при смене сервера на маке
  // выключение размышлений придётся перенастроить, а не просто очистить переменную.
  LLM_REASONING: z.string().default('none'),
  // Поиск и чтение страниц для нового раздела «Чат»: сервис на маке (agents/websearch/), тоже
  // через туннель. Отличие от `SEARCH_URL` не в адресе, а в том, что этот сервис умеет читать
  // страницу целиком (`GET /page`), а не только отдавать выдержки выдачи. Пусто — раздел
  // работает, но отвечает без свежих данных.
  WEBSEARCH_URL: z.string().url().default('http://127.0.0.1:18814'),
  // Поиск в интернете: сервис на маке (agents/search-server.py), тоже через туннель.
  // Пусто — поиск выключен, модель отвечает без свежих данных.
  //
  // Это настройка ПРЕЖНЕГО раздела (src/ai) и вместе с ним удаляется: новый раздел ходит в
  // `WEBSEARCH_URL`. Обе переменные по умолчанию смотрят на один и тот же порт, поэтому во
  // время переезда им не нужно разных туннелей.
  SEARCH_URL: z.string().url().default('http://127.0.0.1:18814'),
  // Агент на телефоне: сервис на маке (agents/android-agent/server.py), тоже через туннель.
  // Живёт на маке не по выбору, а по необходимости: телефон, которым он управляет по ADB,
  // подключён к маку, так что запустить агента больше негде.
  // Пусто — режим агента в чате выключен: кнопка в интерфейсе есть, но запрос никуда не уходит.
  AGENT_URL: z.string().url().default('http://127.0.0.1:18816'),
  // VeriFactu: disabled — ничего не делаем; local — пишем записи с хеш-цепочкой и QR, но в AEAT
  // не отправляем; submit — ещё и отправляем. В разработке и на копии прод-данных обязан быть
  // local или disabled: с submit тестовые инвойсы уходят в прод AEAT по реальному NIF компании.
  VERIFACTU_MODE: z.enum(['disabled', 'local', 'submit']).default('disabled'),
  VERIFACTU_ENV: z.enum(['sandbox', 'production']).default('sandbox'),
  // 32-байтный ключ (base64) шифрования сертификатов компаний (AES-256-GCM). Тот же, что был
  // в iq-factura: иначе уже загруженный сертификат не расшифруется и отправка в AEAT встанет.
  VERIFACTU_MASTER_KEY: z.string().default(''),
  // Номер установки в AEAT. Пусто — берётся id компании (историческое поведение сервиса):
  // менять его нельзя, иначе AEAT увидит новую установку.
  VERIFACTU_INSTALLATION_ID: z.string().default(''),
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
  // Политика проверок намеренно узкая: в проде обязательны ключи S3 (без них не работает всё
  // остальное: файлы, фото, вложения писем — сервис мёртв целиком) и учётные данные первого
  // владельца. DATABASE_URL дефолта не имеет: без неё приложение не поднимется нигде.
  if (e.NODE_ENV === 'production') {
    const missing: string[] = [];
    if (!e.S3_FILES_ACCESS_KEY) missing.push('S3_FILES_ACCESS_KEY');
    if (!e.S3_FILES_SECRET_KEY) missing.push('S3_FILES_SECRET_KEY');
    // ADMIN_LOGIN/ADMIN_PASSWORD обязательны именно в проде: на пустой БД первый владелец
    // создаётся из этих значений (AuthService.onModuleInit), а /auth/login — публичная ручка
    // с лимитом лишь 5 попыток в минуту на IP. Дефолтная пара admin/admin означала бы, что
    // сервис открыт любому, кто знает адрес, и смены пароля в приложении для этого нет.
    // Проверяем сам процесс (process.env), а не результат схемы: иначе не отличить «владелец
    // задал admin» от «ничего не задал и сработал дефолт».
    if (!process.env.ADMIN_LOGIN?.trim()) missing.push('ADMIN_LOGIN');
    if (!process.env.ADMIN_PASSWORD?.trim()) missing.push('ADMIN_PASSWORD');
    if (missing.length) {
      throw new Error(`[env] production требует: ${missing.join(', ')}`);
    }
    // Фатально только то, что небезопасно при любом раскладе: дефолт, плейсхолдер из шаблона
    // и пароль, равный логину (такой «секрет» виден из одного поля). Длину отдельно НЕ требуем:
    // владелец мог давно поставить короткий пароль, и отказ старта на нём означал бы, что
    // следующий деплой не поднимается вовсе. Вместо этого — заметное предупреждение в лог.
    const password = e.ADMIN_PASSWORD.trim();
    const looksPlaceholder = password.toLowerCase().startsWith('change_me');
    if (password.toLowerCase() === 'admin' || looksPlaceholder || password === e.ADMIN_LOGIN.trim()) {
      throw new Error(
        '[env] production: ADMIN_PASSWORD — дефолт, плейсхолдер или совпадает с ADMIN_LOGIN. ' +
          'Задайте пароль секретом репозитория ADMIN_PASSWORD и перезапустите сервис.',
      );
    }
    if (password.length < 12) {
      // eslint-disable-next-line no-console
      console.error(
        '[env] ВНИМАНИЕ: ADMIN_PASSWORD короче 12 символов. Вход ограничен 5 попытками в минуту ' +
          'на IP и пароль перебирается по словарю — смените его на длинный и случайный.',
      );
    }
    // Ключа почты в этом списке намеренно нет. Сначала здесь был отказ старта (пароли
    // аккаунтов негде хранить — значит, работать нельзя), но у этого решения цена выше
    // пользы: без ключа падал бы весь сервис, включая файлы и фото, из-за раздела, который
    // сам по себе необязательный. Поэтому деградируем: синхронизация не запустится
    // (MailSyncService это проверяет и пишет в лог), а добавить аккаунт сейчас можно только
    // вручную в БД — ручки создания аккаунта в API нет (см. src/mail: encryptSecret не
    // вызывается ниоткуда).
    if (e.MAIL_SYNC_ENABLED && !e.MAIL_SECRET_KEY) {
      // eslint-disable-next-line no-console
      console.error(
        '[env] MAIL_SYNC_ENABLED=true, но MAIL_SECRET_KEY не задан: синхронизация почты не запустится, ' +
          'аккаунты добавить нельзя. Задайте секрет репозитория MAIL_SECRET_KEY и перезапустите сервис.',
      );
    }
    // Фактуры проверяем только когда VeriFactu вообще включён. При `disabled` (умолчание)
    // раздел может существовать в коде, но не быть настроенным — отказ старта тогда уронил бы
    // всё облако ради ещё не перенесённых данных.
    if (e.VERIFACTU_MODE !== 'disabled') {
      const missingFactura: string[] = [];
      if (!e.FACTURA_COMPANY_ID) missingFactura.push('FACTURA_COMPANY_ID');
      if (!e.VERIFACTU_MASTER_KEY) missingFactura.push('VERIFACTU_MASTER_KEY');
      if (missingFactura.length) {
        // Без компании записи некуда привязать, без мастер-ключа не расшифруется сертификат —
        // в обоих случаях отправка в AEAT молча не работает, а это налоговое обязательство,
        // поэтому лучше не подняться, чем работать «вроде бы».
        throw new Error(
          `[env] VERIFACTU_MODE=${e.VERIFACTU_MODE} требует: ${missingFactura.join(', ')}`,
        );
      }
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
// Осознанный псевдоним той же настройки: код, который работает с байтами и потолками, берёт
// их из этого файла, а не через env.*, — значение одно, отдельной переменной окружения нет.
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
