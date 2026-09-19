-- Память владельца вместо режимов ответа.
--
-- Режимов (обычный / кейвман / хуманайзер) больше нет: манера речи одна и включена всегда —
-- коротко, по-человечески, без воды и штампов. Выбор из трёх режимов оказался лишним шагом:
-- нужен был не выбор, а одно поведение по умолчанию. Поэтому колонка `ai_chats.style` уходит,
-- а её место занимает `ai_settings.memory` — свободный текст владельца о себе («живу в
-- Испании», «пиши без вступлений», «мой стек — Flutter и NestJS»), который подмешивается в
-- системную часть каждого запроса.
--
-- Память хранится отдельной таблицей со строкой на пользователя, а не полем в `User`: это
-- состояние раздела «Чат», и в общем профиле ему места нет.

-- AlterTable
ALTER TABLE "ai_chats" DROP COLUMN "style";

-- CreateTable
CREATE TABLE "ai_settings" (
    "userId" TEXT NOT NULL,
    "memory" TEXT NOT NULL DEFAULT '',
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ai_settings_pkey" PRIMARY KEY ("userId")
);

-- AddForeignKey
ALTER TABLE "ai_settings" ADD CONSTRAINT "ai_settings_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
