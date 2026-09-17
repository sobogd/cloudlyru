-- Кто вошёл: чтобы список сеансов в приложении был читаемым, а не «сеанс №5».
-- Колонки пустые у сессий, созданных до этой правки: показать про них нечего.
ALTER TABLE "Session" ADD COLUMN "client" TEXT;
ALTER TABLE "Session" ADD COLUMN "ip" TEXT;
ALTER TABLE "Session" ADD COLUMN "userAgent" TEXT;
