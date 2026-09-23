#!/usr/bin/env node
//
// Сертификаты подписи в аккаунте Apple: посмотреть, что там есть, и убрать лишнее руками.
//
// Зачем. Сборка iOS идёт через `-allowProvisioningUpdates` (см. scripts/build-ios.sh), и
// раньше на одноразовом раннере не было ни одного сертификата: Xcode выпускал себе новые
// на каждый прогон (в имени таких сертификатов Apple пишет «Created via API»), аккаунт
// упирался в лимит, и сборка падала с «Your account has reached the maximum number of
// certificates» ещё до компиляции. Сейчас сертификаты стабильные, их разово выпускает
// scripts/asc-signing-setup.mjs, и растут они только когда истекают (раз в год).
//
// Автоматической чистки здесь больше нет намеренно: у стабильного CI-сертификата Apple
// составляет ровно такое же имя — «Apple Development: Created via API», — и правило «сноси
// всё с этой припиской» снесло бы его. Поэтому мусор убирается осознанно: `list` показывает
// аккаунт, `revoke <id>` отзывает конкретный сертификат.
//
// Что НЕ трогает `revoke`: ничего — он делает ровно то, о чём его просят. А вот профили
// сборок, опубликованных на этом сертификате, Apple отзывает вместе с ним, поэтому сертификат,
// которым подписаны живые сборки, отзывать не надо: свои сертификаты отзывают те, у кого
// утекли ключи, а истёкшие уходят сами.
//
// Запуск (значения ключа и ID берутся из окружения, на экран и в логи не попадают):
//   node --env-file=$HOME/work/.env scripts/asc-certs.mjs list
//   node --env-file=$HOME/work/.env scripts/asc-certs.mjs revoke <id> [<id>…]
// В CI ключ лежит файлом ($ASC_KEY_FILE), а ASC_KEY_ID / ASC_ISSUER_ID приходят секретами.
import { certificates, deleteCertificate } from './asc-api.mjs';

/** Печатает таблицу сертификатов по типам — то, что нужно глазами, без ключей и CSR. */
async function list() {
  const certs = await certificates();
  console.table(certs);
  const byType = {};
  for (const c of certs) byType[c.type] = (byType[c.type] || 0) + 1;
  console.log('итого по типам:', byType);
}

/** Отзывает сертификаты по id: вместе с сертификатом Apple помечает отозванными его профили. */
async function revoke(ids) {
  if (ids.length === 0) throw new Error('revoke: нужен хотя бы один id сертификата');
  for (const id of ids) {
    await deleteCertificate(id);
    console.log(`отозван ${id}`);
  }
}

const command = process.argv[2] || 'list';
if (command === 'list') await list();
else if (command === 'revoke') await revoke(process.argv.slice(3));
else throw new Error(`неизвестная команда: ${command} (list | revoke <id>…)`);
