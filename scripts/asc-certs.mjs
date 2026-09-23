#!/usr/bin/env node
//
// Сертификаты подписи в аккаунте Apple: посмотреть, что там есть, и убрать мусор.
//
// Зачем. Сборка iOS идёт через `-allowProvisioningUpdates` (см. scripts/build-ios.sh): Xcode
// сам выпускает себе сертификат и профиль. На раннере GitHub, который живёт один прогон,
// сделать это можно только «с нуля» — поэтому каждый прогон оставляет в аккаунте свежий
// development-сертификат имени «Apple Development: Created via API», и со временем аккаунт
// упирается в лимит Apple: xcodebuild падает с «Your account has reached the maximum number
// of certificates» ещё до сборки, а руками это чинится в кабинете разработчика.
// Отсюда `cleanup` — им ios.yml подчищает хвосты прошлых прогонов до сборки.
//
// Что НЕ трогается: сертификаты, заведённые человеком и машинами разработки. У них имя
// содержит Apple ID («Apple Development: Bogdan Sokolov»), а не приписку «Created via API»,
// и именно им подписываются локальные сборки — чистка их не видит. Сертификаты других типов
// (Apple Distribution и прочие) тоже не трогаются: их выпускает не раннер, и профили на них
// висят у уже установленных сборок.
//
// Запуск (значения ключа и ID берутся из окружения, на экран и в логи не попадают):
//   node --env-file=$HOME/work/.env scripts/asc-certs.mjs list
//   node --env-file=$HOME/work/.env scripts/asc-certs.mjs cleanup
//   node --env-file=$HOME/work/.env scripts/asc-certs.mjs revoke <id> [<id>…]
// В CI ключ уже лежит файлом ($ASC_KEY_FILE), а ASC_KEY_ID / ASC_ISSUER_ID приходят секретами.
import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Приписка в имени, по которой видно сертификат, выпущенный сборщиком на одноразовом раннере. */
const RUNNER_CERT_MARK = 'Created via API';

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

/** Запрос к API Apple: тело ошибки попадает в исключение целиком — по нему и разбираем проблемы. */
async function api(method, path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : null;
}

/** Все сертификаты аккаунта: id, тип, имя, срок и последние 8 знаков серийного номера. */
async function certificates() {
  const out = await api('GET', '/v1/certificates?limit=200');
  return (out.data || []).map((c) => ({
    id: c.id,
    type: c.attributes.certificateType,
    name: c.attributes.name,
    expires: (c.attributes.expirationDate || '').slice(0, 10),
    serial: (c.attributes.serialNumber || '').slice(-8),
  }));
}

/** Печатает таблицу сертификатов по типам — то, что нужно глазами, без ключей и CSR. */
async function list() {
  const certs = await certificates();
  console.table(certs);
  const byType = {};
  for (const c of certs) byType[c.type] = (byType[c.type] || 0) + 1;
  console.log('итого по типам:', byType);
}

/**
 * Отзывает сертификаты, оставшиеся от прошлых прогонов сборки на одноразовых раннерах:
 * development-сертификаты с припиской «Created via API». Сертификаты, заведённые руками
 * или машиной разработки (в имени Apple ID), и всё, что не DEVELOPMENT, остаётся на месте.
 * Возвращает число отозванных — по нему воркфлоу видно, была ли чистка не пустой.
 */
async function cleanup() {
  const certs = await certificates();
  const junk = certs.filter((c) => c.type === 'DEVELOPMENT' && c.name.includes(RUNNER_CERT_MARK));
  if (junk.length === 0) {
    console.log('хвостов от прошлых прогонов нет — чистить нечего');
    return 0;
  }
  for (const cert of junk) {
    await api('DELETE', `/v1/certificates/${cert.id}`);
    console.log(`отозван ${cert.id} (${cert.name}, серийный …${cert.serial}, истекал ${cert.expires})`);
  }
  console.log(`отозвано ${junk.length}, осталось сертификатов: ${certs.length - junk.length}`);
  return junk.length;
}

/** Ручной отзыв по id: нужен, когда мусор не подходит под правило чистки. */
async function revoke(ids) {
  if (ids.length === 0) throw new Error('revoke: нужен хотя бы один id сертификата');
  for (const id of ids) {
    await api('DELETE', `/v1/certificates/${id}`);
    console.log(`отозван ${id}`);
  }
}

const command = process.argv[2] || 'list';
if (command === 'list') await list();
else if (command === 'cleanup') await cleanup();
else if (command === 'revoke') await revoke(process.argv.slice(3));
else throw new Error(`неизвестная команда: ${command} (list | cleanup | revoke <id>…)`);
