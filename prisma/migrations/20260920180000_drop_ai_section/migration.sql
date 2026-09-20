-- Удаление прежнего раздела «Чат»: таблицы ai_chats, ai_settings, ai_messages.
--
-- Раздел переписан с нуля (см. миграцию 20260920170000_chat_section). Прежний отвечал по
-- пяти выдержкам из поисковой выдачи, водил телефон через ADB и хранил сжатие контекста
-- непрозрачным блоком провайдера — от него не осталось ни кода, ни настроек, которым он
-- соответствовал бы. Историю переписки перенести нечем: структура другая (источники ответа
-- стали отдельной сущностью), а тексты ответов прежней модели в новом разделе не имеют
-- смысла — они получены другой моделью по другим данным.
--
-- DROP, а не переименование: держать пустые таблицы «на всякий случай» значит оставлять в
-- схеме раздел, которого нет в коде, и путать следующего, кто будет читать БД.
--
-- Порядок важен: сначала таблица сообщений (у неё внешний ключ на чаты), потом чаты,
-- потом настройки.

-- DropForeignKey
ALTER TABLE "ai_messages" DROP CONSTRAINT IF EXISTS "ai_messages_chatId_fkey";

-- DropForeignKey
ALTER TABLE "ai_chats" DROP CONSTRAINT IF EXISTS "ai_chats_userId_fkey";

-- DropForeignKey
ALTER TABLE "ai_settings" DROP CONSTRAINT IF EXISTS "ai_settings_userId_fkey";

-- DropTable
DROP TABLE IF EXISTS "ai_messages";

-- DropTable
DROP TABLE IF EXISTS "ai_chats";

-- DropTable
DROP TABLE IF EXISTS "ai_settings";
