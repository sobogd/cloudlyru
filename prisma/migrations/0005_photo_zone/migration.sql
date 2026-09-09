-- AlterTable: фото/файлы разделены зонами
-- FILES (обычный диск; медиа хранится как есть) | PHOTOS (поддерево системной папки «Фото»; медиа конвертируется)

ALTER TABLE "User" ADD COLUMN "photoFolderId" TEXT;

-- AlterTable
ALTER TABLE "Folder" ADD COLUMN "zone" TEXT NOT NULL DEFAULT 'FILES';

-- AlterTable
ALTER TABLE "FileEntry" ADD COLUMN "zone" TEXT NOT NULL DEFAULT 'FILES';

-- CreateIndex
CREATE INDEX "FileEntry_zone_deletedAt_idx" ON "FileEntry"("zone", "deletedAt");
