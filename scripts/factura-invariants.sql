-- Приёмка переноса фактур: слепок данных, который снимается ДО переноса с базы `iq_factura`
-- и ПОСЛЕ — с базы `cloudly`, и сравнивается построчно (`diff`). Совпал — данные переехали
-- один в один; не совпал — видно, какая именно таблица разошлась.
--
--   psql -q -d cloudly -f scripts/factura-invariants.sql > /tmp/after.txt
--   ssh root@<сервер> "sudo -u postgres psql -q -d iq_factura -f -" < scripts/factura-invariants.sql > /tmp/before.txt
--   diff /tmp/before.txt /tmp/after.txt
--
-- Колонки в контрольной сумме перечислены ПО АЛФАВИТУ и в фиксированном порядке: в источнике
-- физический порядок колонок другой (их добавляли миграциями), поэтому `t::text` дал бы
-- ложное расхождение. Время приводится к UTC, иначе строки с timestamp сравнивались бы
-- в разных зонах. Идентификаторы строк (cuid) переносятся как есть, поэтому сортировка по id
-- на обеих сторонах даёт одинаковый порядок.
--
-- Ожидаемые значения на момент переноса (2026-09): 71 фактура, 24 записи VeriFactu (все
-- ACCEPTED, последняя #24, хеш начинается на E6116A90), максимальный serialIndex 2026 — 49
-- (следующая фактура обязана получить FACT-2026-00050), у компании cmpv0jfi9… загружен
-- сертификат (cipher 4383 симв., nonce 12 Б, tag 16 Б, срок 2028-07-16).

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
set time zone 'UTC';

-- 1. Сколько строк и та же ли это строка-в-строку (по таблицам)
select 'users|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "createdAt", email, id, otp, "otpAttempts", "otpExpiresAt", "pendingCompanyName", "pendingTaxId", "preferredLocale", "sessionToken", "updatedAt"), E'\n' order by id)), '-') from "users";
select 'sessions|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "createdAt", "expiresAt", id, ip, "tokenHash", "userAgent", "userId"), E'\n' order by id)), '-') from "sessions";
select 'users_companies|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "companyId", "createdAt", id, role, "userId"), E'\n' order by id)), '-') from "users_companies";
select 'companies|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "activityStartDate", "activityType", "addressLine1", "addressLine2", "bankName", "baseCurrency", city, country, "createdAt", "defaultIrpfRate", iban, id, "invoiceNumberOffset", "legalName", name, "onboardingStep", "postalCode", region, swift, "taxId", "updatedAt", "vatId", "verifactuCertCipher", "verifactuCertExpiry", "verifactuCertIssuer", "verifactuCertNif", "verifactuCertNonce", "verifactuCertSubject", "verifactuCertTag"), E'\n' order by id)), '-') from "companies";
select 'bank_accounts|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "archivedAt", "bankName", "companyId", "createdAt", currency, iban, id, "isDefault", label, swift, "updatedAt"), E'\n' order by id)), '-') from "bank_accounts";
select 'contacts|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "addressLine1", "addressLine2", "archivedAt", city, "companyId", "countryCode", "createdAt", currency, email, "esNoIva", id, "isEu", name, nature, notes, "postalCode", region, "taxId", "updatedAt"), E'\n' order by id)), '-') from "contacts";
select 'invoices|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "bankAccountId", "companyId", "contactId", "contactSnapshot", "createdAt", currency, description, "dueDate", "emitterSnapshot", "fxRate", "fxRateDate", id, "irpfAmount", "irpfRate", "issueDate", language, "legalNoteCode", nature, "netAmount", "netAmountEur", notes, number, paid, "paidAt", "paymentMethod", "pdfGeneratedAt", "pdfS3Key", "pdfSha256", "serialIndex", "serialYear", series, status, "toPayAmount", "totalAmount", "totalAmountEur", "updatedAt", "vatAmount", "vatAmountEur", "vatRate"), E'\n' order by id)), '-') from "invoices";
select 'invoice_lines|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', description, id, "invoiceId", quantity, "sortOrder", total, "totalEur", unit, "unitPrice"), E'\n' order by id)), '-') from "invoice_lines";
select 'invoice_events|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "companyId", "createdAt", id, "invoiceId", outcome, payload, summary, type), E'\n' order by id)), '-') from "invoice_events";
select 'expenses|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', category, "companyId", "createdAt", currency, "deductibleForIrpf", "deductibleVatPct", description, "fileMime", "fileName", "fileS3Key", "fxRate", "fxRateDate", id, "irpfAmount", "irpfRate", "issueDate", kind, nature, "netAmount", "netAmountEur", notes, "reverseCharge", "supplierCountryCode", "supplierEsNoIva", "supplierIsEu", "supplierName", "supplierTaxId", "totalAmount", "totalAmountEur", "updatedAt", "vatAmount", "vatAmountEur", "vatRate"), E'\n' order by id)), '-') from "expenses";
select 'filed_declarations|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', casillas, "companyId", "compensarNext", "createdAt", "fileMime", "fileName", "fileS3Key", id, justificante, model, notes, quarter, "resultPaid", "submittedAt", "updatedAt", year), E'\n' order by id)), '-') from "filed_declarations";
select 'support_messages|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "companyId", "createdAt", id, "isAdmin", message, "userId"), E'\n' order by id)), '-') from "support_messages";
select 'verifactu_registries|' || count(*) || '|' || coalesce(md5(string_agg(concat_ws('|', "aeatResponseCode", "aeatResponseRaw", "aeatRetryCount", "aeatStatus", "aeatSubmittedAt", "companyId", "currentHash", "hashInput", id, "invoiceId", "previousHash", "qrUrl", "sequenceNumber", "signedAt", "tipoFactura"), E'\n' order by id)), '-') from "verifactu_registries";

-- 2. Нумерация: продолжение серии по годам (max serialIndex + 1 = следующий номер)
select 'numbering|' || "companyId" || '|' || "serialYear" || '|' || coalesce(max("serialIndex")::text, 'null') || '|' || count(*)
from invoices group by "companyId", "serialYear" order by "serialYear";

-- 3. Статусы фактур и наличие PDF (сам файл лежит в S3 под pdfS3Key и не перегенерируется)
select 'invoices_status|' || status || '|' || count(*) from invoices group by status order by 1;
select 'invoices_pdf|with_key=' || count("pdfS3Key") || '|without_key=' || (count(*) - count("pdfS3Key")) from invoices;

-- 4. Хеш-цепочка VeriFactu: длина, последняя запись и её хеш (по нему следующая запись
--    проверит previousHash), плюс распределение статусов отправки в AEAT
select 'verifactu_status|' || "aeatStatus" || '|' || count(*) from verifactu_registries group by "aeatStatus" order by 1;
select 'verifactu_last|' || "companyId" || '|' || max("sequenceNumber") || '|' ||
       (array_agg("currentHash" order by "sequenceNumber" desc))[1] || '|' ||
       (array_agg("previousHash" order by "sequenceNumber" desc))[1]
from verifactu_registries group by "companyId" order by 1;

-- 5. Сертификат: метаданные и длины полей шифротекста (ключ AES-256-GCM — nonce 12 Б, tag 16 Б).
--    Сам шифротекст не печатаем: он расшифровывается только с VERIFACTU_MASTER_KEY, и проверять
--    его надо не глазами, а попыткой расшифровки сервисом после переноса.
select 'cert|' || id || '|' || coalesce("verifactuCertNif", '-') || '|' || coalesce("verifactuCertExpiry"::text, '-') || '|' ||
       coalesce(length("verifactuCertCipher")::text, '0') || '|' || coalesce(length("verifactuCertNonce")::text, '0') || '|' ||
       coalesce(length("verifactuCertTag")::text, '0')
from companies where "verifactuCertCipher" is not null order by id;

-- 6. Вложения в S3 (сканы расходов и поданных деклараций): сколько ключей и сколько строк без них
select 'docs|expenses=' || count("fileS3Key") || '/' || count(*) from expenses;
select 'docs|filed_declarations=' || count("fileS3Key") || '/' || count(*) from filed_declarations;

-- 7. Суммы: подписи, что Decimal не потерял точность при переносе
select 'totals|invoices=' || coalesce(sum("totalAmount")::text, '0') || '|expenses=' ||
       (select coalesce(sum("totalAmount")::text, '0') from expenses) from invoices;
