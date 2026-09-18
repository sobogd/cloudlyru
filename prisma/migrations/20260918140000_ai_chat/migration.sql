-- Чат с моделью ИИ: диалоги и сообщения.
--
-- Зачем это в БД, а не в приложении. Раньше (первый заход) клиент ходил в xAI напрямую,
-- а ключ вшивался в сборку значением --dart-define. Из этого вышло три беды: ключ лежал
-- в APK, который скачивают с публичной ссылки; в отладке не было видно ничего, кроме
-- «не работает» на экране; история переписки не переживала закрытие приложения.
-- Теперь запрос к модели делает сервер своим ключом (GROK_API_KEY в его окружении),
-- логирует каждый запрос и ответ провайдера, а переписка лежит здесь — и одна на все
-- устройства владельца.
--
-- `ai_chats.title` заполняется из первого вопроса (как в приложениях ChatGPT/Gemini):
-- своей темы у модели не спрашивают, а список из «Новый чат» бесполезен.
-- `ai_messages.reasoning` — «размышления» reasoning-моделей отдельным полем: на экране они
-- показываются отдельным блоком, а в контекст следующего запроса не отправляются.
-- `promptTokens`/`completionTokens` — расход на ответ: цена ошибки тут деньги.

-- CreateTable
CREATE TABLE "ai_chats" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "title" TEXT NOT NULL DEFAULT 'Новый чат',
    "model" TEXT NOT NULL DEFAULT 'grok-4.6',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ai_chats_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ai_messages" (
    "id" TEXT NOT NULL,
    "chatId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "content" TEXT NOT NULL,
    "reasoning" TEXT NOT NULL DEFAULT '',
    "promptTokens" INTEGER,
    "completionTokens" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ai_messages_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "ai_chats_userId_updatedAt_idx" ON "ai_chats"("userId", "updatedAt");

-- CreateIndex
CREATE INDEX "ai_messages_chatId_createdAt_idx" ON "ai_messages"("chatId", "createdAt");

-- AddForeignKey
ALTER TABLE "ai_chats" ADD CONSTRAINT "ai_chats_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ai_messages" ADD CONSTRAINT "ai_messages_chatId_fkey" FOREIGN KEY ("chatId") REFERENCES "ai_chats"("id") ON DELETE CASCADE ON UPDATE CASCADE;
