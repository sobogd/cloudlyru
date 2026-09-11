-- Телефоны-исполнители, их состояние (что на телефоне, чего нет в облаке) и команды веба.
CREATE TABLE "Device" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "label" TEXT NOT NULL,
  "lastSeenAt" TIMESTAMP(3),
  "connectedAt" TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "Device_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "Device_userId_label_key" ON "Device"("userId", "label");

CREATE TABLE "DeviceEntry" (
  "id" TEXT NOT NULL,
  "deviceId" TEXT NOT NULL,
  "section" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "isDir" BOOLEAN NOT NULL DEFAULT false,
  "size" BIGINT NOT NULL DEFAULT 0,
  "mtime" TIMESTAMP(3),
  "state" TEXT NOT NULL DEFAULT 'LOCAL',
  "error" TEXT,
  "seenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "DeviceEntry_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "DeviceEntry_deviceId_section_path_key" ON "DeviceEntry"("deviceId", "section", "path");
CREATE INDEX "DeviceEntry_deviceId_idx" ON "DeviceEntry"("deviceId");

CREATE TABLE "DeviceCommand" (
  "id" TEXT NOT NULL,
  "deviceId" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "payload" JSONB,
  "state" TEXT NOT NULL DEFAULT 'pending',
  "error" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "sentAt" TIMESTAMP(3),
  "doneAt" TIMESTAMP(3),
  CONSTRAINT "DeviceCommand_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "DeviceCommand_deviceId_state_idx" ON "DeviceCommand"("deviceId", "state");
