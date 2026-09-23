# VPS prod-iq-rest — runbook (46.225.143.221)

Бэкапы, восстановление и PITR для прод-VPS. Написан по итогам аудита 2026-09-10.
Локальная копия — здесь, на Маке; рабочая копия для «здесь и сейчас» лежит на сервере в `/root/RESTORE.md`.

## Где что лежит

| Что | Расписание | Куда | Хранение |
| --- | --- | --- | --- |
| 2 горячие БД (`iq_rest`, `rests`) | каждые 5 мин | `hetzner/reset/hot/` | 3 дня |
| **все БД** (12) | каждый час в :02 | `hetzner/reset/hourly/` | 7 дней |
| `pg_dumpall` (роли + все БД) | 03:30 | `hetzner/reset/daily/` | 30 дней |
| **шифрованный снапшот конфигов**: nginx, letsencrypt, postgres, ssh, fail2ban, ufw, cron, все `.env`, PM2-дамп, helper-скрипты | 03:45 | `hetzner/sobogd/server-config/` | 30 дней |
| **WAL** (для PITR) | каждые 10 мин | `hetzner/sobogd/pgwal/` | 21 день |
| физический base backup | вс 04:00 | `hetzner/sobogd/pgbase/<stamp>/` | 21 день (3 копии) |
| БД `cloudly` (владелец — приложение) | 03:00 | bucket `cloudlyru`, префикс `db/` | 30 дней (lifecycle) |
| разовые архивы (старые дампы, снятое с сервера состояние) | вручную | `hetzner/sobogd/archive/2026-09-10/`, `sobogd/archive-encrypted/20260910/` | без автоочистки |

`mc`-алиас `hetzner` (Hetzner Object Storage, nbg1) настроен только у root: `/root/.mc/config.json`
(попадает и в шифрованные снапшоты).

## Пароль шифрования — на Маке, не только на сервере

Автоматическое шифрование идёт паролем из `/root/.backup-pass` (600) на сервере.
**Копия на Маке: `~/work/.env`, ключ `VPS_BACKUP_PASS`** (файл 600, вне git).

```bash
# скачать нужный архив с сервера на Мак
ssh root@46.225.143.221 'mc cat hetzner/sobogd/server-config/config-<stamp>.tar.gz.gpg' > /tmp/cfg.gpg
# расшифровать и распаковать локально
gpg --batch --passphrase-file <(grep ^VPS_BACKUP_PASS= ~/work/.env | cut -d= -f2-) \
    -d /tmp/cfg.gpg | tar xz -C /tmp/vps-restore/
```

Проверено 2026-09-10: архив `config-20260910-1552.tar.gz.gpg` (59 МБ) скачивается на Мак и
расшифровывается локальной копией пароля — 1322 файла.

## Восстановление одной БД из логического дампа

```bash
ssh root@46.225.143.221
/usr/local/bin/mc ls hetzner/reset/hourly/ | grep iq_rest
/usr/local/bin/mc cp hetzner/reset/hourly/iq_rest_<stamp>.sql.gz /tmp/
gunzip -c /tmp/iq_rest_<stamp>.sql.gz | sudo -u postgres psql -d iq_rest
```
Дампы — plain SQL с `--clean --if-exists`: объекты пересоздаются на месте.
Свежие копии также лежат локально в `/var/backups/postgresql/{hot,hourly,daily}/`.

## Восстановление всего (новый сервер / потеря сервера)

```bash
# 1. роли + все базы
/usr/local/bin/mc cp hetzner/reset/daily/pg_dumpall_<stamp>.sql.gz /tmp/
gunzip -c /tmp/pg_dumpall_<stamp>.sql.gz | sudo -u postgres psql -d postgres
# 2. конфиги, .env, PM2-дамп, helper-скрипты
/usr/local/bin/mc cp hetzner/sobogd/server-config/config-<stamp>.tar.gz.gpg /tmp/
gpg --batch --passphrase-file /root/.backup-pass -d /tmp/config-<stamp>.tar.gz.gpg | tar xz -C /
# 3. приложения — только из GitHub Actions (git-чекаутов на сервере нет):
#    запустить нужные deploy-воркфлоу вручную; затем sudo -u deployer pm2 resurrect
```

## Point-in-time recovery

1. `mc cp --recursive hetzner/sobogd/pgbase/<stamp> /tmp/pgbase/`
2. Остановить PostgreSQL, отложить старый data-dir, распаковать `base.tar.gz` в
   `/var/lib/postgresql/17/main`, `pg_wal.tar.gz` — в его `pg_wal/`.
3. Скачать WAL-сегменты из `hetzner/sobogd/pgwal/` в `pg_wal/`.
4. В `postgresql.auto.conf`: `restore_command = 'cp /path/to/pgwal/%f %p'`,
   `recovery_target_time = '<timestamp>'`, создать `recovery.signal`, запустить кластер.
5. Проверить, убрать `recovery.signal` и `restore_command`.

Архивация WAL сделана двухшаговой: `archive_command` только копирует сегмент в локальный
спул `/var/lib/postgresql/wal-archive`, а в S3 его увозит cron `wal-upload.sh`. Сломанный S3
не может застопорить чекпоинты.

**Аварийный клапан:** если архиватор сыпет ошибками И свободно меньше 4 ГБ, `wal-upload.sh`
ставит `archive_command='/bin/true'`, чтобы WAL не забил диск. Вернуть:
`ALTER SYSTEM SET archive_command = 'test ! -f /var/lib/postgresql/wal-archive/%f && cp %p /var/lib/postgresql/wal-archive/%f'; SELECT pg_reload_conf();`

## Мониторинг

`/usr/local/bin/vps-healthcheck.sh` (cron, каждые 5 мин): диск, RAM, swap, load, systemd-юниты,
PM2, шесть публичных HTTPS-доменов, PostgreSQL (коннекты, idle-in-transaction, сбои архиватора,
размер WAL-спула) и свежесть всех потоков бэкапов в S3. Пишет `/var/log/vps-health.log`,
состояние — `/var/lib/vps-health.state` (алерт при смене состояния, повтор каждые 12 ч).
Канал алертов выключен; включается в `/etc/vps-health.env` (`SLACK_WEBHOOK=` или
`TELEGRAM_BOT_TOKEN=`+`TELEGRAM_CHAT_ID=`).

## PostgreSQL

- `listen_addresses = localhost` — снаружи БД недоступна. Ходить так:
  `ssh -L 5433:localhost:5432 root@46.225.143.221`.
- Внешние правила в `pg_hba.conf` закомментированы, UFW-правила на 5432 удалены.
- Тюнинг: `shared_buffers=512MB`, `effective_cache_size=1536MB`, `work_mem=8MB`,
  `maintenance_work_mem=128MB`, `log_min_duration_statement=1000` (запросы > 1 с — в
  `/var/log/postgresql/postgresql-17-main.log`), `track_io_timing=on`, `archive_mode=on`.
- 12 баз, 9 ролей, только `plpgsql` — переезд дампом простой.

## Что снято с сервера 2026-09-10 (и почему)

Сервер приведён к виду «только то, что деплоят GitHub Actions»:

- Claude Code: системная установка `/usr/lib/node_modules/@anthropic-ai` + `/usr/bin/claude`,
  npm-установка у deployer, `~/.claude`, `.claude.json`, кэши MCP, `.desktop`-хендлер.
- git-на-сервере: **приватные SSH-ключи** `/root/.ssh/deploy_key` и
  `/home/deployer/.ssh/github_dev` + `~/.ssh/config`, `~/.gitconfig`, GitHub CLI с OAuth-токеном
  (`~/.config/gh`, пакет `gh` удалён).
- Рабочие материалы Claude-эпохи: `~/CLAUDE.md`, `~/research`, `~/google-ads`, `~/staging`,
  PDF и превью меню Los Castanitos, playwright-кэш (1.4 ГБ, ни одно приложение его не использует).
- БД `my-history` удалена (приложение снято 2026-09-09), из горячего бэкапа исключена.

Всё перечисленное лежит в `hetzner/sobogd/archive-encrypted/20260910/` (gpg AES-256, тот же пароль):

```bash
ssh root@46.225.143.221 'mc cat hetzner/sobogd/archive-encrypted/20260910/declutter-<stamp>.tar.gz.gpg' > /tmp/d.gpg
gpg --batch --passphrase-file <(grep ^VPS_BACKUP_PASS= ~/work/.env | cut -d= -f2-) -d /tmp/d.gpg | tar xz -C /tmp/declutter/
```

Локальная копия проекта `my-history` тоже удалена с Мака — её архив
`my-history-local-20260910.tar.gz.gpg` лежит там же; полная история — в GitHub (`sobogd/my-history`).

Осталось на стороне DNS (в Cloudflare, руками): A-записи `my-history.iq-rest.com` и
`admin/back/menu/moneyboss.iq-rest.com` можно удалить — nginx на них уже отдаёт 410.
