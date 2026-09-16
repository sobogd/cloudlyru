-- Догоняющая чистка копий у провайдера (MailPurgeService) идёт каждые 5 минут по каждому
-- включённому аккаунту: отбор по accountId + remoteDeletedAt IS NULL, сортировка по createdAt.
-- Индекса под эту выборку не было, поэтому каждый проход — полный обход растущей таблицы
-- писем с сортировкой. Индекс частичный (в схеме Prisma не выражается, как и уникальный
-- частичный по gmailMsgId из 20260914150000_mail_foundation).
CREATE INDEX "MailMessage_accountId_createdAt_pending_idx"
  ON "MailMessage" ("accountId", "createdAt")
  WHERE "remoteDeletedAt" IS NULL;

-- Корзина ленты писем: отбор по пользователю и порядок по deletedAt. Индекс ленты
-- (userId, box, sortAt DESC, id DESC) этот запрос не покрывает, а deletedAt в одиночку
-- не селективен.
CREATE INDEX "MailMessage_userId_deletedAt_idx" ON "MailMessage"("userId", "deletedAt");
