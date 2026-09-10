// Замер: у какой доли файлов из распакованного Takeout дата съёмки ОТСУТСТВУЕТ в самом файле
// (тогда объединение метаданных из .json действительно нужно).
// Смотрим выборку по разным папкам архива -001.
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const API = 'http://127.0.0.1:8305/api/v1';
const env = Object.fromEntries(
  readFileSync('/home/deploy/apps/cloudlyru/.env', 'utf8')
    .split('\n').filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);
const login = await fetch(`${API}/auth/login`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ login: env.ADMIN_LOGIN || 'admin', password: env.ADMIN_PASSWORD }),
});
const cookie = (login.headers.getSetCookie?.() || [])[0] || (login.headers.get('set-cookie') || '').split(';')[0];
const H = { Cookie: cookie };
const kids = async (id) => (await (await fetch(`${API}/folders/${id}/children`, { headers: H })).json());
const bytes = async (id) => {
  const r = await fetch(`${API}/files/${id}/content`, { headers: H, redirect: 'follow' });
  return Buffer.from(await r.arrayBuffer());
};

const root = await (await fetch(`${API}/folders`, { headers: H })).json();
const gp = root.folders.find((f) => f.name === 'GooglePhotos-Takeout').id;
const archive = (await kids(gp)).folders.find((f) => f.name.includes('-001'));
const gpFolder = (await kids(gp)).folders.find((f) => f.name === archive.name);
let cur = gpFolder.id;
for (const s of ['Takeout', 'Google Photos']) {
  const d = await kids(cur);
  cur = d.folders.find((x) => x.name === s).id;
}

// берём до 12 папок и в каждой до 4 картинок
const photos = (await kids(cur)).folders.filter((f) => /Photos from|Untitled|Pictures|Movies/.test(f.name)).slice(0, 12);
let checked = 0;
let withDate = 0;
let withoutDate = 0;
const examples = [];

for (const folder of photos) {
  const d = await kids(folder.id);
  const imgs = d.entries.filter((e) => /\.(jpe?g|png|heic|webp)$/i.test(e.name)).slice(0, 4);
  for (const img of imgs) {
    const buf = await bytes(img.id);
    writeFileSync('/tmp/probe.img', buf);
    let dt = null;
    try {
      const out = execFileSync('exiftool', ['-json', '-DateTimeOriginal', '-CreateDate', '/tmp/probe.img'], { encoding: 'utf8' });
      const j = JSON.parse(out)[0];
      dt = j.DateTimeOriginal || j.CreateDate || null;
    } catch { /* ignore */ }
    checked += 1;
    if (dt) withDate += 1;
    else {
      withoutDate += 1;
      if (examples.length < 6) examples.push(`${folder.name}/${img.name}`);
    }
  }
}

console.log(`проверено файлов: ${checked}`);
console.log(`  с датой в файле:      ${withDate}`);
console.log(`  БЕЗ даты в файле:     ${withoutDate}`);
if (examples.length) {
  console.log('  примеры без даты:');
  for (const e of examples) console.log(`    ${e}`);
}
