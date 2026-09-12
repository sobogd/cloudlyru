-- Пауза конвертации: состояние должно переживать рестарт/pm2 reload и быть одним на все
-- процессы, поэтому живёт в БД. Строка одна (id = 1), её заводит upsert при первом обращении.
CREATE TABLE "QueueState" (
    "id" INTEGER NOT NULL DEFAULT 1,
    "paused" BOOLEAN NOT NULL DEFAULT false,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "QueueState_pkey" PRIMARY KEY ("id")
);
