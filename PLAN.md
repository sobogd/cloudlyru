# CloudlyRu — план M0: сервис + Postgres + S3

> Проект: CloudlyRu — личное self-hosted облако файлов/фото (open-source, для себя, потом шире).
> Домен: `files.iq-factura.com` · Репозиторий: `sobogd/cloudlyru` · Workspace-папка: `cloudlyru/`
> Статус: план согласован, M0 в разработке. Даты релизов — после уточнения VPS.

---

## 0. Рамки этого плана (M0)

Делаем **только фундамент**, на котором потом вырастут фото-таймлайн, поездки на карте, шаринг и мобильные клиенты:

1. Сервер-приложение (NestJS) на VPS: авторизация владельца, файловое дерево, загрузка/скачивание.
2. Postgres на VPS: метаданные (файлы, папки, хэши, сессии, токены).
3. Hetzner Object Storage (S3) как **основное хранилище файлов** (оригиналы, content-addressed).
4. Домен `files.iq-factura.com` + nginx reverse proxy + TLS.
5. Бэкап БД: ежедневный `pg_dump` → S3 (префикс `db/`).
6. Позже (вне M0): WebDAV/Finder, шаринг-ссылки с паролем/сроком, альбомы, фото-таймлайн/карта, мобильные клиенты, домашний HDD-бэкап.

**Принцип на будущее (зафиксирован):** фото/видео/файлы = объекты в S3 (content-addressed по SHA-256, дедуп), Postgres владеет логическим деревом и метаданными. Производные (превью/транскоды) — НЕ в S3 (минимум биллинга 64 КБ у Hetzner), а на локальном диске VPS (регенерируемы).

---

## 1. Архитектура

```
Телефоны / ноутбук / Mac (клиенты, M1+)
   │  HTTPS (files.iq-factura.com)
   ▼
nginx (VPS, 80/443, TLS) ──►  NestJS API (127.0.0.1:<PORT>)
                                   │
                                   ├──► Postgres 16 (VPS, локальный SSD) — метаданные
                                   │        └─ cron: pg_dump → S3 (db/cloudly-*.sql.gz, 30 дней)
                                   │
                                   └──► Hetzner S3 (бакет files) — оригиналы
                                          ключи: files/<sha256>[:.<ext>]  (content-addressed)
                                          versioning ON + lifecycle (префиксы)
```

Роли:
- **S3 = источник истины по файлам** (durable, 3× репликация Hetzner) + дампы БД.
- **VPS = мозг**: Postgres (дерево/метаданные), API, nginx. Тяжёлых файлов на диске VPS нет (только временный буфер загрузки + кэш).
- **Дом (Mac + HDD)** — будущая независимая копия S3 (см. §10), в M0 не нужен.

---

## 2. Стек и версии

| Компонент | Выбор | Почему |
|---|---|---|
| Язык/рантайм | Node.js 22 LTS + TypeScript | твой основной стек |
| Фреймворк | NestJS 10+ | тот же, что в iq-rest — знакомый |
| ORM | Prisma (PostgreSQL) | уже используешь в iq-rest |
| БД | PostgreSQL 16 (локально на VPS) | метаданные; сетевые БД запрещены |
| S3-клиент | `@aws-sdk/client-s3` + `@aws-sdk/lib-storage` (multipart) | стандарт, работает с Hetzner (S3-совместим) |
| Хэши | `sha256` стримингом при загрузке | дедуп + сверка целостности |
| Пароли | argon2id | см. безопасность |
| Процесс-менеджер | pm2 | как в iq-rest |
| HTTP | Fastify-адаптер NestJS (опционально) или Express | для M0 Express достаточно; Fastify — если понадобится скорость стримов |
| Очереди | не нужны в M0 (всё синхронно/лёгкое); BullMQ — когда появится транскодинг (M1+) | не тащить лишнее |

Версии фиксируются в `package.json` lock-файлом.

---

## 3. Домен, nginx, TLS

- Поддомен: `files.iq-factura.com` → A-запись на **выделенный VPS под cloudlyru** (⚠️ НЕ общий прод iq-rest — см. Открытые вопросы №1).
- Порт приложения: выбрать свободный, например **8305** (не пересекается с 8001–8005, 8123, 8130, 8131).
- TLS: если домен за Cloudflare-прокси (оранжевое облако) → сертификат на CF (режим Full), nginx слушает 80/443 и проксирует на 8305. Если DNS без CF → certbot (Let's Encrypt).
- **Лимит Cloudflare 100 МБ на запрос** (если CF проксирует): загрузки проектируем **чанками по 5–20 МБ** с resume — это требование в коде, а не опция.
- nginx: отдельный `server {}` блок, **не трогая существующие блоки iq-rest** на сервере.

```nginx
# /etc/nginx/sites-available/cloudlyru.conf  (симлинк в sites-enabled)
server {
    listen 80;
    server_name files.iq-factura.com;
    # если TLS на Cloudflare: 80 → 301 на https (CF сам даёт сертификат)
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name files.iq-factura.com;

    # --- если сертификаты выдаёт certbot (НЕ CF-proxy), раскомментируй:
    # ssl_certificate     /etc/letsencrypt/live/files.iq-factura.com/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/files.iq-factura.com/privkey.pem;
    # если CF-proxy (Full) — сертификаты CF/настоящие, обычно достаточно блока 80→https выше

    client_max_body_size 50m;      # чанки до 20 МБ + запас; стриминг без буферизации ниже
    client_body_buffer_size 512k;
    proxy_request_buffering off;   # не буферизовать загрузку (меньше RAM, быстрее)

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    location / {
        proxy_pass http://127.0.0.1:8305;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        send_timeout       300s;
    }
}
```

Файл-шаблон кладём в репо: `deploy/nginx/cloudlyru.conf` (переменные порта/домена).

---

## 4. Структура репозитория

```
cloudlyru/
├── PLAN.md
├── .env.example              # все переменные БЕЗ значений (секреты только на сервере)
├── .gitignore
├── package.json / pnpm-lock.yaml
├── prisma/
│   ├── schema.prisma
│   └── migrations/
├── src/
│   ├── main.ts
│   ├── app.module.ts
│   ├── config/               # env-валидация (zod или @nestjs/config + joi)
│   ├── auth/                 # login/password, сессии, CSRF, rate-limit
│   ├── users/                # (seed админа)
│   ├── folders/
│   ├── files/                # upload (чанки), download, dedupe, content
│   ├── s3/                   # S3-клиент (интерфейс Storage + реализация Hetzner)
│   ├── jobs/                 # pg_dump-скрипт (отдельный bin или cron)
│   └── common/               # guards, filters, helpers
├── deploy/
│   ├── nginx/cloudlyru.conf
│   ├── pm2/ecosystem.config.cjs
│   └── scripts/backup-db.sh  # pg_dump → gzip → S3
└── scripts/                   # dev-утилиты (seed, s3-admin)
```

---

## 5. Модель данных (Prisma) — M0

Принципы: uuid PK; все удаления — **soft delete** (корзина), hard delete только отдельной джобой по истечении retention; `updated_at` везде; уникальные ключи.

```prisma
// ===== Пользователи и сессии =====
model User {
  id           String   @id @default(uuid())
  login        String   @unique            // единственный владелец в M0 (seed 'admin')
  passwordHash String                        // argon2id
  createdAt    DateTime @default(now())
}

model Session {                              // веб-сессия (httpOnly cookie)
  id        String   @id @default(uuid())
  userId    String
  tokenHash String   @unique                 // sha256 токена в БД, сам токен только в cookie
  expiresAt DateTime
  createdAt DateTime @default(now())
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
}

model ApiToken {                             // app-password / device-токены (WebDAV, клиенты)
  id        String   @id @default(uuid())
  userId    String
  label     String                           // 'iphone-15', 'webdav-finder'
  tokenHash String   @unique
  scope     String   @default("files:rw")    // будущие: files:ro, files:upload:<folderId>, share:rw
  lastUsedAt DateTime?
  createdAt DateTime @default(now())
  revokedAt DateTime?
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
}

// ===== Файловое дерево =====
model Folder {
  id        String   @id @default(uuid())
  parentId  String?                          // null = корень
  name      String
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
  deletedAt DateTime?                        // soft delete
  parent    Folder?  @relation("FolderTree", fields: [parentId], references: [id])
  children  Folder[] @relation("FolderTree")
  @@unique([parentId, name])                // без дублей имён в папке (nullable unique в PG)
}

model Asset {                                // физический объект в S3 (один на содержимое!)
  id        String   @id @default(uuid())
  sha256    String   @unique                // ключ дедупа + имя объекта в S3
  size      BigInt
  mime      String
  ext       String?
  createdAt DateTime @default(now())
  entries   FileEntry[]
}

model FileEntry {                            // «файл» в папке — ссылка на Asset (дедуп)
  id        String   @id @default(uuid())
  folderId  String
  assetId   String
  name      String
  createdAt DateTime @default(now())
  deletedAt DateTime?                        // soft delete (корзина)
  folder    Folder   @relation(fields: [folderId], references: [id])
  asset     Asset    @relation(fields: [assetId], references: [id])
  @@unique([folderId, name])
}

// ===== Шаринг (каркас под M1; таблицу заводим сразу) =====
enum ShareKind      { FOLDER FILE ALBUM }
enum ShareCapability{ VIEW DOWNLOAD UPLOAD RW }

model Share {
  id         String         @id @default(uuid())
  kind       ShareKind
  targetId   String                        // folderId | fileEntryId | albumId
  token      String         @unique        // 128 бит случайности
  passwordHash String?                     // пароль на ссылку (без логина)
  capability ShareCapability @default(VIEW)
  expiresAt  DateTime?
  createdAt  DateTime       @default(now())
  revokedAt  DateTime?
}

// ===== Аудит =====
model AuditLog {
  id        String   @id @default(uuid())
  action    String                          // 'auth.login', 'share.created', 'file.deleted' ...
  meta      Json?
  ip        String?
  createdAt DateTime @default(now())
}
```

### Резерв под M1+ (схему расширим, не создаём сейчас)
`Album` (виртуальные коллекции: из файлов/папок), `AlbumItem`, `MediaMeta` (EXIF: captured_at, gps…), `Trip` (кластеры по времени+гео), `LocationSample` (история «где я был»), `StorageTemplate`. Правило: медиа с EXIF попадает в таймлайн автоматически, файлы без метаданных — только в дерево.

---

## 6. S3 (Hetzner Object Storage)

### 6.1 Факты тарифа (важно для проектирования)
- База ~**€6.49/мес**: 1 ТБ хранения + ~1 ТБ исходящего трафика включены (почасовая тарификация с капом).
- Сверх: **€6.35/мес за доп. ТБ**, трафик €1/ТБ. Входящий трафик и API-вызовы — бесплатно.
- **Минимальный биллинг-размер объекта 64 КБ** → нельзя складывать тысячи мелких объектов (превью/мини-файлы). Оригиналы фото/видео — крупные, ок.
- Регион: **FSN1** (Германия) — рядом с VPS, внутренний трафик бесплатный.

### 6.2 Бакет
- Имя: `cloudlyru-files` (или как создал в консоли Hetzner; записать в env `S3_FILES_BUCKET`).
- **Versioning: ON** — откат случайного удаления/перезаписи.
- **Lifecycle**: правило по префиксу `db/` — удалять объекты старше 30 дней (старые дампы); для `files/` — почистить старые **версии** старше 90 дней (сами объекты не трогаем).
- Object Lock (WORM) на короткий retention — решить в M1 вместе с корзиной в коде (обсуждено: «никакая ошибка не удалит всё»).

### 6.3 Ключи объектов
```
files/<sha256>[.<ext>]        # content-addressed: одинаковое содержимое = один объект
db/cloudly-YYYY-MM-DD.sql.gz  # дампы БД
tmp/                          # мусор от прерванных загрузок (чистится lifecycle'ом)
```
- Имя в S3 = хэш → переименование/перенос в дереве = операция в БД, без копий в S3.
- Скачивание: **presigned GET** (URL с TTL) — файл идёт клиенту из S3, VPS не узкое место.
- Загрузка M0: **через сервер** (чанки), сервер пишет multipart в S3 и считает SHA-256 → дедуп до записи. Presigned PUT напрямую с клиента — оптимизация M1 для больших видео.

### 6.4 Креды (безопасно)
- Имена env: `S3_FILES_ACCESS_KEY`, `S3_FILES_SECRET_KEY` (+ `S3_FILES_ENDPOINT`, `S3_FILES_REGION=fsn1`, `S3_FILES_BUCKET`).
- Значения **только на сервере** в `.env` (chmod 600), никогда в git/чате. В репо — `.env.example` с пустыми плейсхолдерами.

---

## 7. API (M0)

Базовый путь: `https://files.iq-factura.com/api/v1` · JSON · сессии cookie.

| Метод | Путь | Описание |
|---|---|---|
| POST | `/auth/login` | login+password → session cookie (rate-limit) |
| POST | `/auth/logout` | сброс сессии |
| GET  | `/auth/me` | текущий пользователь |
| GET  | `/folders` | дерево (или `/folders/:id/children`) |
| POST | `/folders` | создать папку `{parentId?, name}` |
| POST | `/folders/:id` | переименовать/перенести (soft) |
| DELETE | `/folders/:id` | в корзину (soft) |
| GET  | `/files/:id/content` | 302 → presigned S3 URL (download) |
| GET  | `/files/:id` | метаданные (включая sha256 для сверки) |
| DELETE | `/files/:id` | в корзину (soft) |
| POST | `/trash/restore`, `/trash/purge` | корзина |
| **POST** | **`/uploads`** | init: `{folderId?, name, size, mime, totalChunks}` → `uploadId` |
| **PUT** | **`/uploads/:id/chunks/:n`** | чанк (≤20 МБ), поток → во временный объект S3/буфер |
| **POST** | **`/uploads/:id/complete`** | склейка, SHA-256, дедуп, создание Asset+FileEntry; 409 если уже есть |
| POST | `/shares` (каркас) | создать share (без UI в M0) |
| GET  | `/healthz` | для мониторинга nginx/pm2 |

### 7.1 Поток загрузки (чанки, resume)
1. Клиент: `POST /uploads` (метаданные).
2. Клиент шлёт чанки `PUT /uploads/:id/chunks/:n`; сервер пишет их последовательно (временный multipart upload в S3 или локальный буфер + multipart). Прервалось → клиент продолжает с последнего принятого чанка (`GET /uploads/:id/status`).
3. `POST /uploads/:id/complete`: сервер финализирует, **считает SHA-256**, проверяет `Asset.sha256`:
   - есть → удаляем временный объект, создаём только `FileEntry` (дедуп, 0 байт в S3);
   - нет → `PutObject`/finalize multipart под ключом `files/<sha256>`, создаём Asset + FileEntry.
4. Ответ: `{entry, asset, deduped: boolean}`.

Ограничения: максимальный размер файла (например 50 ГБ, конфиг), лимит числа активных uploadId на пользователя, таймаут неактивности (чистка `tmp/`).

---

## 8. Авторизация (M0 — минимум, согласовано)

- **Один владелец**: seed-админ (login/password). Пароль — argon2id.
- Веб-сессия: httpOnly + Secure + SameSite=Lax cookie; CSRF — double-submit токен (SPA).
- Никакой регистрации. Никакого Google (решение зафиксировано).
- **ApiToken (app-password)**: генерится в вебе, используется WebDAV/Finder/клиентами (Basic по HTTPS) — таблица готова, UI в M1.
- Гости: только share-ссылки с паролем и сроком (таблица готова, функционал в M1).
- Rate-limit на `/auth/login` (например 5 попыток/мин + lockout), audit-log входов.

---

## 9. Фон и джобы

- **Дамп БД → S3** (cron на VPS, 03:00): `pg_dump` (clean) | gzip → `db/cloudly-<date>.sql.gz`. Lifecycle хранит 30 дней. Скрипт: `deploy/scripts/backup-db.sh`.
- **Проверка целостности** (M1): периодический аудит «файлы в БД ↔ объекты в S3» + сверка размеров.
- Мониторинг: `GET /healthz` + pm2 + логи; алерт в Telegram — позже.

---

## 10. Бэкап «домой на HDD» (будущее, вне M0)

Когда будешь уходить от Google: на Mac (always-on) `rclone sync s3:cloudlyru-files → /Volumes/BackupHDD/cloudlyru/` каждую ночь с `--backup-dir` (удалённое не стирается, а уходит в историю). Seed — разовая операция на дни с возобновлением. В M0 не делаем, но архитектура S3 это поддерживает из коробки.

---

## 11. Конфигурация и секреты

`.env.example` (в репо, без значений):
```
NODE_ENV=production
PORT=8305
BASE_URL=https://files.iq-factura.com
DATABASE_URL=postgresql://cloudly:CHANGE_ME@127.0.0.1:5432/cloudly
SESSION_SECRET=CHANGE_ME_64_hex
ADMIN_LOGIN=admin
ADMIN_PASSWORD_HASH=            # заполняется seed-скриптом
S3_FILES_ACCESS_KEY=
S3_FILES_SECRET_KEY=
S3_FILES_ENDPOINT=https://fsn1.your-objectstorage.com
S3_FILES_REGION=fsn1
S3_FILES_BUCKET=cloudlyru-files
UPLOAD_CHUNK_MAX_MB=20
TRASH_RETENTION_DAYS=30
```

Правила: `.env` в `.gitignore`; на сервере `.env` chmod 600; значения не появляются в логах/чате; ротация SESSION_SECRET и app-password — через админ-скрипты.

---

## 12. Развёртывание на VPS (шаги)

⚠️ Выполнять на **выделенном** VPS под cloudlyru (не на общем проде iq-rest) — см. Открытые вопросы.

```bash
# 1. База
sudo apt update && sudo apt install -y postgresql-16   # или из apt.postgresql.org
sudo -u postgres createuser cloudly -P                 # пароль → в .env (не в git)
sudo -u postgres createdb -O cloudly cloudly

# 2. Node + приложение
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs
sudo mkdir -p /opt/cloudlyru && sudo chown $USER: /opt/cloudlyru
# git clone sobogd/cloudlyru /opt/cloudlyru ; pnpm install --prod ; pnpm prisma migrate deploy
# env: /opt/cloudlyru/.env (600)

# 3. pm2
pnpm add -g pm2
pm2 start ecosystem.config.cjs   # deploy/pm2/ecosystem.config.cjs (name: cloudlyru, port 8305)
pm2 save && pm2 startup          # автозапуск после ребута

# 4. nginx (шаблон deploy/nginx/cloudlyru.conf → /etc/nginx/sites-available/cloudlyru.conf)
sudo ln -s /etc/nginx/sites-available/cloudlyru.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 5. TLS
#    если CF-proxy: ничего не делать (сертификат на CF) — проверить режим Full
#    если DNS напрямую: sudo certbot --nginx -d files.iq-factura.com

# 6. Cron бэкапа БД
crontab -e   # 0 3 * * * /opt/cloudlyru/deploy/scripts/backup-db.sh >> /var/log/cloudly-backup.log 2>&1

# 7. Проверка
curl -s https://files.iq-factura.com/api/v1/healthz
```

---

## 13. Безопасность (чек-лист M0)

- [ ] argon2id для паролей; сессии — токен в httpOnly-cookie, в БД только hash.
- [ ] CSRF (double-submit) на все мутирующие запросы SPA.
- [ ] rate-limit: логин (5/мин), upload init (100/час), общий (helmet + express-rate-limit).
- [ ] CORS: только `https://files.iq-factura.com` (или same-origin SPA).
- [ ] nginx: только 80/443 снаружи; 8305 слушает 127.0.0.1; ufw: 22,80,443.
- [ ] S3: versioning ON; ключи — отдельные, в идеале без `s3:DeleteObject` у runtime-ключа (удаление — отдельной админ-операцией); lifecycle на `db/` и старые версии.
- [ ] presigned URL: TTL 5–15 мин, только GET.
- [ ] Валидация путей: никаких «..», имена файлов — без спецсимволов-ловушек; размеры/типы — лимиты.
- [ ] Аудит-лог входов и удалений.
- [ ] `.env` не в git; ключи не в логах (mask в логгере).

---

## 14. Критерии готовности M0

1. `https://files.iq-factura.com` открывается, TLS валиден, nginx проксирует на 8305.
2. Логин владельца работает; без сессии — 401; rate-limit на логин работает.
3. Через API: создать папки, залить файл (чанки), скачать по presigned-URL, положить в корзину и восстановить.
4. **Дедуп**: повторная загрузка того же файла не создаёт новый объект в S3 (проверка по количеству объектов в бакете).
5. Загрузка файла **>100 МБ** проходит чанками без ошибок (проверка лимита CF/nginx).
6. Cron: в S3 появился `db/cloudly-*.sql.gz`; восстановление из него на чистой БД проходит (прогнать один раз вручную).
7. В бакете: versioning ON, lifecycle создан; в S3 нет объектов в `tmp/` после завершённых загрузок.
8. `GET /healthz` = 200; pm2 restart переживает перезагрузку VPS.

---

## 15. Открытые вопросы (нужны ответы до кодинга)

1. **Какой VPS**: отдельный под cloudlyru (рекомендую, CX22/CX32 у Hetzner) или тот же, что прод iq-rest? Если общий — нужен явный план изоляции (отдельный юзер/порт/папка, не трогать блоки iq-rest).
2. **DNS**: `files.iq-factura.com` за Cloudflare-прокси (оранжевое облако) или A-запись напрямую на VPS? От этого зависит TLS (CF vs certbot) и актуальность лимита 100 МБ.
3. **Репозиторий**: `sobogd/cloudlyru` — private или public (проект задуман open-source)? Пока создаю private — легко переключить.
4. **Бакет**: имя и регион созданного в Hetzner бакета (ожидаю `cloudlyru-files`, FSN1) — подтвердить.
5. **ОС VPS** (Ubuntu 24.04?) и есть ли уже nginx/postgres на нём — для шагов §12.

---

## 16. Что НЕ входит в M0 (роадмап дальше)

- M1: WebDAV (Finder/Mac), корзина-UI, шаринг-ссылки (пароль+срок), presigned-загрузка.
- M2: фото-таймлайн/карта по EXIF + авто-определение поездок, альбомы.
- M3: Android-клиент (автовыгрузка + share-диалог), затем iOS (шеринг в оригинале + автовыгрузка).
- M4: история местоположений («где я был», 5–10 мин), дом. HDD-бэкап, миграция из Google.
