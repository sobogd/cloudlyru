-- Фундамент раздела «Почта»: аккаунты, курсоры синка, письма, вложения.
--
-- Почему отдельные таблицы, а не ещё одна ветка дерева: письмо — не файл. У него есть
-- заголовки (от кого, кому, тема, Message-ID, References), состояние прочтения, папка
-- (входящие/исходящие) и серверный идентификатор, по которому повторный проход по папке
-- IMAP понимает, что письмо уже сохранено. Дерево остаётся деревом, а письма ссылаются
-- на него через вложения.
--
-- Модель «две папки»: MailMessage.box — 'inbox' | 'sent'. Всё полученное, включая спам,
-- лежит во «Входящих»: других папок у почты нет намеренно. MailCursor описывает папку
-- ИСТОЧНИКА (их много: [Gmail]/All Mail, [Gmail]/Spam, INBOX, Junk, Sent Messages) и
-- говорит, в какую из наших двух корзин её раскладывать.
--
-- Сырой .eml хранится как обычный Asset (объект files/<sha256>, дедуп по содержимому):
-- объект, не заведённый в Asset, снёс бы deploy/scripts/sweep-orphans.mjs как «зомби».
-- Вложения — записи дерева в скрытой зоне MAIL (FileEntry + MailAttachment.entryId),
-- поэтому одно и то же вложение в двух письмах не занимает места дважды.
--
-- User.mailFolderId — системная папка «Почта» верхнего уровня, создаётся лениво при первом
-- обращении почтового модуля. В GET /auth/me не отдаётся: папка скрыта отовсюду, включая
-- WebDAV и клиенты синхронизации (по зоне MAIL не пишется журнал изменений).

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "mailFolderId" TEXT;

-- CreateTable
CREATE TABLE "MailAccount" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "imapHost" TEXT NOT NULL,
    "imapPort" INTEGER NOT NULL DEFAULT 993,
    "smtpHost" TEXT NOT NULL,
    "smtpPort" INTEGER NOT NULL DEFAULT 465,
    "login" TEXT NOT NULL,
    "secretEnc" TEXT NOT NULL,
    "authKind" TEXT NOT NULL DEFAULT 'password',
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "status" TEXT NOT NULL DEFAULT 'idle',
    "statusError" TEXT,
    "lastSyncAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "MailAccount_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MailCursor" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "imapPath" TEXT NOT NULL,
    "box" TEXT NOT NULL,
    "uidValidity" BIGINT NOT NULL,
    "lastUid" BIGINT NOT NULL DEFAULT 0,
    "backfillFrom" TIMESTAMP(3),
    "backfillDone" BOOLEAN NOT NULL DEFAULT false,
    "lastSeenAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "MailCursor_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MailMessage" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "box" TEXT NOT NULL,
    "folderPath" TEXT NOT NULL,
    "uid" BIGINT NOT NULL,
    "uidValidity" BIGINT NOT NULL,
    "gmailMsgId" TEXT,
    "messageId" TEXT,
    "threadKey" TEXT,
    "subject" TEXT,
    "fromName" TEXT,
    "fromAddr" TEXT,
    "toAddrs" TEXT[],
    "ccAddrs" TEXT[],
    "replyTo" TEXT,
    "inReplyTo" TEXT,
    "refs" TEXT[],
    "sentAt" TIMESTAMP(3),
    "receivedAt" TIMESTAMP(3) NOT NULL,
    "sortAt" TIMESTAMP(3) NOT NULL,
    "size" INTEGER NOT NULL,
    "hasAttachments" BOOLEAN NOT NULL DEFAULT false,
    "seen" BOOLEAN NOT NULL DEFAULT false,
    "flagged" BOOLEAN NOT NULL DEFAULT false,
    "bodyText" TEXT,
    "rawAssetId" TEXT NOT NULL,
    "deletedAt" TIMESTAMP(3),
    "remoteDeletedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MailMessage_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MailAttachment" (
    "id" TEXT NOT NULL,
    "messageId" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "partIndex" INTEGER NOT NULL,
    "filename" TEXT NOT NULL,
    "mime" TEXT NOT NULL,
    "size" INTEGER NOT NULL,
    "contentId" TEXT,
    "inline" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MailAttachment_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "MailAccount_userId_idx" ON "MailAccount"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "MailAccount_userId_email_key" ON "MailAccount"("userId", "email");

-- CreateIndex
CREATE INDEX "MailCursor_accountId_idx" ON "MailCursor"("accountId");

-- CreateIndex
CREATE UNIQUE INDEX "MailCursor_accountId_imapPath_key" ON "MailCursor"("accountId", "imapPath");

-- CreateIndex
CREATE INDEX "MailMessage_userId_box_sortAt_id_idx" ON "MailMessage"("userId", "box", "sortAt" DESC, "id" DESC);

-- CreateIndex
CREATE INDEX "MailMessage_accountId_messageId_idx" ON "MailMessage"("accountId", "messageId");

-- CreateIndex
CREATE INDEX "MailMessage_deletedAt_idx" ON "MailMessage"("deletedAt");

-- CreateIndex
CREATE UNIQUE INDEX "MailMessage_accountId_folderPath_uidValidity_uid_key" ON "MailMessage"("accountId", "folderPath", "uidValidity", "uid");

-- CreateIndex
CREATE UNIQUE INDEX "MailAttachment_entryId_key" ON "MailAttachment"("entryId");

-- CreateIndex
CREATE INDEX "MailAttachment_messageId_idx" ON "MailAttachment"("messageId");

-- CreateIndex
CREATE UNIQUE INDEX "MailAttachment_messageId_partIndex_key" ON "MailAttachment"("messageId", "partIndex");

-- AddForeignKey
ALTER TABLE "MailAccount" ADD CONSTRAINT "MailAccount_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MailCursor" ADD CONSTRAINT "MailCursor_accountId_fkey" FOREIGN KEY ("accountId") REFERENCES "MailAccount"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MailMessage" ADD CONSTRAINT "MailMessage_accountId_fkey" FOREIGN KEY ("accountId") REFERENCES "MailAccount"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MailMessage" ADD CONSTRAINT "MailMessage_rawAssetId_fkey" FOREIGN KEY ("rawAssetId") REFERENCES "Asset"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MailAttachment" ADD CONSTRAINT "MailAttachment_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "MailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MailAttachment" ADD CONSTRAINT "MailAttachment_entryId_fkey" FOREIGN KEY ("entryId") REFERENCES "FileEntry"("id") ON DELETE CASCADE ON UPDATE CASCADE;


-- Частичный УНИКАЛЬНЫЙ индекс вместо обычного @@index из схемы: дедуп писем Gmail держится
-- на X-GM-MSGID, и повторный проход (IDLE + плановый синк) при гонке не должен создавать
-- вторую строку того же письма. Частичный — потому что у писем iCloud этого поля нет вовсе,
-- и NULL не должны конфликтовать между собой. В schema.prisma такой индекс не выражается,
-- поэтому живёт только здесь (как MediaMeta_capturedAt_idx в 20260913120000).
CREATE UNIQUE INDEX "MailMessage_accountId_gmailMsgId_key"
  ON "MailMessage" ("accountId", "gmailMsgId")
  WHERE "gmailMsgId" IS NOT NULL;
