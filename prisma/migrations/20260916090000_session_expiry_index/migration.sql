-- Уборка протухших сессий (AuthService.pruneExpiredSessions) выбирает и удаляет строки
-- по expiresAt. Индекса не было вовсе, то есть каждый проход уборки читал таблицу сессий
-- целиком; сессии же живут до 30 дней и накапливаются с каждым входом.
CREATE INDEX "Session_expiresAt_idx" ON "Session"("expiresAt");
