-- Два индекса, без которых раздел «Фото» упирается в размер библиотеки.
--
-- 1. FileEntry(assetId, deletedAt) — для проверки «это мой файл» (AuthService.ownsAsset).
--    Она ищет живые записи по assetId, а индекса на этой колонке не было вовсе: на 100k
--    записей Postgres читал всю таблицу (8-28 мс на замер), и это происходило на КАЖДУЮ
--    отдачу превью, то есть сотни раз на одну прокрутку галереи. С индексом — 0.06 мс.
--    Тот же индекс нужен ленте: по нему идёт соединение Asset → FileEntry.
--
-- 2. MediaMeta(capturedAt DESC NULLS LAST) — порядок самой ленты (записи без даты съёмки
--    идут в конец). Обычный btree(capturedAt) для этого не годится: обратное сканирование
--    ASC-индекса даёт DESC NULLS FIRST — другой порядок, — и Postgres уходит в сортировку
--    всех медиа пользователя (на 100k это внешняя сортировка на диск, ~90 мс на страницу
--    вместо 2.6 мс). Порядок NULLS в Prisma-схеме не выражается, поэтому индекс только тут;
--    в schema.prisma у FileEntry есть парный @@index, а этот осознанно оставлен в миграции.
CREATE INDEX "FileEntry_assetId_deletedAt_idx" ON "FileEntry" ("assetId", "deletedAt");
CREATE INDEX "MediaMeta_capturedAt_idx" ON "MediaMeta" ("capturedAt" DESC NULLS LAST);
