// Proof of concept: объединение метаданных из .json-сайдкара внутрь JPEG прямо в хранилище.
// 1) читаем файл и сайдкар из S3 (через API)
// 2) смотрим текущий EXIF (exiftool)
// 3) вписываем дату съёмки из сайдкара
// 4) проверяем, что пиксели не изменились (sharp: хэш сырых данных)
// 5) кладём изменённый файл обратно в S3 через WebDAV и читаем EXIF обратно
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire('/home/deploy/apps/cloudlyru/');
const sharp = require('sharp');

const API = 'http://127.0.0.1:8305/api/v1';
const env = Object.fromEntries(
  readFileSync('/home/deploy/apps/cloudlyru/.env', 'utf8')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);

const login = await fetch(`${API}/auth/login`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ login: env.ADMIN_LOGIN || 'admin', password: env.ADMIN_PASSWORD }),
});
const cookie = (login.headers.getSetCookie?.() || [])[0] || (login.headers.get('set-cookie') || '').split(';')[0];
const H = { Cookie: cookie };
const kids = async (id) => (await (await fetch(`${API}/folders/${id}/children`, { headers: H })).json());
const bytes = async (id) => {
  const r = await fetch(`${API}/files/${id}/content`, { headers: H, redirect: 'follow' });
  return Buffer.from(await r.arrayBuffer());
};

// --- находим файл ---
const root = await (await fetch(`${API}/folders`, { headers: H })).json();
const gp = root.folders.find((f) => f.name === 'GooglePhotos-Takeout').id;
const archive = (await kids(gp)).folders.find((f) => f.name.includes('-001'));
let cur = gp;
for (const s of [archive.name, 'Takeout', 'Google Photos', 'мама в гомеле апрель 2013']) {
  const d = await kids(cur);
  cur = d.folders.find((x) => x.name === s).id;
}
const listing = await kids(cur);
const jpgEntry = listing.entries.find((e) => e.name === 'DSC_0492.jpg');
const sideEntry = listing.entries.find((e) => e.name.startsWith('DSC_0492.jpg') && e.name.endsWith('.json'));

const original = await bytes(jpgEntry.id);
const sidecar = JSON.parse((await bytes(sideEntry.id)).toString('utf8'));
const taken = new Date(Number(sidecar.photoTakenTime.timestamp) * 1000);
console.log(`файл: ${jpgEntry.name}, ${original.length} Б, sha=${jpgEntry.sha256.slice(0, 16)}`);
console.log(`сайдкар: дата съёмки ${taken.toISOString()}`);

// --- 1. текущий EXIF ---
writeFileSync('/tmp/dsc-before.jpg', original);
const exif = (file) => {
  const out = execFileSync('exiftool', ['-json', '-DateTimeOriginal', '-CreateDate', '-ModifyDate', '-Make', '-Model', '-GPSDateTime', '-Orientation', file], { encoding: 'utf8' });
  return JSON.parse(out)[0];
};
const before = exif('/tmp/dsc-before.jpg');
console.log('EXIF до:', JSON.stringify(before));

// --- 2. вписываем дату съёмки из сайдкара ---
const pad = (n) => String(n).padStart(2, '0');
const stamp = `${taken.getUTCFullYear()}:${pad(taken.getUTCMonth() + 1)}:${pad(taken.getUTCDate())} ${pad(taken.getUTCHours())}:${pad(taken.getUTCMinutes())}:${pad(taken.getUTCSeconds())}`;
execFileSync('cp', ['/tmp/dsc-before.jpg', '/tmp/dsc-after.jpg']);
execFileSync('exiftool', ['-overwrite_original', '-q', `-DateTimeOriginal=${stamp}`, `-CreateDate=${stamp}`, '-OffsetTimeOriginal=+00:00', '/tmp/dsc-after.jpg']);
const after = exif('/tmp/dsc-after.jpg');
console.log(`вписали: ${stamp}`);
console.log('EXIF после:', JSON.stringify(after));

// --- 3. пиксели не изменились? ---
const rawHash = async (f) => {
  const buf = await sharp(f).raw().toBuffer();
  const { createHash } = await import('node:crypto');
  return createHash('sha256').update(buf).digest('hex');
};
const h1 = await rawHash('/tmp/dsc-before.jpg');
const h2 = await rawHash('/tmp/dsc-after.jpg');
console.log(`пиксели: ${h1 === h2 ? 'ИДЕНТИЧНЫ ✓ (изменились только метаданные)' : 'ИЗМЕНИЛИСЬ ✖'}`);
console.log(`размер: ${original.length} → ${readFileSync('/tmp/dsc-after.jpg').length} Б`);

// --- 4. кладём обратно в S3 через WebDAV и читаем оттуда ---
// папку создаём сами (WebDAV PUT не создаёт родителя)
const rootNow = await (await fetch(`${API}/folders`, { headers: H })).json();
if (!rootNow.folders.some((f) => f.name === 'EXIF-test')) {
  await fetch(`${API}/folders`, { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'EXIF-test' }) });
  console.log('создана папка EXIF-test');
}
const tok = await (await fetch(`${API}/auth/tokens`, { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ label: 'exif-poc' }) })).json();
const target = 'EXIF-test/DSC_0492.jpg';
const put = await fetch(`${API}/dav/${target}`, {
  method: 'PUT',
  headers: { Authorization: 'Basic ' + Buffer.from(`admin:${tok.token}`).toString('base64'), 'Content-Type': 'image/jpeg' },
  body: readFileSync('/tmp/dsc-after.jpg'),
});
console.log(`WebDAV PUT ${target}: HTTP ${put.status}`);

const rootAfter = await (await fetch(`${API}/folders`, { headers: H })).json();
const testFolder = rootAfter.folders.find((f) => f.name === 'EXIF-test');
const testFiles = await kids(testFolder.id);
const newEntry = testFiles.entries.find((e) => e.name === 'DSC_0492.jpg');
console.log(`в хранилище: ${newEntry.name}, ${newEntry.size} Б, sha=${newEntry.sha256.slice(0, 16)} (было ${jpgEntry.sha256.slice(0, 16)})`);
const back = await bytes(newEntry.id);
writeFileSync('/tmp/dsc-back.jpg', back);
console.log('EXIF прочитан ОБРАТНО из S3:', JSON.stringify(exif('/tmp/dsc-back.jpg')));

// убираем тестовый токен
await fetch(`${API}/auth/tokens/${tok.id}`, { method: 'DELETE', headers: H });
