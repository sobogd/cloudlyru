// Публикация APK в личное облако владельца: файл лежит в папке apk и скачивается по обычной
// авторизованной ссылке /api/v1/files/<entryId>/content (в браузере, где открыта сессия
// владельца). Если файл с таким именем уже есть, новая версия заменяет его: ссылка не меняется.
//
// Токен выпускается на время публикации и сразу отзывается: постоянных секретов у скрипта нет.
// Запуск:  node --env-file=$HOME/work/.env scripts/publish-apk.mjs android/app/build/outputs/apk/release/app-release.apk
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const API = process.env.CLOUDLY_API || 'https://files.iq-factura.com/api/v1';
const login = process.env.CLOUDLY_ADMIN_LOGIN || 'admin';
const password = process.env.CLOUDLY_ADMIN_PASSWORD;
const file = process.argv[2];
const remoteName = process.argv[3] || 'cloudlyru-sync.apk';
const remotePath = process.argv[4] || 'apk';

if (!password) throw new Error('нужен CLOUDLY_ADMIN_PASSWORD (запускайте через node --env-file)');
if (!file) throw new Error('укажите путь к APK');

const apk = readFileSync(file);
const sha256 = createHash('sha256').update(apk).digest('hex');
console.log(`APK: ${file}, ${(apk.length / 1048576).toFixed(1)} МБ, sha256 ${sha256.slice(0, 16)}…`);

const loginRes = await fetch(`${API}/auth/login`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Origin: API.replace(/\/api\/v1$/, '') },
  body: JSON.stringify({ login, password }),
});
if (!loginRes.ok) throw new Error(`вход не прошёл: HTTP ${loginRes.status} ${await loginRes.text()}`);
const cookie = (loginRes.headers.getSetCookie?.() || [])[0]?.split(';')[0] || '';
const session = { Cookie: cookie };

const created = await (
  await fetch(`${API}/auth/tokens`, {
    method: 'POST',
    headers: { ...session, 'Content-Type': 'application/json' },
    body: JSON.stringify({ label: 'publish-apk' }),
  })
).json();

const auth = { Authorization: `Bearer ${created.token}` };
try {
  const root = await (await fetch(`${API}/folders`, { headers: auth })).json();
  const folderId = (
    await (
      await fetch(`${API}/folders/ensure-path`, {
        method: 'POST',
        headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: remotePath, parentId: root.parentId }),
      })
    ).json()
  ).id;
  if (!folderId) throw new Error(`не удалось получить папку ${remotePath}`);

  const children = await (await fetch(`${API}/folders/${folderId}/children`, { headers: auth })).json();
  const existing = (children.entries || []).find((e) => e.name === remoteName);

  const init = await (
    await fetch(`${API}/uploads`, {
      method: 'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        folderId,
        name: remoteName,
        size: apk.length,
        mime: 'application/vnd.android.package-archive',
        sha256,
        mode: 'relay',
        replace: Boolean(existing),
        ...(existing ? { expectedSha256: existing.sha256 } : {}),
      }),
    })
  ).json();
  if (init.error) throw new Error(`init: ${JSON.stringify(init)}`);
  if (init.deduped) {
    console.log(`содержимое уже в облаке, запись: ${init.entry?.id}`);
    process.exit(0);
  }

  const chunk = await fetch(`${API}/uploads/${init.uploadId}/chunks/1`, {
    method: 'PUT',
    headers: { ...auth, 'Content-Type': 'application/octet-stream' },
    body: apk,
  });
  if (!chunk.ok) throw new Error(`chunk: HTTP ${chunk.status} ${await chunk.text()}`);

  const done = await (
    await fetch(`${API}/uploads/${init.uploadId}/complete`, {
      method: 'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ sha256 }),
    })
  ).json();
  const entryId = done.entry?.id || init.entry?.id;
  console.log(`готово: ${remoteName}${existing ? ' (обновлён)' : ''}`);
  console.log(`ссылка: ${API}/files/${entryId}/content`);
  console.log(`entryId: ${entryId}`);
} finally {
  // временный токен не должен остаться в списке устройств
  await fetch(`${API}/auth/tokens/${created.id}`, { method: 'DELETE', headers: session });
}
