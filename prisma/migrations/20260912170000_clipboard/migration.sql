-- Буфер копирования/вырезания на пользователе: одна цель (файл или папка) и режим.
-- В БД, а не в localStorage браузера: буфер один на аккаунт и переживает рестарт клиента.
ALTER TABLE "User" ADD COLUMN "clipboardKind" TEXT;
ALTER TABLE "User" ADD COLUMN "clipboardId" TEXT;
ALTER TABLE "User" ADD COLUMN "clipboardMode" TEXT;
ALTER TABLE "User" ADD COLUMN "clipboardAt" TIMESTAMP(3);
