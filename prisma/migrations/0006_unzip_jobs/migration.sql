-- Разархивирование архивов внутри хранилища: состояние фоновой задачи.
-- ZIP читается из S3 по Range-запросам, распакованное кладётся обратно в S3.

CREATE TABLE "UnzipJob" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "assetId" TEXT NOT NULL,
    "folderId" TEXT NOT NULL,
    "targetFolderId" TEXT,
    "state" TEXT NOT NULL DEFAULT 'pending',
    "totalEntries" INTEGER NOT NULL DEFAULT 0,
    "doneEntries" INTEGER NOT NULL DEFAULT 0,
    "totalBytes" BIGINT NOT NULL DEFAULT 0,
    "doneBytes" BIGINT NOT NULL DEFAULT 0,
    "skippedEntries" INTEGER NOT NULL DEFAULT 0,
    "currentName" TEXT,
    "error" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "startedAt" TIMESTAMP(3),
    "finishedAt" TIMESTAMP(3),
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "UnzipJob_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "UnzipJob_state_createdAt_idx" ON "UnzipJob"("state", "createdAt");
CREATE INDEX "UnzipJob_entryId_idx" ON "UnzipJob"("entryId");
