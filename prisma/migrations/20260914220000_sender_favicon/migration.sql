-- Логотип отправителя: favicon домена, вытащенный сервером и закэшированный в БД.
-- bytes = null — у домена favicon нет (или он не картинка); triedAt — последняя попытка,
-- чтобы не дёргать один и тот же домен на каждое письмо.

CREATE TABLE "SenderFavicon" (
    "domain" TEXT NOT NULL,
    "bytes" BYTEA,
    "mime" TEXT,
    "triedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SenderFavicon_pkey" PRIMARY KEY ("domain")
);
