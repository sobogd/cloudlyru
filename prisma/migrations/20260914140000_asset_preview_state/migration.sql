-- Явное состояние превью на ассете вместо masterReadyAt + masterMime.
--
-- Почему: masterReadyAt — timestamp из прежнего пайплайна, где собирался «оптимизированный
-- мастер» (перекодированный полноразмерный оригинал). Мастера нет с коммита 36ccbd7 («оригинал —
-- мастер, генерим только превью»), поэтому поле де-факто значило «производные собраны», а по
-- имени и типу читалось как флаг с непонятным смыслом. masterMime с тех же пор пишется только NULL.
--
-- previewState: 'none' — превью ещё нет (задача ждёт, упала или её ещё не ставили),
--               'done' — собраны, 'impossible' — собрать нельзя, причина в previewError.
-- Состояние живёт на ассете, потому что превью строятся из содержимого, а не из записи в дереве:
-- один и тот же файл у двух пользователей — это один Asset и один набор превью.
--
-- JobStat (замеры скорости) удаляется вместе с показом скорости и остатка времени.

ALTER TABLE "Asset" ADD COLUMN "previewState" TEXT NOT NULL DEFAULT 'none';
ALTER TABLE "Asset" ADD COLUMN "previewError" TEXT;

-- У кого превью уже собраны — сразу готовы.
UPDATE "Asset" SET "previewState" = 'done' WHERE "masterReadyAt" IS NOT NULL;

ALTER TABLE "Asset" DROP COLUMN "masterReadyAt";
ALTER TABLE "Asset" DROP COLUMN "masterMime";

CREATE INDEX "Asset_previewState_idx" ON "Asset"("previewState");

DROP TABLE IF EXISTS "JobStat";

-- Прогресс задачи (0–100) больше не показывается нигде: экран очереди — это остаток, пауза
-- и пересчёт. Вместе с полем уходит и разбор out_time у ffmpeg (UPDATE на каждые 2 с энкода).
ALTER TABLE "Job" DROP COLUMN "progress";

-- Строки задач прежних версий. 'done' больше не существует: готовность превью — это
-- Asset.previewState, и такая строка только мешала бы пересчёту (он считает «есть строка →
-- задача уже есть»). Отменённые задачи — тоже мусор: отмены в очереди больше нет, а строка
-- держала бы файл вне очереди, хотя превью у него так и нет. Кому превью нужны — вернёт
-- кнопка «Пересчитать»; начатые задачи сервис сам возвращает в pending при старте.
DELETE FROM "Job" WHERE "state" NOT IN ('pending', 'processing', 'failed');
DELETE FROM "Job" WHERE "state" = 'failed' AND "error" LIKE 'cancelled%';
