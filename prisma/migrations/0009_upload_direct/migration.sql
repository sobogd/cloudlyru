-- Прямая загрузка в S3: ETag'и частей и объявленный sha256 храним в БД.
-- Раньше части жили в RAM процесса: рестарт сервиса терял сессию, а complete не мог
-- собрать объект по ETag'ам, которых сервер не видел (прямая загрузка мимо VPS).
ALTER TABLE "UploadSession" ADD COLUMN "parts" JSONB;
ALTER TABLE "UploadSession" ADD COLUMN "declaredSha256" TEXT;
ALTER TABLE "UploadSession" ADD COLUMN "direct" BOOLEAN NOT NULL DEFAULT false;
