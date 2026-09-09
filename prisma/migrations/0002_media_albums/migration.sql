-- CreateTable M2: медиа-метаданные (EXIF) и альбомы

CREATE TABLE "MediaMeta" (
    "id" TEXT NOT NULL,
    "assetId" TEXT NOT NULL,
    "capturedAt" TIMESTAMP(3),
    "latitude" DOUBLE PRECISION,
    "longitude" DOUBLE PRECISION,
    "make" TEXT,
    "model" TEXT,
    "width" INTEGER,
    "height" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MediaMeta_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Album" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Album_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "AlbumItem" (
    "id" TEXT NOT NULL,
    "albumId" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AlbumItem_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "MediaMeta_assetId_key" ON "MediaMeta"("assetId");

CREATE INDEX "Album_userId_idx" ON "Album"("userId");

CREATE UNIQUE INDEX "AlbumItem_albumId_entryId_key" ON "AlbumItem"("albumId", "entryId");

-- AddForeignKey
ALTER TABLE "MediaMeta" ADD CONSTRAINT "MediaMeta_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "Asset"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AlbumItem" ADD CONSTRAINT "AlbumItem_albumId_fkey" FOREIGN KEY ("albumId") REFERENCES "Album"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AlbumItem" ADD CONSTRAINT "AlbumItem_entryId_fkey" FOREIGN KEY ("entryId") REFERENCES "FileEntry"("id") ON DELETE CASCADE ON UPDATE CASCADE;
