-- CreateTable M2.5: очередь конвертации + флаги мастера на Asset

ALTER TABLE "Asset" ADD COLUMN "masterReadyAt" TIMESTAMP(3);
ALTER TABLE "Asset" ADD COLUMN "masterMime" TEXT;

CREATE TABLE "Job" (
    "id" TEXT NOT NULL,
    "assetId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'pending',
    "error" TEXT,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "startedAt" TIMESTAMP(3),
    "finishedAt" TIMESTAMP(3),
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Job_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "Job_state_createdAt_idx" ON "Job"("state", "createdAt");
CREATE INDEX "Job_assetId_idx" ON "Job"("assetId");

-- AddForeignKey
ALTER TABLE "Job" ADD CONSTRAINT "Job_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "Asset"("id") ON DELETE CASCADE ON UPDATE CASCADE;
