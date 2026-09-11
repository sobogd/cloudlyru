// Публикация сборки Android-клиента: файл ложится в релизный артефакт S3
// (release/android/), откуда его отдаёт постоянная ссылка https://files.iq-factura.com/apk.
//
// Рядом с APK пишется latest.json — версия, размер, sha256. По нему приложение понимает,
// что вышла новая версия (GET /api/v1/app/android), а /apk всегда отдаёт последнюю сборку.
//
// Ключи S3 берутся из окружения (S3_FILES_*), никаких других секретов скрипту не нужно:
//   node --env-file=$HOME/work/.env scripts/publish-apk.mjs [путь-к-apk] [--dry-run] [--force]
//
// Защита от «обновления назад»: versionCode новой сборки обязан быть больше опубликованного.
// Повторная публикация тех же самых байтов (перезапуск сборки) проходит молча.
import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { S3Client, PutObjectCommand, GetObjectCommand, NoSuchKey } from '@aws-sdk/client-s3';

const APK_KEY = 'release/android/cloudlyru-sync.apk';
const META_KEY = 'release/android/latest.json';
const APK_MIME = 'application/vnd.android.package-archive';
const PUBLIC_URL = (process.env.CLOUDLY_BASE_URL || 'https://files.iq-factura.com').replace(/\/+$/, '') + '/apk';

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const positional = args.filter((a) => !a.startsWith('--'));
const apkPath = resolve(positional[0] || 'android/app/build/outputs/apk/release/app-release.apk');
const dryRun = flags.has('--dry-run');
const force = flags.has('--force');

if (!existsSync(apkPath)) throw new Error(`нет файла сборки: ${apkPath}`);

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

/** versionCode/versionName сборки: их пишет AGP рядом с APK в output-metadata.json. */
function readVersion(file) {
  const metaPath = join(dirname(file), 'output-metadata.json');
  if (!existsSync(metaPath)) {
    throw new Error(
      `рядом с APK нет ${metaPath} — не знаю versionCode. Соберите через ./gradlew :app:assembleRelease`,
    );
  }
  const meta = JSON.parse(readFileSync(metaPath, 'utf8'));
  const element = (meta.elements || [])[0] || {};
  if (typeof element.versionCode !== 'number') throw new Error('в output-metadata.json нет versionCode');
  return {
    applicationId: String(meta.applicationId || ''),
    versionCode: element.versionCode,
    versionName: String(element.versionName || ''),
    minSdk: Number(meta.minSdkVersionForDexing || 0),
  };
}

const apk = readFileSync(apkPath);
const sha256 = createHash('sha256').update(apk).digest('hex');
const version = readVersion(apkPath);

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
  `сборка: ${version.versionName} (versionCode ${version.versionCode}), ` +
    `${(apk.length / 1048576).toFixed(1)} МБ, sha256 ${sha256.slice(0, 16)}…`,
);
if (published) {
  console.log(
    `опубликовано: ${published.versionName} (versionCode ${published.versionCode}), sha256 ${String(published.sha256).slice(0, 16)}…`,
  );
  // Совсем те же байты — повторный запуск сборки: публиковать нечего.
  if (published.versionCode === version.versionCode && published.sha256 === sha256) {
    console.log('эта сборка уже в релизе — публиковать нечего (телефон увидит её как текущую)');
    process.exit(0);
  }
  // versionCode — единственное, по чему телефон понимает, что вышло обновление. Сборка
  // с тем же или меньшим номером ляжет по ссылке, но кнопка «Обновить» её не увидит,
  // и обновиться получится только руками — это и есть та возня, от которой уходим.
  if (published.versionCode >= version.versionCode) {
    if (!force) {
      throw new Error(
        `в релизе уже versionCode ${published.versionCode}: поднимите versionCode/versionName ` +
          'в android/app/build.gradle.kts, иначе телефон это обновлением не увидит ' +
          '(или передайте --force, если публикуете осознанно)',
      );
    }
    console.warn(
      `--force: публикую сборку с versionCode ${version.versionCode} поверх ${published.versionCode} — ` +
        'в приложении она как обновление не появится',
    );
  }
}

const meta = {
  ...version,
  size: apk.length,
  sha256,
  builtAt: new Date().toISOString(),
  url: PUBLIC_URL,
};

if (dryRun) {
  console.log(`--dry-run: залил бы ${key(APK_KEY)} (${apk.length} Б) и ${key(META_KEY)}`);
  console.log(`ссылка была бы: ${PUBLIC_URL}`);
  process.exit(0);
}

await s3.send(
  new PutObjectCommand({ Bucket: bucket, Key: key(APK_KEY), Body: apk, ContentType: APK_MIME }),
);
console.log(`залито: s3://${bucket}/${key(APK_KEY)}`);
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
console.log(`версия для проверки обновления: ${PUBLIC_URL.replace(/\/apk$/, '')}/api/v1/app/android`);
