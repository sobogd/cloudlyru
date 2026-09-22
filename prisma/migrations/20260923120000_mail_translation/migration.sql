-- Кэш перевода писем на русский (локальная модель на маке, см. src/llm).
--
-- Результат модели не мгновенный, а одно письмо открывают многократно: без этой таблицы каждый
-- показ перевода занимал бы слот движка на маке на десятки секунд. Одна строка на пару
-- «письмо × язык» — уникальность держит БД, а не код, поэтому одновременный перевод с двух
-- устройств не плодит дубликаты.
--
-- `onDelete: Cascade`: перевод не имеет смысла без письма, и безвозвратное удаление письма
-- должно уносить и его.

-- CreateTable
CREATE TABLE "MailTranslation" (
    "id" TEXT NOT NULL,
    "messageId" TEXT NOT NULL,
    "target" TEXT NOT NULL,
    "text" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MailTranslation_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "MailTranslation_messageId_target_key" ON "MailTranslation"("messageId", "target");

-- AddForeignKey
ALTER TABLE "MailTranslation" ADD CONSTRAINT "MailTranslation_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "MailMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE;
