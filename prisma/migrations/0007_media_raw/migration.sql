-- Подробные метаданные медиа для деталки: полный набор извлечённых тегов
-- (EXIF фото / ffprobe видео) в виде JSON; индексируемые поля уже есть.
ALTER TABLE "MediaMeta" ADD COLUMN "raw" JSONB;
