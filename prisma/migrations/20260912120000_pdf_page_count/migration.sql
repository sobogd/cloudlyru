-- Превью PDF: страницы рендерятся сервером в производные view/<sha>-p<N>-1080.webp,
-- и без числа страниц их не перечислить при удалении файла (trash purge, hard delete).
ALTER TABLE "Asset" ADD COLUMN "pageCount" INTEGER;
