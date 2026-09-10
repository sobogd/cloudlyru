// Тест читалки ZIP поверх S3: список файлов, распаковка, проверка CRC32.
// Запуск на VPS: node /root/takeout/test-zip-reader.js
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire('/home/deploy/apps/cloudlyru/');
const s3 = require('@aws-sdk/client-s3');
const { RemoteZip, crc32 } = require('/root/takeout/s3-zip.js');

const env = Object.fromEntries(
  readFileSync('/home/deploy/apps/cloudlyru/.env', 'utf8')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);
const client = new s3.S3Client({
  region: env.S3_FILES_REGION,
  endpoint: env.S3_FILES_ENDPOINT,
  forcePathStyle: env.S3_FILES_FORCE_PATH_STYLE === 'true',
  credentials: { accessKeyId: env.S3_FILES_ACCESS_KEY, secretAccessKey: env.S3_FILES_SECRET_KEY },
});
const BUCKET = env.S3_FILES_BUCKET;
const API = 'http://127.0.0.1:8305/api/v1';

let reads = 0;
let bytesRead = 0;
function sourceFor(key, size) {
  return {
    size: () => size,
    readRange: async (start, end) => {
      reads += 1;
      const r = await client.send(
        new s3.GetObjectCommand({ Bucket: BUCKET, Key: key, Range: `bytes=${start}-${end}` }),
      );
      const buf = Buffer.from(await r.Body.transformToByteArray());
      bytesRead += buf.length;
      return buf;
    },
  };
}

// --- авторизация и список архивов ---
const loginRes = await fetch(`${API}/auth/login`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ login: env.ADMIN_LOGIN || 'admin', password: env.ADMIN_PASSWORD }),
});
const cookie = (loginRes.headers.getSetCookie?.() || [])[0] || (loginRes.headers.get('set-cookie') || '').split(';')[0];
const root = await (await fetch(`${API}/folders`, { headers: { Cookie: cookie } })).json();
const fid = root.folders.find((f) => f.name === 'GooglePhotos-Takeout').id;
const kids = await (await fetch(`${API}/folders/${fid}/children`, { headers: { Cookie: cookie } })).json();
const archives = kids.entries.map((e) => ({ name: e.name, sha256: e.sha256, size: e.size }));
const pick = (n) => archives.find((a) => a.name.includes(n));

// ================= ТЕСТ 1: маленький архив (569 КБ) =================
{
  const a = pick('-023.zip');
  const zip = new RemoteZip(sourceFor(`files/${a.sha256}`, a.size));
  const entries = await zip.entries();
  console.log(`\n=== ТЕСТ 1: ${a.name} (${(a.size / 1e6).toFixed(2)} МБ) ===`);
  console.log(`файлов в архиве: ${entries.length}`);
  for (const e of entries) console.log(`  ${e.name} (${e.uncompressedSize} Б, метод ${e.method})`);
  const buf = await zip.readEntryBuffer(entries[0]);
  console.log(`распаковано: ${buf.length} Б, CRC32 проверен ✓ (readEntryBuffer бросает при несовпадении)`);
}

// ================= ТЕСТ 2: большой архив (53.62 ГБ, ZIP64) =================
{
  const a = pick('-001.zip');
  const zip = new RemoteZip(sourceFor(`files/${a.sha256}`, a.size));
  console.log(`\n=== ТЕСТ 2: ${a.name} (${(a.size / 1e9).toFixed(2)} ГБ, ZIP64) ===`);

  const t0 = Date.now();
  const entries = await zip.entries();
  const listMs = Date.now() - t0;
  console.log(`файлов в архиве: ${entries.length} (список получен за ${(listMs / 1000).toFixed(1)} с, S3-запросов: ${reads}, прочитано ${(bytesRead / 1e6).toFixed(1)} МБ)`);

  const json = entries.find((e) => e.name.endsWith('.json'));
  const biggest = entries.reduce((m, e) => (e.uncompressedSize > m.uncompressedSize ? e : m), entries[0]);
  console.log(`самый крупный файл: ${biggest.name} (${(biggest.uncompressedSize / 1e6).toFixed(1)} МБ)`);
  console.log(`пример json-метаданных: ${json ? json.name : 'нет'}`);

  // 2a: распаковка с проверкой CRC (размер + CRC внутри readEntryBuffer)
  for (const e of [entries[0], json].filter(Boolean)) {
    const t = Date.now();
    const buf = await zip.readEntryBuffer(e);
    console.log(`  ✔ ${e.name}: ${buf.length} Б, CRC32 совпал (${Date.now() - t} мс)`);
  }

  // 2b: потоковая распаковка большого файла (без буферизации) + инкрементальный CRC
  const t = Date.now();
  let size = 0;
  let crc = 0;
  for await (const chunk of zip.readEntryStream(biggest)) {
    crc = crc32(chunk, crc);
    size += chunk.length;
  }
  const ok = crc === biggest.crc32 && size === biggest.uncompressedSize;
  console.log(`  ${ok ? '✔' : '✖'} ПОТОК ${biggest.name}: ${(size / 1e6).toFixed(1)} МБ за ${((Date.now() - t) / 1000).toFixed(1)} с, CRC32 ${ok ? 'совпал' : 'НЕ совпал'}`);
}

console.log(`\nИтого S3-запросов: ${reads}, прочитано ${(bytesRead / 1e6).toFixed(1)} МБ`);
