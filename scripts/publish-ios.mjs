// Публикация сборки для iPad и iPhone: Ad Hoc архив `.ipa` ложится в релизный артефакт S3
// (release/ios/), откуда его отдаёт постоянная ссылка https://files.iq-factura.com/ios.
//
// Рядом с архивом пишется latest.json — версия, размер, sha256. Из него сервер собирает
// манифест установки (`/ios/manifest.plist`) и страницу `/ios/install`, поэтому после
// публикации ничего руками обновлять не нужно: манифест всегда указывает на последнюю сборку.
//
// Версию скрипту передают аргументами, а не читают из бандла: в `.ipa` лежит бинарный
// Info.plist, разбирать который без зависимостей нечем. Номер берётся из `flutter/pubspec.yaml`
// — из того же `+N`, что даёт versionCode на Android и CFBundleVersion на маке.
//
// Ключи S3 берутся из окружения (S3_FILES_*), больше скрипту ничего не нужно:
//   node --env-file=$HOME/work/.env scripts/publish-ios.mjs <файл.ipa> \
//     --version-name 1.0.0 --version-code 131 [--dry-run] [--force]
//
// Защита от «обновления назад»: номер сборки обязан быть больше опубликованного. Повторная
// публикация тех же самых байтов (перезапуск сборки) проходит молча.
import { createHash } from 'node:crypto';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { S3Client, PutObjectCommand, GetObjectCommand, NoSuchKey } from '@aws-sdk/client-s3';

const IPA_KEY = 'release/ios/cloudlyru-sync.ipa';
const META_KEY = 'release/ios/latest.json';
const IPA_MIME = 'application/octet-stream';
const PUBLIC_URL =
  (process.env.CLOUDLY_BASE_URL || 'https://files.iq-factura.com').replace(/\/+$/, '') + '/ios';

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const positional = args.filter((a) => !a.startsWith('--'));
const ipaPath = resolve(positional[0] || 'flutter/build/ios/ipa/Cloudly.ipa');
const dryRun = flags.has('--dry-run');
const force = flags.has('--force');

/** Значение аргумента `--key value` или undefined, если его нет. */
function flagValue(name) {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? args[at + 1] : undefined;
}

if (!existsSync(ipaPath)) throw new Error(`нет файла сборки: ${ipaPath}`);
if (!statSync(ipaPath).isFile()) throw new Error(`это не файл: ${ipaPath}`);

const versionName = flagValue('version-name');
const versionCode = Number(flagValue('version-code'));
if (!versionName) throw new Error('нужен --version-name (имя версии, например 1.0.0)');
if (!Number.isInteger(versionCode) || versionCode <= 0) {
  throw new Error('нужен --version-code (номер сборки из flutter/pubspec.yaml, после «+»)');
}

const { accessKeyId, secretAccessKey, endpoint, region, bucket, prefix } = {
  accessKeyId: process.env.S3_FILES_ACCESS_KEY,
  secretAccessKey: process.env.S3_FILES_SECRET_KEY,
  endpoint: process.env.S3_FILES_ENDPOINT || 'https://nbg1.your-objectstorage.com',
  region: process.env.S3_FILES_REGION || 'nbg1',
  bucket: process.env.S3_FILES_BUCKET || 'cloudlyru',
  prefix: normalizePrefix(process.env.S3_FILES_PREFIX || ''),
};
if (!accessKeyId || !secretAccessKey) {
  throw new Error('нужны S3_FILES_ACCESS_KEY / S3_FILES_SECRET_KEY (запускайте через node --env-file)');
}

function normalizePrefix(raw) {
  const p = raw.trim().replace(/^\/+/, '').replace(/\/+$/, '');
  return p ? `${p}/` : '';
}

const key = (k) => prefix + k;

const ipa = readFileSync(ipaPath);
const sha256 = createHash('sha256').update(ipa).digest('hex');

const s3 = new S3Client({
  region,
  endpoint,
  // как в приложении: у Hetzner Object Storage путь в стиле S3 (/bucket/key)
  forcePathStyle: (process.env.S3_FILES_FORCE_PATH_STYLE || 'true') !== 'false',
  credentials: { accessKeyId, secretAccessKey },
});

async function readPublished() {
  try {
    const out = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key(META_KEY) }));
    const text = await out.Body.transformToString();
    return JSON.parse(text);
  } catch (e) {
    if (e instanceof NoSuchKey || e?.name === 'NoSuchKey' || e?.$metadata?.httpStatusCode === 404) return null;
    throw e;
  }
}

const published = await readPublished();
console.log(
  `сборка: ${versionName} (номер ${versionCode}), ` +
    `${(ipa.length / 1048576).toFixed(1)} МБ, sha256 ${sha256.slice(0, 16)}…`,
);
if (published) {
  console.log(
    `опубликовано: ${published.versionName} (номер ${published.versionCode}), sha256 ${String(published.sha256).slice(0, 16)}…`,
  );
  // Совсем те же байты — повторный запуск сборки: публиковать нечего.
  if (published.versionCode === versionCode && published.sha256 === sha256) {
    console.log('эта сборка уже в релизе — публиковать нечего');
    process.exit(0);
  }
  // Номер сборки виден в приложении и в манифесте: сборка с тем же или меньшим номером
  // ляжет по ссылке, но обновиться на неё с устройства не выйдет — систему устроит
  // только старшая версия, а человек увидит «установка не удалась» без объяснения.
  if (published.versionCode >= versionCode) {
    if (!force) {
      throw new Error(
        `в релизе уже номер ${published.versionCode}: поднимите номер в flutter/pubspec.yaml, ` +
          'иначе устройство не поставит сборку поверх (или передайте --force, если публикуете осознанно)',
      );
    }
    console.warn(
      `--force: публикую сборку с номером ${versionCode} поверх ${published.versionCode}`,
    );
  }
}

const meta = {
  applicationId: 'ru.cloudly.sync',
  versionCode,
  versionName,
  // Минимальной версии iOS у сборки нет в описании: её задаёт профиль подписи и Deployment
  // Target, а поле в ответе общее с мобильной сборкой — оставляем ноль, как «не заявлено».
  minSdk: 0,
  size: ipa.length,
  sha256,
  builtAt: new Date().toISOString(),
  url: PUBLIC_URL,
};

if (dryRun) {
  console.log(`--dry-run: залил бы ${key(IPA_KEY)} (${ipa.length} Б) и ${key(META_KEY)}`);
  console.log(`установка была бы: ${PUBLIC_URL}/install`);
  process.exit(0);
}

await s3.send(
  new PutObjectCommand({ Bucket: bucket, Key: key(IPA_KEY), Body: ipa, ContentType: IPA_MIME }),
);
console.log(`залито: s3://${bucket}/${key(IPA_KEY)}`);
await s3.send(
  new PutObjectCommand({
    Bucket: bucket,
    Key: key(META_KEY),
    Body: Buffer.from(JSON.stringify(meta, null, 2) + '\n', 'utf8'),
    ContentType: 'application/json; charset=utf-8',
  }),
);
console.log(`залито: s3://${bucket}/${key(META_KEY)}`);
console.log(`установка на устройстве: ${PUBLIC_URL}/install`);
console.log(`сам архив: ${PUBLIC_URL}`);
