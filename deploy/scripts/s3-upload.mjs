// Загрузка файла в S3 (Hetzner Object Storage) для бэкапа БД CloudlyRu.
// Запуск из каталога приложения (там же лежат node_modules с @aws-sdk):
//   node deploy/scripts/s3-upload.mjs <локальный файл> <ключ в бакете>
// Ключи берутся из окружения (S3_FILES_*), в аргументы процесса не попадают.
import { createReadStream } from 'fs';
import { stat } from 'fs/promises';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

const [file, key] = process.argv.slice(2);
if (!file || !key) {
  console.error('[s3-upload] usage: s3-upload.mjs <file> <key>');
  process.exit(2);
}
const bucket = process.env.S3_FILES_BUCKET;
if (!bucket || !process.env.S3_FILES_ACCESS_KEY || !process.env.S3_FILES_SECRET_KEY) {
  console.error('[s3-upload] нет S3_FILES_BUCKET / S3_FILES_ACCESS_KEY / S3_FILES_SECRET_KEY');
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

const size = (await stat(file)).size;
await s3.send(
  new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    Body: createReadStream(file),
    ContentLength: size,
    ContentType: 'application/gzip',
  }),
);
console.log(`[s3-upload] s3://${bucket}/${key} (${(size / 1e6).toFixed(1)} МБ)`);
