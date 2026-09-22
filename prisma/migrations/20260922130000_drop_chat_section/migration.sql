-- Удаление раздела «Чат»: таблицы chats, chat_settings, chat_messages, chat_sources.
--
-- Раздел вырезан целиком — и серверный код им больше не пользуется, и клиент его не показывает.
-- DROP, а не оставление «на всякий случай»: пустые таблицы в схеме — это раздел, которого нет в
-- коде, и следующий читатель БД будет искать его серверную реализацию.
--
-- Два внешних ключа тянутся цепочкой: chat_sources -> chat_messages -> chats, chat_settings ->
-- users. Снимаем их явно перед DROP, чтобы миграция одинаково проходила и на чистой копии, и на
-- продеевой БД.
--
-- Прежнюю историю раздела (миграции 20260918140000_ai_chat … 20260920170000_chat_section) не
-- трогаем: они уже применены, переписывать применённую историю нельзя.

-- DropForeignKey
ALTER TABLE "chat_sources" DROP CONSTRAINT IF EXISTS "chat_sources_messageId_fkey";

-- DropForeignKey
ALTER TABLE "chat_messages" DROP CONSTRAINT IF EXISTS "chat_messages_chatId_fkey";

-- DropForeignKey
ALTER TABLE "chat_settings" DROP CONSTRAINT IF EXISTS "chat_settings_userId_fkey";

-- DropForeignKey
ALTER TABLE "chats" DROP CONSTRAINT IF EXISTS "chats_userId_fkey";

-- DropTable
DROP TABLE IF EXISTS "chat_sources";

-- DropTable
DROP TABLE IF EXISTS "chat_messages";

-- DropTable
DROP TABLE IF EXISTS "chat_settings";

-- DropTable
DROP TABLE IF EXISTS "chats";
