# Окно переноса фактур: порядок действий

Перенос раздела «Фактуры» из отдельного сервиса `iq-factura-api` (база `iq_factura`)
в облако (база `cloudly`). Документ — это чек-лист на одно окно: его выполняют сверху вниз,
проверяя результат после каждого шага. Всё уже отрепетировано на копии прод-данных
дважды, включая запуск объединённого сервиса на перенесённой базе.

Инварианты, которые обязаны сохраниться (проверяются `scripts/factura-invariants.sql`):

| Что | Значение на момент переноса |
|---|---|
| Фактуры | 71 (все `SENT`) |
| Нумерация | 2025 → `serialIndex` 23; **2026 → 49**, следующая фактура `FACT-2026-00050` |
| Цепочка VeriFactu | запись **#24**, `currentHash` = `E6116A90…`, все 24 `ACCEPTED` |
| Сертификат | `Z1894474S`, срок 16.07.2028, шифр 4383 / nonce 12 / tag 16 |
| PDF | 71 объект в бакете `iq-factura-invoices`, `pdfS3Key` не меняются и не перегенерируются |
| Суммы | фактуры 87 233.08 €, расходы 3 492.54 € |

## Предусловия

- Ветка `feature/factura` в `cloudlyru` (бэкенд + раздел приложения) — готова, проверена.
- В репозитории `sobogd/cloudlyru` заведены секреты (значения берутся из
  `/home/deploy/apps/iq-factura-api/.env` на сервере; **в чат и в логи они не попадают**):

  | Секрет | Откуда значение |
  |---|---|
  | `FACTURA_COMPANY_ID` | `cmpv0jfi90003yfrjfd5va2eg` — компания `support` (NIF `Z1894474S`) |
  | `VERIFACTU_MASTER_KEY` | `VERIFACTU_MASTER_KEY` из `.env` фактуры, байт в байт |
  | `GEMINI_API_KEY` | `GEMINI_API_KEY` из `.env` фактуры |
  | `S3_INVOICES_BUCKET` | `iq-factura-invoices` (креды не нужны — подходят `S3_FILES_*`) |
  | `VERIFACTU_ENV` | `production` |
  | `VERIFACTU_MODE` | **пока не задавать** — по умолчанию `disabled`, см. шаг 6 |

- Никто не выставляет фактуры в старом дашборде (окно ~15 минут).

## Шаги

### 1. Артефакт отката и снимок «до»

```bash
# снимок данных до переноса (он же приёмка после)
ssh root@46.225.143.221 'sudo -u postgres psql -q -d iq_factura -f -' \
  < scripts/factura-invariants.sql > /tmp/factura-before.txt

# полный дамп старой базы — из него восстанавливается всё, включая историю миграций
ssh root@46.225.143.221 'sudo -u postgres pg_dump -d iq_factura -Fc -f /root/iqf-rollback-$(date +%Y%m%d-%H%M).dump'
```

### 2. Заморозка старого сервиса

```bash
ssh root@46.225.143.221 "sudo -u deployer pm2 stop iq-factura-api iq-factura-landing && sudo -u deployer pm2 save"
```

Останавливаем именно `iq-factura-api`: он единственный, кто пишет в `iq_factura`. Лендинг
и дашборд останавливаем заодно, чтобы никто не работал с API, который сейчас замолчит.

### 3. Дамп данных для переноса

```bash
ssh root@46.225.143.221 'sudo -u postgres pg_dump -d iq_factura --data-only --no-owner --disable-triggers --exclude-table=_prisma_migrations' \
  | gzip > /tmp/factura-data.sql.gz
```

`--exclude-table=_prisma_migrations` обязателен: в целевой базе своя история миграций,
и чужие строки в ней не нужны. `--disable-triggers` даёт заливать таблицы в любом порядке
(внешние ключи проверяются после).

### 4. Бэкап целевой базы

```bash
ssh root@46.225.143.221 'CLOUDLY_ENV_FILE=/home/deploy/apps/cloudlyru/.env /home/deploy/apps/cloudlyru/deploy/scripts/backup-db.sh'
```

### 5. Выкладка кода: миграция создаёт пустые фактурные таблицы

```bash
git push origin feature/factura:main        # или merge в main и push
# GH Actions: prisma migrate deploy (через SSH-туннель) → деплой → pm2 reload cloudlyru
gh run watch --repo sobogd/cloudlyru "$(gh run list --repo sobogd/cloudlyru -L1 --json databaseId -q '.[0].databaseId')"
```

Сервис поднимется с `VERIFACTU_MODE=disabled` (секрет ещё не задан) — это защита: отправка
в AEAT в этом состоянии невозможна, ручка ответит внятной ошибкой. Проверка:

```bash
curl -s https://files.iq-factura.com/api/v1/healthz
ssh root@46.225.143.221 'sudo -u postgres psql -d cloudly -Atc "select count(*) from invoices"'
# ожидаем: таблицы есть, строк 0
```

### 6. Заливка данных

```bash
gunzip -c /tmp/factura-data.sql.gz | ssh root@46.225.143.221 \
  'sudo -u postgres psql -v ON_ERROR_STOP=1 -d cloudly'
```

От `postgres` (суперпользователь) — так разрешены `ALTER TABLE … DISABLE TRIGGER ALL`
из дампа; владельцем таблиц остаётся роль `cloudly`, как и было.

### 7. Приёмка

```bash
ssh root@46.225.143.221 'sudo -u postgres psql -q -d cloudly -f -' \
  < scripts/factura-invariants.sql > /tmp/factura-after.txt
diff /tmp/factura-before.txt /tmp/factura-after.txt && echo "СЛЕПКИ СОВПАЛИ"

# цепочка VeriFactu не просто скопирована, а внутренне согласована: у каждой записи
# currentHash = sha256(hashInput), previousHash = хеш предыдущей, и ссылка на предыдущий
# хеш есть внутри самого hashInput
ssh root@46.225.143.221 'cd /home/deploy/apps/cloudlyru && node scripts/factura-chain-check.mjs'
# ожидаем: «support …: OK, записей 24, последняя #24 E6116A90FF1C1939…»

# выборочно: три PDF из базы действительно лежат в бакете
ssh root@46.225.143.221 "sudo -u deployer env -i PATH=/usr/bin:/bin HOME=/home/deploy node -e '
require(\"/home/deploy/apps/cloudlyru/node_modules/dotenv\").config({path:\"/home/deploy/apps/cloudlyru/.env\"});
const {S3Client,HeadObjectCommand}=require(\"/home/deploy/apps/cloudlyru/node_modules/@aws-sdk/client-s3\");
const c=new S3Client({endpoint:process.env.S3_FILES_ENDPOINT,region:process.env.S3_FILES_REGION,credentials:{accessKeyId:process.env.S3_FILES_ACCESS_KEY,secretAccessKey:process.env.S3_FILES_SECRET_KEY},forcePathStyle:true});
(async()=>{const {execSync}=require(\"child_process\");
const keys=execSync(\"sudo -u postgres psql -d cloudly -Atc \\\"select \\\\\\\"pdfS3Key\\\\\\\" from invoices order by random() limit 3\\\"\").toString().trim().split(\"\n\");
for(const k of keys){await c.send(new HeadObjectCommand({Bucket:process.env.S3_INVOICES_BUCKET,Key:k}));console.log(\"OK \"+k);}})();'"
```

Если `diff` пуст — данные переехали один в один. Если нет — **откат** (см. ниже), дальше не идём.

### 8. Включение отправки в AEAT

```bash
# секреты репозитория: значения не печатаем, читаем из .env фактуры прямо на сервере
gh secret set VERIFACTU_MODE --repo sobogd/cloudlyru --body submit
gh secret set VERIFACTU_ENV  --repo sobogd/cloudlyru --body production

# повторный деплой перезаписывает .env на сервере из секретов и перезапускает сервис
gh workflow run deploy.yml --repo sobogd/cloudlyru
```

`FACTURA_COMPANY_ID`, `VERIFACTU_MASTER_KEY`, `GEMINI_API_KEY`, `S3_INVOICES_BUCKET` к этому
моменту уже заданы — иначе `src/config/env.ts` откажется стартовать с включённым VeriFactu
(это сделано намеренно: молча не отправлять в налоговую хуже, чем не подняться).

Проверка, что сертификат расшифровывается тем же ключом:

```bash
curl -s -b <cookie> https://files.iq-factura.com/api/v1/companies/me | grep -o '"verifactuCertNif":"[^"]*"'
# ожидаем Z1894474S
```

### 9. Смоук в приложении

- вкладка «Фактуры»: 71 фактура, номера из серии `FACT-2026-…`;
- открыть PDF старой фактуры: файл приходит из бакета, `pdfGeneratedAt` не менялся;
- «Декларации» → Q3 2026: 19 фактур, 130 → сумма как в снимке (3884.04);
- «Расходы»: 53; «Контрагенты»: 14; «Счета»: 1.

### 10. Первая реальная фактура — проверка цепочки

Выставить одну фактуру и убедиться:

- номер `FACT-2026-00050`;
- в AEAT запись **#25**, статус `ACCEPTED`, `previousHash` = `E6116A90FF1C1939…` (тот же
  хеш, что был #24) — то есть цепочка продолжилась, а не началась заново;
- на PDF появился QR и хвост хеша.

Только после этого можно гасить старый стек (Ф5): `pm2 delete iq-factura-api
iq-factura-landing`, снять nginx-хосты `app.`/`api.`/`www`/`iq-factura.com`, убрать статику
дашборда, отключить шесть workflow'ов в репозитории `invoice-spain`, а базу `iq_factura`
и `iq_factura_test` оставить архивом на 30 дней.

## Откат

До шага 8 (включение отправки) откат простой: в `iq_factura` мы только читали.

```bash
ssh root@46.225.143.221 "sudo -u deployer pm2 start iq-factura-api iq-factura-landing"
ssh root@46.225.143.221 'sudo -u postgres psql -d cloudly -c "TRUNCATE users, sessions, companies, contacts, bank_accounts, invoices, invoice_lines, invoice_events, expenses, filed_declarations, support_messages, verifactu_registries, users_companies CASCADE"'
```

`TRUNCATE` чистит только перенесённые фактурные таблицы; данные облака (файлы, почта) лежат
в других таблицах и не затрагиваются. После отката старый сервис продолжает работу с прежней
базой, как будто ничего не было.

После шага 8 откат — вернуть ветку `main` на предыдущий коммит и выполнить шаги выше:
новая фактура в AEAT уже уйдёт, отменить её можно только аннулирующей записью из кабинета
налоговой (нумерация в Испании без пропусков).

## Проверки, которые уже сделаны на репетиции

- полный цикл на свежей базе: миграции → свежий дамп прода → восстановление → `diff` слепков
  совпал, сервер поднялся на перенесённой базе и отдал 71 фактуру, 53 расхода, 5 поданных,
  14 контрагентов, 1 счёт, декларацию Q3;
- цепочка VeriFactu проверена хешами: 24/24 записи дают `currentHash = sha256(hashInput)`,
  24/24 связаны `previousHash`, 24/24 содержат ссылку внутри `hashInput` — и на проде,
  и на перенесённой копии;
- PDF: пере-рендер архивной фактуры `FACT-2026-00049` перенесённым кодом даёт файл
  **бит-в-бит** с сохранённым (`pdfSha256` совпал). Именно поэтому `pdfkit` пришпилен к
  `0.17.2` — той версии, что стоит в сервисе фактур: на `0.20.x` (там ломающие изменения
  в шрифтах и обёртке строк) байты выходили другими, а значит и вид новых фактур мог
  разойтись со старыми.

## Почему порядок именно такой

- **Сначала дамп, потом заморозка** ненадолго, но безопаснее: если дамп не снимется, окно
  вообще не начинается.
- **Миграция до данных**: таблицы создаёт Prisma, а не `pg_dump` — тогда схема целевой базы
  ровно та, которую ждёт сгенерированный клиент, и `prisma migrate deploy` в следующих
  деплоях не видит расхождений.
- **Отправка включается последней**: до этого сервис физически не может отправить в AEAT
  ни одной записи, поэтому ошибка переноса не превращается в налоговую.
