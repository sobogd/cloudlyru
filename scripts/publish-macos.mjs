// Публикация настольной сборки macOS: архив с `Cloudly.app` ложится в релизный артефакт S3
// (release/macos/), откуда его отдаёт постоянная ссылка https://files.iq-factura.com/macos.
//
// Рядом с архивом пишется latest.json — версия, размер, sha256. По нему приложение на маке
// понимает, что вышла новая версия (GET /api/v1/app/macos), а /macos всегда отдаёт последнюю.
//
// Версию скрипту передают аргументами, а не читают из собранного бандла: в бандле лежит
// бинарный Info.plist, разбирать который без зависимостей нечем. В workflow номер берётся
// из `flutter/pubspec.yaml` — из того же `+N`, что даёт versionCode на Android.
//
// Ключи S3 берутся из окружения (S3_FILES_*), никаких других секретов скрипту не нужно:
//   node --env-file=$HOME/work/.env scripts/publish-macos.mjs <архив> \
//     --version-name 1.0.0 --version-code 51 [--dry-run] [--force]
//
// Защита от «обновления назад»: номер сборки обязан быть больше опубликованного.
// Повторная публикация тех же самых байтов (перезапуск сборки) проходит молча.
import { createHash } from 'node:crypto';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { S3Client, PutObjectCommand, GetObjectCommand, NoSuchKey } from '@aws-sdk/client-s3';

const ZIP_KEY = 'release/macos/cloudlyru-sync-macos.zip';
const META_KEY = 'release/macos/latest.json';
const ZIP_MIME = 'application/zip';
const PUBLIC_URL =
  (process.env.CLOUDLY_BASE_URL || 'https://files.iq-factura.com').replace(/\/+$/, '') + '/macos';

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const positional = args.filter((a) => !a.startsWith('--'));
const zipPath = resolve(positional[0] || 'flutter/build/macos/Build/Products/Release/Cloudly.zip');
const dryRun = flags.has('--dry-run');
const force = flags.has('--force');

/** Значение аргумента `--key value` или undefined, если его нет. */
function flagValue(name) {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? args[at + 1] : undefined;
}

if (!existsSync(zipPath)) throw new Error(`нет файла сборки: ${zipPath}`);
if (!statSync(zipPath).isFile()) throw new Error(`это не файл: ${zipPath}`);

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

const zip = readFileSync(zipPath);
const sha256 = createHash('sha256').update(zip).digest('hex');

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
    `${(zip.length / 1048576).toFixed(1)} МБ, sha256 ${sha256.slice(0, 16)}…`,
);
if (published) {
  console.log(
    `опубликовано: ${published.versionName} (номер ${published.versionCode}), sha256 ${String(published.sha256).slice(0, 16)}…`,
  );
  // Совсем те же байты — повторный запуск сборки: публиковать нечего.
  if (published.versionCode === versionCode && published.sha256 === sha256) {
    console.log('эта сборка уже в релизе — публиковать нечего (мак увидит её как текущую)');
    process.exit(0);
  }
  // Номер сборки — единственное, по чему приложение понимает, что вышло обновление: сборка
  // с тем же или меньшим номером ляжет по ссылке, но кнопка «Обновить» её не увидит.
  if (published.versionCode >= versionCode) {
    if (!force) {
      throw new Error(
        `в релизе уже номер ${published.versionCode}: поднимите номер в flutter/pubspec.yaml, ` +
          'иначе мак это обновлением не увидит (или передайте --force, если публикуете осознанно)',
      );
    }
    console.warn(
      `--force: публикую сборку с номером ${versionCode} поверх ${published.versionCode} — ` +
        'в приложении она как обновление не появится',
    );
  }
}

const meta = {
  applicationId: 'ru.cloudly.sync',
  versionCode,
  versionName,
  // Минимальной версии macOS у настольной сборки нет: система либо запускает её, либо нет,
  // а поле в ответе общее с мобильной сборкой — оставляем ноль, как «не заявлено».
  minSdk: 0,
  size: zip.length,
  sha256,
  builtAt: new Date().toISOString(),
  url: PUBLIC_URL,
};

if (dryRun) {
  console.log(`--dry-run: залил бы ${key(ZIP_KEY)} (${zip.length} Б) и ${key(META_KEY)}`);
  console.log(`ссылка была бы: ${PUBLIC_URL}`);
  process.exit(0);
}

await s3.send(
  new PutObjectCommand({ Bucket: bucket, Key: key(ZIP_KEY), Body: zip, ContentType: ZIP_MIME }),
);
console.log(`залито: s3://${bucket}/${key(ZIP_KEY)}`);
await s3.send(
  new PutObjectCommand({
    Bucket: bucket,
    Key: key(META_KEY),
    Body: Buffer.from(JSON.stringify(meta, null, 2) + '\n', 'utf8'),
    ContentType: 'application/json; charset=utf-8',
  }),
);
console.log(`залито: s3://${bucket}/${key(META_KEY)}`);
console.log(`последняя сборка всегда здесь: ${PUBLIC_URL}`);
console.log(`версия для проверки обновления: ${PUBLIC_URL.replace(/\/macos$/, '')}/api/v1/app/macos`);
