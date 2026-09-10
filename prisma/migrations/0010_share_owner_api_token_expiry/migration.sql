-- AlterTable
ALTER TABLE "ApiToken" ADD COLUMN     "expiresAt" TIMESTAMP(3);

-- AlterTable
ALTER TABLE "Share" ADD COLUMN     "userId" TEXT;

-- CreateIndex
CREATE INDEX "Share_userId_idx" ON "Share"("userId");

-- AddForeignKey
ALTER TABLE "Share" ADD CONSTRAINT "Share_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
