-- Клиент синхронизации может занять имя, занятое его же записью из корзины (replaceTrashed):
-- запись восстанавливается и перезаписывается. Флаг живёт в сессии загрузки, потому что
-- решение принимается на init, а применяется на complete — между ними может пройти час.
ALTER TABLE "UploadSession" ADD COLUMN "replaceTrashed" BOOLEAN NOT NULL DEFAULT false;
