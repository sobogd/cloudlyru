// Временная ссылка на файл в бакете (например, чтобы отдать APK или дамп).
// Запуск из каталога приложения (там же node_modules с @aws-sdk):
//   node deploy/scripts/s3-presign.mjs <ключ в бакете> [секунд]
// По умолчанию 7 суток — максимум для presigned-ссылок S3. Ключи доступа берутся
// из окружения и в аргументы не попадают; печатается только URL.
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const [key, ttlArg] = process.argv.slice(2);
if (!key) {
  console.error('[s3-presign] usage: s3-presign.mjs <key> [ttl-seconds]');
  process.exit(2);
}
const ttl = Number(ttlArg) > 0 ? Math.min(Number(ttlArg), 604800) : 604800;
const bucket = process.env.S3_FILES_BUCKET;
if (!bucket || !process.env.S3_FILES_ACCESS_KEY || !process.env.S3_FILES_SECRET_KEY) {
  console.error('[s3-presign] нет S3_FILES_BUCKET / S3_FILES_ACCESS_KEY / S3_FILES_SECRET_KEY');
  process.exit(2);
}

const s3 = new S3Client({
  region: process.env.S3_FILES_REGION || 'nbg1',
  endpoint: process.env.S3_FILES_ENDPOINT || 'https://nbg1.your-objectstorage.com',
  forcePathStyle: (process.env.S3_FILES_FORCE_PATH_STYLE ?? 'true') !== 'false',
  credentials: {
    accessKeyId: process.env.S3_FILES_ACCESS_KEY,
    secretAccessKey: process.env.S3_FILES_SECRET_KEY,
  },
});

const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket, Key: key }), {
  expiresIn: ttl,
});
console.error(`[s3-presign] s3://${bucket}/${key} — ссылка на ${Math.round(ttl / 3600)} ч`);
console.log(url);
