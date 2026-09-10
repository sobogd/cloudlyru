/*
  ВНИМАНИЕ: миграция правилась руками.

  Prisma сгенерировала `ADD COLUMN "updatedAt" NOT NULL` без default — на проде таблица
  FileEntry не пустая, и такая миграция упала бы. Здесь тот же результат в три шага:
  добавить nullable → заполнить из createdAt → поставить NOT NULL. DB-default не оставляем:
  иначе `prisma migrate dev` увидит расхождение между схемой (без default) и БД.
*/

-- AlterTable
ALTER TABLE "FileEntry" ADD COLUMN     "clientMtime" TIMESTAMP(3),
ADD COLUMN     "keepOffline" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "updatedAt" TIMESTAMP(3);

-- Backfill: у существующих записей момент последнего изменения неизвестен, берём createdAt
UPDATE "FileEntry" SET "updatedAt" = "createdAt" WHERE "updatedAt" IS NULL;

ALTER TABLE "FileEntry" ALTER COLUMN "updatedAt" SET NOT NULL;

-- AlterTable
ALTER TABLE "Folder" ADD COLUMN     "keepOffline" BOOLEAN NOT NULL DEFAULT false;

-- AlterTable
ALTER TABLE "UploadSession" ADD COLUMN     "clientMtime" TIMESTAMP(3),
ADD COLUMN     "replace" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "completedAt" TIMESTAMP(3),
ADD COLUMN     "result" JSONB,
ADD COLUMN     "expectedSha256" TEXT,
ADD COLUMN     "expectedUpdatedAt" TIMESTAMP(3);

-- CreateTable
CREATE TABLE "ChangeLog" (
    "seq" BIGSERIAL NOT NULL,
    "userId" TEXT NOT NULL,
    "target" TEXT NOT NULL,
    "op" TEXT NOT NULL,
    "targetId" TEXT NOT NULL,
    "folderId" TEXT,
    "name" TEXT NOT NULL,
    "zone" TEXT,
    "sha256" TEXT,
    "size" BIGINT,
    "mime" TEXT,
    "clientMtime" TIMESTAMP(3),
    "keepOffline" BOOLEAN NOT NULL DEFAULT false,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ChangeLog_pkey" PRIMARY KEY ("seq")
);

-- CreateIndex
CREATE INDEX "ChangeLog_userId_seq_idx" ON "ChangeLog"("userId", "seq");

-- CreateIndex
CREATE INDEX "ChangeLog_at_idx" ON "ChangeLog"("at");
