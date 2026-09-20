-- Раздел «Чат»: таблицы нового раздела (chats, chat_settings, chat_messages, chat_sources).
--
-- Почему новый набор таблиц, а не правка прежних `ai_*`. Прежний раздел ходил в модель с
-- поиском по сниппетам и с агентом на телефоне (ADB на маке); этот переписан с нуля: источники
-- ответа стали отдельной сущностью со своими адресами и номерами, а сжатие контекста —
-- собственным полем вместо непрозрачного блока провайдера, который читала только его сторона.
-- Старые таблицы удаляются вместе с прежним кодом отдельной миграцией, чтобы этот переезд
-- можно было откатить, не теряя историю.
--
-- `chat_sources` — источники ответа: адрес, заголовок, сниппет выдачи и число символов, реально
-- ушедших модели. Полного текста страниц здесь нет намеренно: это мегабайты на каждый ответ,
-- а нужен он только в момент генерации. `position` — номер упоминания в тексте (`[1]`), по нему
-- приложение и делает ссылку.
--
-- `chats.summary` / `chats.summarizedUpToAt` — сжатие длинного разговора в пересказ: каждый
-- ответ пересылает историю заново, а префилл на домашнем маке идёт медленно.

-- CreateTable
CREATE TABLE "chats" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "title" TEXT NOT NULL DEFAULT 'Новый чат',
    "model" TEXT NOT NULL DEFAULT 'qwen/qwen3.5-9b',
    "summary" TEXT,
    "summarizedUpToAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "chats_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "chat_settings" (
    "userId" TEXT NOT NULL,
    "memory" TEXT NOT NULL DEFAULT '',
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "chat_settings_pkey" PRIMARY KEY ("userId")
);

-- CreateTable
CREATE TABLE "chat_messages" (
    "id" TEXT NOT NULL,
    "chatId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "content" TEXT NOT NULL,
    "reasoning" TEXT NOT NULL DEFAULT '',
    "searchQuery" TEXT,
    "promptTokens" INTEGER,
    "completionTokens" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "chat_sources" (
    "id" TEXT NOT NULL,
    "messageId" TEXT NOT NULL,
    "position" INTEGER NOT NULL,
    "title" TEXT NOT NULL DEFAULT '',
    "url" TEXT NOT NULL,
    "snippet" TEXT NOT NULL DEFAULT '',
    "read" BOOLEAN NOT NULL DEFAULT false,
    "chars" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "chat_sources_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "chats_userId_updatedAt_idx" ON "chats"("userId", "updatedAt");

-- CreateIndex
CREATE INDEX "chat_messages_chatId_createdAt_idx" ON "chat_messages"("chatId", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "chat_sources_messageId_position_key" ON "chat_sources"("messageId", "position");

-- AddForeignKey
ALTER TABLE "chats" ADD CONSTRAINT "chats_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "chat_settings" ADD CONSTRAINT "chat_settings_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "chat_messages" ADD CONSTRAINT "chat_messages_chatId_fkey" FOREIGN KEY ("chatId") REFERENCES "chats"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "chat_sources" ADD CONSTRAINT "chat_sources_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "chat_messages"("id") ON DELETE CASCADE ON UPDATE CASCADE;
