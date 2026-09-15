-- CreateTable: статистика конвертации (длительность задач по видам).
-- Строка Job на успехе удаляется, поэтому средняя длительность задачи хранится здесь:
-- по ней /queue/status оценивает срок остатка очереди.

CREATE TABLE "ConvertStat" (
    "id" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'done',
    "durationMs" INTEGER NOT NULL,
    "finishedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ConvertStat_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "ConvertStat_kind_finishedAt_idx" ON "ConvertStat"("kind", "finishedAt");
