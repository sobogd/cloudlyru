-- Таблица неудач приёма почты (MailIngestFailure).
--
-- Зачем она: после INGEST_MAX_TRIES попыток письмо пропускают — курсор уходит дальше и письмо
-- больше не попадётся. До этой таблицы единственным следом были строка в логе и счётчик в
-- `MailAccount.statusError`, а счётчик жил в памяти процесса: первый же перезапуск его стирал,
-- и дырка в архиве становилась невидимой навсегда. Теперь запись переживает перезапуск и
-- снимается сама, когда письмо всё-таки сохранилось (MailSyncService.clearUnsaved).
--
-- Изменение аддитивное: новая таблица, существующие данные не трогаются.
CREATE TABLE "MailIngestFailure" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "folderPath" TEXT NOT NULL,
    "uidValidity" BIGINT NOT NULL,
    "uid" BIGINT NOT NULL,
    "tries" INTEGER NOT NULL DEFAULT 1,
    "error" TEXT NOT NULL,
    "firstAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "MailIngestFailure_pkey" PRIMARY KEY ("id")
);

-- Координаты письма: по ним запись обновляется при повторной неудаче и снимается при успехе.
CREATE UNIQUE INDEX "MailIngestFailure_accountId_folderPath_uidValidity_uid_key"
  ON "MailIngestFailure"("accountId", "folderPath", "uidValidity", "uid");

-- Свежие неудачи аккаунта: по этому порядку строится счётчик в статусе аккаунта.
CREATE INDEX "MailIngestFailure_accountId_lastAt_idx"
  ON "MailIngestFailure"("accountId", "lastAt" DESC);

-- Записи уходят вместе с аккаунтом: без аккаунта координаты письма ничего не значат.
ALTER TABLE "MailIngestFailure"
  ADD CONSTRAINT "MailIngestFailure_accountId_fkey"
  FOREIGN KEY ("accountId") REFERENCES "MailAccount"("id") ON DELETE CASCADE ON UPDATE CASCADE;
