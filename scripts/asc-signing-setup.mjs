#!/usr/bin/env node
//
// Стабильные сертификаты подписи для сборки iOS в CI: разово выпустить, упаковать в один .p12
// и положить в секреты GitHub — и больше к подписи не возвращаться.
//
// Зачем. Раньше на одноразовом раннере не было ни одного сертификата, и Xcode под
// автоматической подписью выпускал себе новые на каждый прогон: архив он подписывает
// development-личностью, экспорт Ad Hoc — distribution-личностью. Аккаунт упирался в лимит
// Apple, воркфлоу перед сборкой чистил хвосты прошлых прогонов — и каждая сборка отзывала
// сертификаты предыдущей, о чём Apple присылала письмо. С готовыми личностями в связке ключей
// Xcode ничего не выпускает: профиль Ad Hoc он по-прежнему собирает и обновляет сам, а
// сертификаты остаются те же.
//
// Что делает скрипт (всё в одном каталоге, по умолчанию ~/cloudly-ios-signing):
//   ci-dev.key / ci-dev.csr / ci-dev.pem   — development: ключ, запрос и сертификат Apple Development;
//   ci-dist.key / ci-dist.csr / ci-dist.pem — distribution: ключ, запрос и Apple Distribution;
//   signing.pem                             — обе пары «ключ + сертификат» одним файлом; в секреты
//                                             уходит именно он: CI импортирует его в связку ключей;
//   certs.json                              — id, имя и срок обоих сертификатов в App Store Connect.
// Каталог создаётся с правами 700, ключи и бандл — 600: секреты остаются на машине и уезжают
// только в секреты GitHub (команду скрипт печатает, значения не печатает).
//
// Запуск:
//   node --env-file=$HOME/work/.env scripts/asc-signing-setup.mjs             # выпустить или обновить
//   node --env-file=$HOME/work/.env scripts/asc-signing-setup.mjs --new-cert  # выпустить новые
//   SIGNING_DIR=/другой/каталог node --env-file=$HOME/work/.env scripts/asc-signing-setup.mjs
//
// Когда перезапускать: сертификаты живут год — когда истекут, `--new-cert` выпустит новые
// (старые истекут сами, отзывать их не нужно), после этого надо обновить секрет. Если
// сертификаты отозвали руками, обычный запуск это заметит и выпустит новые.
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { certificates, createCertificate } from './asc-api.mjs';
/**
 * Какие сертификаты нужны сборке: у каждого своя роль, оба обязательны.
 * DEVELOPMENT — им Xcode подписывает архив, DISTRIBUTION — им уезжает Ad Hoc .ipa.
 * Типов на выбор по два: у Apple это современные DEVELOPMENT/DISTRIBUTION, у аккаунтов
 * постарше — IOS_DEVELOPMENT/IOS_DISTRIBUTION; берём первый, который примет аккаунт.
 */
const CERT_KINDS = [
  { role: 'development', types: ['DEVELOPMENT', 'IOS_DEVELOPMENT'] },
  { role: 'distribution', types: ['DISTRIBUTION', 'IOS_DISTRIBUTION'] },
];
/**
 * openssl нужен только для ключей и запросов на сертификат. Именно системный
 * (/usr/bin/openssl, LibreSSL): он есть на любом маке, а Homebrew-OpenSSL выкидывает
 * лишние поля из subject, которые Apple готов принять, но видеть в кабинете не хочется.
 * Абсолютный путь страхует от того, что в PATH стоит что-то другое.
 */
const OPENSSL = process.env.OPENSSL_BIN || (existsSync('/usr/bin/openssl') ? '/usr/bin/openssl' : 'openssl');

const newCert = process.argv.slice(2).includes('--new-cert');
const dir = resolve(process.env.SIGNING_DIR || join(homedir(), 'cloudly-ios-signing'));

/** Путь внутри каталога подписи: все файлы складываются только туда. */
const file = (name) => join(dir, name);

/**
 * Запускает openssl и возвращает его вывод. Ошибки падают наружу вместе с текстом —
 * по нему видно, что именно не устроило openssl (формат, отсутствующий файл).
 *
 * @param {string[]} argv аргументы без имени программы.
 * @returns {string} stdout команды.
 */
function openssl(argv) {
  return execFileSync(OPENSSL, argv, { encoding: 'utf8' });
}

/** Читает json из каталога подписи или null, если файла нет. */
function readJson(name) {
  return existsSync(file(name)) ? JSON.parse(readFileSync(file(name), 'utf8')) : null;
}

/**
 * Выпускает один сертификат нужной роли и кладёт рядом с ключом сам сертификат в PEM.
 * Subject Apple не проверяет (сертификат подписывается на их стороне), важна только
 * корректность запроса; OU с Team ID оставляем для читаемости в кабинете.
 *
 * @param {{role: string, types: string[]}} kind что за сертификат нужен.
 * @returns {Promise<{id: string, name: string, serial: string, expires: string}>} данные сертификата.
 */
async function issueCertificate(kind) {
  const keyPath = file(`ci-${kind.role}.key`);
  openssl(['genrsa', '-out', keyPath, '2048']);
  chmodSync(keyPath, 0o600);
  const subject = `/CN=Cloudly CI/${kind.role}${process.env.APPLE_TEAM_ID ? `/OU=${process.env.APPLE_TEAM_ID}` : ''}/C=DE`;
  openssl(['req', '-new', '-key', keyPath, '-out', file(`ci-${kind.role}.csr`), '-subj', subject]);

  const csr = readFileSync(file(`ci-${kind.role}.csr`), 'utf8');
  let created = null;
  let lastError = null;
  for (const type of kind.types) {
    try {
      created = await createCertificate(type, csr);
      console.log(`выпущен ${created.name} (${kind.role}, тип ${type}): серийный …${created.serial}, истекает ${created.expires}`);
      break;
    } catch (e) {
      lastError = e;
      console.log(`тип ${type} не принят, пробую следующий: ${String(e.message).slice(0, 200)}`);
    }
  }
  if (!created) throw lastError;

  // API отдаёт сертификат в DER, а openssl и .p12 работают с PEM: переводим и убираем DER.
  writeFileSync(file(`ci-${kind.role}.der`), Buffer.from(created.content, 'base64'));
  openssl(['x509', '-inform', 'DER', '-in', file(`ci-${kind.role}.der`), '-out', file(`ci-${kind.role}.pem`)]);
  rmSync(file(`ci-${kind.role}.der`), { force: true });
  return { id: created.id, name: created.name, serial: created.serial, expires: created.expires };
}

/**
 * Собирает один PEM-бандл со всеми парами «ключ + сертификат». В связку ключей macOS такой
 * файл импортируется одной командой и даёт сразу все личности — ни .p12, ни пароля к нему
 * не нужно (пароль пришлось бы класть рядом отдельным секретом и он ничего бы не добавил).
 *
 * @param {Array<{role: string}>} kinds роли, для которых уже есть файлы.
 */
function packBundle(kinds) {
  const bundle = kinds
    .map((kind) =>
      [readFileSync(file(`ci-${kind.role}.pem`), 'utf8'), readFileSync(file(`ci-${kind.role}.key`), 'utf8')].join(''),
    )
    .join('');
  writeFileSync(file('signing.pem'), bundle, { mode: 0o600 });
  chmodSync(file('signing.pem'), 0o600);
}

/**
 * Приводит каталог подписи к рабочему состоянию: если оба сертификата уже выпущены и живы
 * в аккаунте (их могли отозвать руками) — ничего не делает, иначе выпускает заново.
 * `--new-cert` выпускает новые поверх старых, это способ поменять истёкшие.
 *
 * @returns {Promise<object>} данные сертификатов по ролям: `{development: {...}, distribution: {...}}`.
 */
async function ensureCertificates() {
  const saved = readJson('certs.json');
  if (!newCert && saved) {
    const alive = await certificates();
    const allAlive = CERT_KINDS.every((k) => alive.some((c) => c.id === saved[k.role]?.id));
    if (allAlive) {
      // Бандл — производное от ключей и сертификатов: если его удалили отдельно, собираем заново.
      if (!existsSync(file('signing.pem'))) packBundle(CERT_KINDS);
      for (const kind of CERT_KINDS) {
        console.log(`сертификат на месте (${kind.role}): ${saved[kind.role].name}, серийный …${saved[kind.role].serial}, истекает ${saved[kind.role].expires}`);
      }
      return saved;
    }
    console.log('часть сертификатов в аккаунте отозвана — выпускаю заново');
  }

  const built = {};
  for (const kind of CERT_KINDS) {
    built[kind.role] = await issueCertificate(kind);
  }
  packBundle(CERT_KINDS);
  writeFileSync(file('certs.json'), JSON.stringify(built, null, 2) + '\n');
  return built;
}

mkdirSync(dir, { recursive: true, mode: 0o700 });

const certs = await ensureCertificates();
const nearest = CERT_KINDS.map((k) => certs[k.role].expires).sort()[0];

console.log(`
== дальше ==
Секреты для сборки в CI (значения читаются из файлов, на экран не выводятся):

  base64 -i ${file('signing.pem')} | gh secret set IOS_SIGNING_PEM

Токен GitHub подставит $HOME/work/.git-token.sh (source перед командами).

Сборка в CI кладёт эти сертификаты в одноразовую связку ключей и подписывает ими сборку —
в аккаунте Apple она ничего не заводит. Профиль Ad Hoc и список устройств остаются на попечении
Xcode, как и раньше. Локальные сборки не меняются: на маке подпись идёт личным сертификатом
из связки ключей. Ближайший срок — ${nearest}, после него сертификаты надо выпустить заново.`);
