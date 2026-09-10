#!/usr/bin/env node
// ============================================================================
// takeout-stream-to-cloudly.mjs
//
// Перенос архивов Google Takeout (Google Photos) в CloudlyRu в СТРИМЕ —
// без сохранения архива на диске. Скрипт предназначен для запуска на VPS
// рядом с CloudlyRu (localhost), но работает и с любой точки (BASE).
//
// Логика на один архив:
//   1. GET авторизованного URL Takeout (Cookie из расширения CurlWget) → поток.
//   2. Читаем поток чанками и шлём в чанкованный upload API CloudlyRu
//      (POST /uploads → PUT /uploads/:id/chunks/:n → POST /uploads/:id/complete).
//      Сервер сам multipart'ит в S3 и делает дедуп по sha256.
//   3. Диск не используется вообще: ни для архива, ни для распаковки.
//
// ДОКАЧКА: прогресс по каждому архиву пишется в STATE_FILE. Если Google-кука
// умерла в середине 50-ГБ архива — после обновления cookie скрипт продолжает
// с последней принятой части через HTTP Range, а не начинает архив заново.
//
// Требования: Node 20+ (global fetch). Зависимостей нет.
// ============================================================================

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { dirname } from 'node:path';

// ---------------- config ----------------
const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const URLS_FILE = arg('--urls', 'urls.txt');
const COOKIE_FILE = arg('--cookie', 'cookie.txt');
const STATE_FILE = arg('--state', '.takeout-state.json');
const TARGET_FOLDER = arg('--folder', 'GooglePhotos-Takeout');
const CHUNK_BYTES = 8 * 1024 * 1024; // 8 МБ на чанк (серверный лимит 20 МБ)
const BASE = process.env.CLOUDLY_BASE || 'http://127.0.0.1:8305';
const ADMIN = process.env.CLOUDLY_ADMIN || 'admin';
const PASSWORD = process.env.CLOUDLY_PASSWORD || '';
const API = `${BASE}/api/v1`;
const GOOGLE_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';

class CookieExpired extends Error {}

if (!PASSWORD) {
  console.error('[config] задай CLOUDLY_PASSWORD (пароль админа CloudlyRu)');
  process.exit(2);
}
if (!existsSync(URLS_FILE)) {
  console.error(`[config] нет файла списка URL: ${URLS_FILE}`);
  process.exit(2);
}
if (!existsSync(COOKIE_FILE)) {
  console.error(`[config] нет файла Google cookie: ${COOKIE_FILE}`);
  process.exit(2);
}

const urls = readFileSync(URLS_FILE, 'utf8')
  .split(/\r?\n/)
  .map((s) => s.trim())
  .filter(Boolean);
const googleCookie = readFileSync(COOKIE_FILE, 'utf8').trim();
const state = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, 'utf8')) : { done: [] };
state.done = state.done || [];
state.progress = state.progress || {};

const doneSet = new Set(state.done);
console.log(`[config] архивов в списке: ${urls.length}; уже готово: ${doneSet.size}`);
console.log(`[config] целевая папка: ${TARGET_FOLDER}; чанк: ${CHUNK_BYTES / 1024 / 1024} МБ`);

// Маркеры для сторожа (watchdog): он перезапускает перенос, только если процесс
// умер не из-за протухшей cookie и не потому, что всё уже готово.
const MARKER_DIR = dirname(STATE_FILE);
const COOKIE_DEAD_MARKER = `${MARKER_DIR}/COOKIE_DEAD`;
const ALL_DONE_MARKER = `${MARKER_DIR}/ALL_DONE`;
for (const m of [COOKIE_DEAD_MARKER, ALL_DONE_MARKER]) {
  try { unlinkSync(m); } catch { /* нет файла — ок */ }
}

function saveState() {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function nameFromUrl(u) {
  try {
    const p = new URL(u).pathname.split('/').filter(Boolean);
    return decodeURIComponent(p[p.length - 1] || `archive-${Date.now()}.zip`);
  } catch {
    return `archive-${Date.now()}.zip`;
  }
}

const gb = (b) => (b / 1e9).toFixed(2);

/** «2 ч 15 м» из секунд. */
function humanTime(sec) {
  if (!Number.isFinite(sec) || sec <= 0) return '—';
  const h = Math.floor(sec / 3600);
  const m = Math.round((sec % 3600) / 60);
  return h ? `${h} ч ${String(m).padStart(2, '0')} м` : `${m} м`;
}

// ---- учёт прогресса по всему переносу (для строки прогресса) ----
const sizes = new Map(Object.entries(state.sizes || {})); // url → полный размер, байт
const inFlight = new Map(); // url → сколько байт уже принято сервером
let speedBps = 0;
let lastTickBytes = 0;
let lastTickAt = Date.now();

function totalBytes() {
  let sum = 0;
  for (const url of urls) sum += sizes.get(url) || 0;
  return sum;
}
function doneBytes() {
  let sum = 0;
  for (const url of doneSet) sum += sizes.get(url) || 0;
  return sum;
}
function currentBytes() {
  let sum = doneBytes();
  for (const v of inFlight.values()) sum += v;
  return sum;
}

function progressLine() {
  const total = totalBytes();
  const cur = currentBytes();
  const pct = total ? ((cur / total) * 100).toFixed(1) : '?';
  const left = speedBps > 0 ? humanTime((total - cur) / speedBps) : '—';
  const speed = speedBps > 0 ? `${(speedBps / 1e6).toFixed(1)} МБ/с` : '—';
  const active = [...inFlight.entries()]
    .map(([u, b]) => `${nameFromUrl(u).replace(/^takeout-\d+T\d+Z-\d+-/, '').replace('.zip', '')}:${((b / (sizes.get(u) || 1)) * 100).toFixed(0)}%`)
    .join(' ');
  return `[прогресс] готово ${doneSet.size}/${urls.length} · в работе ${inFlight.size}${active ? ` (${active})` : ''} · ${gb(cur)}/${gb(total)} ГБ (${pct}%) · ${speed} · осталось ~${left}`;
}

// ---------------- CloudlyRu API helpers ----------------
let sessionCookie = '';

async function api(path, init = {}, retries = 3) {
  const headers = { ...(init.headers || {}) };
  if (sessionCookie) headers['Cookie'] = sessionCookie;
  if (init.body && typeof init.body === 'string') headers['Content-Type'] = headers['Content-Type'] || 'application/json';
  let lastErr;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const res = await fetch(`${API}${path}`, { ...init, headers });
      if (res.status === 401 && path !== '/auth/login' && sessionCookie) {
        await login();
        headers['Cookie'] = sessionCookie;
        return api(path, init, 1);
      }
      const text = await res.text();
      let data = null;
      try { data = text ? JSON.parse(text) : null; } catch { data = text; }
      if (!res.ok) {
        const msg = data && typeof data === 'object' && data.message ? data.message : `HTTP ${res.status}`;
        const err = new Error(`${path} → ${msg}`);
        err.status = res.status;
        throw err;
      }
      return data;
    } catch (e) {
      lastErr = e;
      if (attempt < retries) await new Promise((r) => setTimeout(r, 1500 * attempt));
    }
  }
  throw lastErr;
}

async function login() {
  const res = await fetch(`${API}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ login: ADMIN, password: PASSWORD }),
  });
  const setCookie = res.headers.getSetCookie?.() || [];
  const raw = res.headers.get('set-cookie') || '';
  const cookieStr = setCookie[0] || raw.split(';')[0];
  if (!res.ok || !cookieStr) {
    const t = await res.text().catch(() => '');
    throw new Error(`login failed (${res.status}): ${t.slice(0, 200)}`);
  }
  sessionCookie = cookieStr;
  console.log('[auth] login ok');
}

async function ensureTargetFolder() {
  const root = await api('/folders');
  const existing = (root.folders || []).find((f) => f.name === TARGET_FOLDER);
  if (existing) return existing.id;
  const created = await api('/folders', { method: 'POST', body: JSON.stringify({ name: TARGET_FOLDER }) });
  console.log(`[folders] создана папка «${TARGET_FOLDER}»`);
  return created.id;
}

// ---------------- Google download ----------------
/** GET архива; fromByte > 0 → докачка через Range. HTML в ответе = кука умерла. */
async function googleStream(url, fromByte = 0) {
  const headers = {
    Cookie: googleCookie,
    Referer: 'https://takeout.google.com/',
    'User-Agent': GOOGLE_UA,
  };
  if (fromByte > 0) headers.Range = `bytes=${fromByte}-`;

  const res = await fetch(url, { headers, redirect: 'follow' });
  const ct = res.headers.get('content-type') || '';
  if (ct.includes('text/html')) {
    await res.body?.cancel().catch(() => undefined);
    throw new CookieExpired('Google вернул HTML вместо архива — cookie протухла, обнови её в CurlWget');
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => undefined);
    throw new Error(`google HTTP ${res.status}`);
  }
  if (!res.body) throw new Error('google: пустой ответ');
  return res;
}

// ---------------- upload one archive ----------------
/** Обёртка: при «сессия потеряна» (рестарт сервера) один раз перезапускает архив с нуля. */
async function uploadArchive(url, folderId) {
  try {
    return await uploadArchiveAttempt(url, folderId, false);
  } catch (e) {
    if (e instanceof CookieExpired) throw e;
    if (e.fatal) {
      console.log('[retry] сессия на сервере потеряна — перезапускаю этот архив с нуля');
      delete state.progress[url];
      saveState();
      return await uploadArchiveAttempt(url, folderId, true);
    }
    throw e;
  }
}

async function uploadArchiveAttempt(url, folderId, forceFresh) {
  const name = nameFromUrl(url);
  console.log(`\n=== ${name} ===`);

  let uploadId = null;
  let received = 0;
  let serverParts = 0;
  let total = 0;

  // --- попытка продолжить прерванный архив ---
  const saved = forceFresh ? null : state.progress[url];
  if (saved && saved.uploadId && saved.received > 0) {
    try {
      // ВАЖНО: статус-эндпоинт CloudlyRu — GET /uploads/:id (без суффикса /status).
      // Точка возобновления берётся С СЕРВЕРА (partCount точен), а не из чекпойнта:
      // между чекпойнтами сервер мог принять ещё части.
      const st = await api(`/uploads/${saved.uploadId}`);
      const serverBytes = Number(st.receivedParts) * CHUNK_BYTES;
      if (Number(st.size) === Number(saved.total) && serverBytes > 0 && serverBytes <= Number(st.size)) {
        uploadId = saved.uploadId;
        serverParts = Number(st.receivedParts);
        received = serverBytes;
        total = Number(st.size);
        console.log(`[resume] продолжаем с ${gb(received)} ГБ (сервер принял частей: ${serverParts})`);
      } else {
        console.log('[resume] состояние на сервере не подходит — начинаем заново');
      }
    } catch (e) {
      console.log(`[resume] сессия недоступна (${e.message}) — начинаем архив заново`);
    }
  }

  let gres = await googleStream(url, received);

  // Google не поддержал Range (вернул 200 вместо 206) → докачка невозможна, стартуем с нуля
  if (received > 0 && gres.status !== 206) {
    console.log('[resume] сервер отдал файл целиком (Range не поддержан) — перезапуск архива с нуля');
    try { await api(`/uploads/${uploadId}`, { method: 'DELETE' }, 1); } catch { /* ignore */ }
    uploadId = null; received = 0; serverParts = 0;
    gres = await googleStream(url, 0);
  }

  const remaining = Number(gres.headers.get('content-length') || 0);
  const sizeFromRange = received + remaining;
  if (!remaining) throw new Error('google не отдал content-length');

  if (!uploadId) {
    const init = await api('/uploads', {
      method: 'POST',
      body: JSON.stringify({ name, size: sizeFromRange, mime: 'application/zip', folderId }),
    });
    uploadId = init.uploadId;
    total = Number(init.size);
    console.log(`[upload] init ${uploadId}, размер ${gb(total)} ГБ`);
  } else {
    total = Number(state.progress[url].total);
    console.log(`[upload] докачка в сессию ${uploadId}: осталось ${gb(remaining)} ГБ из ${gb(total)} ГБ`);
  }
  if (sizeFromRange !== total) throw new Error(`размер не совпал: ${sizeFromRange} != ${total}`);

  inFlight.set(url, received);
  const reader = gres.body.getReader();
  let part = serverParts;

  // Конвейер: продюсер читает поток Google и набивает чанки в предвыделенный буфер
  // (без Buffer.concat — он давал ~60-кратное раздувание копирований и упирал CPU),
  // консюмер последовательно отправляет их в CloudlyRu. Чтение и загрузка идут
  // параллельно, поэтому канал не простаивает на время round-trip'ов к S3.
  const queue = [];
  const MAX_QUEUE = 4; // ~32 МБ в полёте
  let producerDone = false;
  let consumerFailed = false;
  let wake = null;
  const notify = () => { if (wake) { const w = wake; wake = null; w(); } };
  const waitFor = async (cond) => { while (!cond()) await new Promise((r) => { wake = r; }); };

  const producer = (async () => {
    let buf = Buffer.allocUnsafe(CHUNK_BYTES);
    let off = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const src = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
        let pos = 0;
        while (pos < src.length) {
          if (consumerFailed) return;
          const take = Math.min(CHUNK_BYTES - off, src.length - pos);
          src.copy(buf, off, pos, pos + take);
          off += take;
          pos += take;
          if (off === CHUNK_BYTES) {
            await waitFor(() => queue.length < MAX_QUEUE || consumerFailed);
            if (consumerFailed) return;
            queue.push(buf);
            notify();
            buf = Buffer.allocUnsafe(CHUNK_BYTES);
            off = 0;
          }
        }
      }
      if (off > 0 && !consumerFailed) {
        queue.push(buf.subarray(0, off));
      }
    } finally {
      producerDone = true;
      notify();
    }
  })();

  const consumer = (async () => {
    for (;;) {
      await waitFor(() => queue.length > 0 || producerDone || consumerFailed);
      if (consumerFailed) return;
      if (queue.length === 0) return; // producerDone
      const chunk = queue.shift();
      notify(); // разбудить продюсера, ждущего место в очереди
      part += 1;
      await putChunk(uploadId, part, chunk);
      received += chunk.length;
      inFlight.set(url, received);
      if (part % 128 === 0) {
        state.progress[url] = { uploadId, received, total };
        saveState();
        const pct = ((received / total) * 100).toFixed(0);
        console.log(`  [${name.replace(/^takeout-\d+T\d+Z-\d+-/, '').replace('.zip', '')}] ${gb(received)}/${gb(total)} ГБ (${pct}%)`);
      }
    }
  })();

  try {
    await Promise.all([producer, consumer]);
    if (received !== total) throw new Error(`недокачано: ${received} != ${total}`);

    const done = await api(`/uploads/${uploadId}/complete`, { method: 'POST' });
    delete state.progress[url];
    inFlight.delete(url);
    saveState();
    const ok = await verifyEntry(done.entry.id, total, name);
    console.log(`  ✔ [${doneSet.size + 1}/${urls.length}] ${name} · ${gb(total)} ГБ · проверка: ${ok ? 'целый' : 'ПОДОЗРИТЕЛЬНЫЙ'}`);
    console.log(progressLine());
  } catch (e) {
    consumerFailed = true;
    notify();
    await reader.cancel().catch(() => undefined);
    await producer.catch(() => undefined);
    if (e instanceof CookieExpired) {
      // прогресс сохранён, сессию НЕ убиваем — допереносим после обновления cookie
      state.progress[url] = { uploadId, received, total };
      saveState();
      throw e;
    }
    // прочие ошибки: сохраняем прогресс, но сессию оставляем (повтор с докачкой)
    if (uploadId && received > 0) {
      state.progress[url] = { uploadId, received, total };
      saveState();
    }
    throw e;
  } finally {
    reader.releaseLock();
  }
}

// ---------------- верификация архива после загрузки ----------------
// Проверяем, что файл в S3 реально целый и полный, НЕ скачивая его:
//   1) размер в CloudlyRu == размеру из Google;
//   2) в хвосте объекта (Range-запрос к /files/:id/content) есть корректная
//      запись End of Central Directory ровно в конце файла → архив не обрезан.
// Раньше ручка отвечала 302 на presigned-ссылку S3; теперь байты идут через сервис,
// Range пробрасывается в S3 как есть.
async function verifyEntry(entryId, expectedSize, name) {
  try {
    const meta = await api(`/files/${entryId}`);
    if (Number(meta.size) !== Number(expectedSize)) {
      throw new Error(`размер не совпал: в сервисе ${meta.size}, у Google ${expectedSize}`);
    }
    const size = Number(meta.size);
    const tailLen = Math.min(size, 65536);
    const r = await fetch(`${API}/files/${entryId}/content`, {
      headers: {
        ...(sessionCookie ? { Cookie: sessionCookie } : {}),
        Range: `bytes=${size - tailLen}-`,
      },
    });
    if (r.status !== 206) throw new Error(`Range-запрос к /files/:id/content: HTTP ${r.status} (ожидался 206)`);
    const tail = Buffer.from(await r.arrayBuffer());

    let pos = -1;
    for (let i = tail.length - 22; i >= 0; i--) {
      if (tail.readUInt32LE(i) === 0x06054b50) { pos = i; break; } // PK\x05\x06
    }
    if (pos < 0) throw new Error('EOCD не найден — архив обрезан');
    const commentLen = tail.readUInt16LE(pos + 20);
    if (pos + 22 + commentLen !== tail.length) {
      throw new Error(`EOCD не в конце файла (лишних байт: ${tail.length - pos - 22 - commentLen}) — архив повреждён`);
    }
    const entries = tail.readUInt16LE(pos + 10);
    const cdSize = tail.readUInt32LE(pos + 12);
    const cdOffset = tail.readUInt32LE(pos + 16);
    const zip64 = entries === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff;
    if (!zip64 && cdOffset + cdSize !== size - 22 - commentLen) {
      throw new Error('смещения центрального каталога не сходятся с размером файла');
    }
    console.log(`[verify] ✔ ${name}: целый (${gb(size)} ГБ${zip64 ? ', zip64' : `, записей ${entries}`})`);
    return true;
  } catch (e) {
    state.suspect = state.suspect || [];
    if (!state.suspect.includes(name)) state.suspect.push(name);
    saveState();
    console.error(`[verify] ✖ ${name}: ${e.message} — файл помечен как подозрительный (state.suspect)`);
    return false;
  }
}

async function putChunk(uploadId, part, chunk) {  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(`${API}/uploads/${uploadId}/chunks/${part}`, {
        method: 'PUT',
        headers: { ...(sessionCookie ? { Cookie: sessionCookie } : {}), 'Content-Type': 'application/octet-stream' },
        body: chunk,
      });
      if (res.ok) return;
      if (res.status === 401) { await login(); continue; }
      const text = await res.text();
      const err = new Error(`chunk ${part}: HTTP ${res.status} ${text.slice(0, 160)}`);
      // сессия потеряна (рестарт сервера) — докачка невозможна, пусть падает наверх
      if (res.status === 409 || text.includes('upload session')) err.fatal = true;
      throw err;
    } catch (e) {
      if (e.fatal || attempt >= 10) throw e;
      const msg = String(e.message || e);
      if (msg.includes('out of order')) throw e;
      await new Promise((r) => setTimeout(r, 1000 * attempt));
    }
  }
}

// ---------------- опрос размеров (и ранняя проверка cookie) ----------------
async function probeSizes() {
  const todo = urls.filter((u) => !sizes.has(u));
  if (!todo.length) return;
  console.log(`[config] опрашиваю размеры архивов (${todo.length} шт) — заодно проверяю cookie...`);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= todo.length) return;
      const u = todo[i];
      const res = await fetch(u, {
        headers: { Cookie: googleCookie, Referer: 'https://takeout.google.com/', 'User-Agent': GOOGLE_UA, Range: 'bytes=0-0' },
        redirect: 'follow',
      });
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('text/html')) {
        await res.body?.cancel().catch(() => undefined);
        throw new CookieExpired('Google вернул HTML на запрос размера — cookie протухла');
      }
      const cr = res.headers.get('content-range') || '';
      const size = Number(cr.split('/')[1] || res.headers.get('content-length') || 0);
      await res.body?.cancel().catch(() => undefined);
      if (size > 0) sizes.set(u, size);
    }
  };
  await Promise.all(Array.from({ length: Math.min(4, todo.length) }, () => worker()));
  state.sizes = Object.fromEntries(sizes);
  saveState();
  console.log(`[config] суммарный объём: ${gb(totalBytes())} ГБ в ${urls.length} архивах`);
}

// ---------------- main ----------------
await login();

try {
  await probeSizes();
} catch (e) {
  if (e instanceof CookieExpired) {
    console.error(`\n[СТОП] ${e.message}`);
    console.error('Обнови cookie.txt (CurlWget) и запусти скрипт снова.');
    try { writeFileSync(COOKIE_DEAD_MARKER, new Date().toISOString()); } catch { /* ignore */ }
    process.exit(3);
  }
  throw e;
}

const targetFolderId = await ensureTargetFolder();

let okCount = 0;
let failCount = 0;
let cookieDead = false;
let stopRequested = false;
let consecutiveFails = 0;
const MAX_CONSECUTIVE_FAILS = 3; // защита: не проходить весь список впустую, если сервис лежит

// Параллельная загрузка нескольких архивов: внутри архива части строго
// последовательны (требование сервера), но между архивами round-trip'ы к S3
// перекрываются, поэтому суммарная скорость выше.
const CONCURRENCY = Math.max(1, Number(arg('--concurrency', '1')) || 1);
const pending = urls.filter((u) => {
  if (doneSet.has(u)) {
    console.log(`[skip] уже готов: ${nameFromUrl(u)}`);
    okCount += 1;
    return false;
  }
  return true;
});
console.log(`[config] параллельных архивов: ${CONCURRENCY}; к переносу: ${pending.length}`);
console.log(progressLine());
let cursor = 0;

lastTickBytes = currentBytes();
lastTickAt = Date.now();
const ticker = setInterval(() => {
  const now = Date.now();
  const cur = currentBytes();
  const dt = (now - lastTickAt) / 1000;
  if (dt > 0) {
    const inst = (cur - lastTickBytes) / dt;
    speedBps = speedBps > 0 ? speedBps * 0.6 + inst * 0.4 : inst;
  }
  lastTickBytes = cur;
  lastTickAt = now;
  console.log(progressLine());
}, 20000);
ticker.unref?.();

async function worker(id) {
  for (;;) {
    if (cookieDead || stopRequested) return;
    const i = cursor++;
    if (i >= pending.length) return;
    const url = pending[i];
    try {
      await uploadArchive(url, targetFolderId);
      doneSet.add(url);
      state.done = [...doneSet];
      consecutiveFails = 0;
      saveState();
      okCount += 1;
      console.log(`[worker ${id}] архивов готово: ${okCount} из ${pending.length}`);
    } catch (e) {
      if (e instanceof CookieExpired) {
        console.error(`\n[СТОП] ${e.message}`);
        console.error('Прогресс сохранён — после обновления cookie.txt запусти скрипт снова, он продолжит с места обрыва.');
        cookieDead = true;
        try { writeFileSync(COOKIE_DEAD_MARKER, new Date().toISOString()); } catch { /* ignore */ }
        return;
      }
      failCount += 1;
      consecutiveFails += 1;
      console.error(`[FAIL] ${nameFromUrl(url)}: ${e.message}`);
      if (consecutiveFails >= MAX_CONSECUTIVE_FAILS) {
        console.error(
          `\n[СТОП] ${MAX_CONSECUTIVE_FAILS} архива подряд не загрузились — похоже, CloudlyRu/сеть недоступны. ` +
            'Останавливаюсь, чтобы не проходить весь список впустую. Прогресс сохранён, повторный запуск продолжит с места.',
        );
        stopRequested = true;
        return;
      }
    }
  }
}

await Promise.all(Array.from({ length: Math.min(CONCURRENCY, pending.length) }, (_, k) => worker(k + 1)));
clearInterval(ticker);

if (!cookieDead && !stopRequested && failCount === 0) {
  try { writeFileSync(ALL_DONE_MARKER, new Date().toISOString()); } catch { /* ignore */ }
  console.log('[done] все архивы перенесены — маркер ALL_DONE записан');
}

console.log(`\nИтог: готово ${okCount}, ошибок ${failCount} из ${urls.length}${cookieDead ? ' (остановлено: нужна свежая cookie)' : ''}${stopRequested ? ' (остановлено: сервис недоступен)' : ''}`);
if (cookieDead) process.exit(3);
if (stopRequested) process.exit(4);
if (failCount) process.exit(1);
