// App Store Connect API: токен и всё, что нужно знать про сертификаты подписи.
//
// Модуль общий для двух скриптов: `asc-certs.mjs` (посмотреть сертификаты аккаунта и убрать
// лишние руками) и `asc-signing-setup.mjs` (разово завести стабильные сертификаты для сборки
// в CI).
// Токен и обёртка запроса живут в одном месте, потому что подпись JWT у Apple капризная
// (ES256 и подпись в формате r||s, а не DER) и второй её копии в репозитории быть не должно.
//
// Ключ (ASC_KEY_ID / ASC_ISSUER_ID) берётся из окружения, сам файл .p8 — из ASC_KEY_FILE
// или из ~/.appstoreconnect/private_keys. Ни ключ, ни его содержимое в вывод не попадают.

import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

const keyId = process.env.ASC_KEY_ID;
const issuerId = process.env.ASC_ISSUER_ID;
if (!keyId || !issuerId) throw new Error('нужны ASC_KEY_ID и ASC_ISSUER_ID');
// В CI ключ кладёт воркфлоу и путь передаёт через ASC_KEY_FILE; локально он лежит там, куда
// его складывает сам Xcode, — тогда ASC_KEY_ID достаточно, чтобы найти файл.
const keyPath =
  process.env.ASC_KEY_FILE || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`);
const privateKey = readFileSync(keyPath, 'utf8');

/** base64url — так JWT и передаётся, обычный base64 Apple не принимает. */
const b64url = (value) =>
  Buffer.from(value).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/**
 * Токен App Store Connect: подпись ES256 ключом .p8, ключ в подписи участвует как есть.
 * Срок — 20 минут (предел, который принимает Apple), для одного запуска скрипта хватает.
 */
function makeToken() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const payload = b64url(
    JSON.stringify({ iss: issuerId, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }),
  );
  const signer = createSign('SHA256');
  signer.update(`${header}.${payload}`);
  // dsaEncoding: JWS ждёт подпись в формате r||s, а Node по умолчанию отдаёт DER.
  return `${header}.${payload}.${b64url(signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }))}`;
}

const token = makeToken();

/**
 * Запрос к API Apple. Тело ошибки попадает в исключение целиком: по нему и разбираются
 * проблемы (нет прав у ключа, выбран лимит сертификатов, не тот сертификат в профиле).
 *
 * @param {'GET'|'POST'|'DELETE'} method HTTP-метод.
 * @param {string} path путь с ведущим «/», например `/v1/certificates?limit=200`.
 * @param {object} [body] тело запроса для POST — как есть, без обёрток.
 * @returns {Promise<any>} разобранный JSON ответа или null, если тела нет.
 */
async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : null;
}

/** Все сертификаты аккаунта: id, тип, имя, срок и последние 8 знаков серийного номера. */
export async function certificates() {
  const out = await api('GET', '/v1/certificates?limit=200');
  return (out.data || []).map((c) => ({
    id: c.id,
    type: c.attributes.certificateType,
    name: c.attributes.name,
    expires: (c.attributes.expirationDate || '').slice(0, 10),
    serial: (c.attributes.serialNumber || '').slice(-8),
  }));
}

/**
 * Выпускает сертификат по CSR. Тип задаётся вызывающим: у Apple под Ad Hoc нужен
 * `DISTRIBUTION` («Apple Distribution»), у старых аккаунтов тот же смысл у `IOS_DISTRIBUTION`.
 *
 * @param {string} certificateType значение из перечисления Apple.
 * @param {string} csrContent CSR в PEM (текстом, не base64).
 * @returns {Promise<{id: string, name: string, serial: string, expires: string, content: string}>}
 *   id и подписанный сертификат; `content` — base64 от DER-сертификата.
 */
export async function createCertificate(certificateType, csrContent) {
  const out = await api('POST', '/v1/certificates', {
    data: { type: 'certificates', attributes: { certificateType, csrContent } },
  });
  const a = out.data.attributes;
  return {
    id: out.data.id,
    name: a.name,
    serial: (a.serialNumber || '').slice(-8),
    expires: (a.expirationDate || '').slice(0, 10),
    content: a.certificateContent,
  };
}

/**
 * Отзывает (удаляет) сертификат по id: у Apple это одна операция, и вместе с сертификатом
 * Apple помечает отозванными все профили, которые на нём висели.
 *
 * @param {string} id идентификатор сертификата в App Store Connect.
 */
export async function deleteCertificate(id) {
  await api('DELETE', `/v1/certificates/${id}`);
}
