-- Раздел «Заметки»: одна таблица `notes`.
--
-- Заметке не нужен ни заголовок, ни дерево: это текст, приоритет и время последней правки.
-- `priority` — TEXT, а не enum: в схеме проекта enum'ов нет, три значения проверяются в сервисе
-- перед записью. Сортировку списка (высокий → низкий, внутри — свежие сверху) делает сервер,
-- поэтому индекс покрывает именно его выборку «все заметки пользователя».
--
-- `userId` ссылается на `User` (не `users`): основная модель User физического имени не меняет,
-- на `users` отображён отдельный `FacturaUser`.

-- CreateTable
CREATE TABLE "notes" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "text" TEXT NOT NULL,
    "priority" TEXT NOT NULL DEFAULT 'low',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "notes_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "notes_userId_priority_updatedAt_idx" ON "notes"("userId", "priority", "updatedAt");

-- AddForeignKey
ALTER TABLE "notes" ADD CONSTRAINT "notes_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
