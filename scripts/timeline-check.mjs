// Проверка курсорной пагинации ленты «Фото» (MediaService.timeline) на локальной БД.
//
// Запуск (из каталога приложения, там же node_modules и собранный dist):
//   DATABASE_URL=postgresql://user@127.0.0.1:5432/cloudly_dev node scripts/timeline-check.mjs
//
// Ключи S3 не нужны: лента читает только Postgres, объектное хранилище в этом пути не
// участвует — поэтому сервис собирается с заглушкой вместо S3Service.
//
// Что и почему проверяется:
//   1) страницы 1/7/25/300 собирают ленту целиком — без пропусков и дубликатов. Размер
//      страницы 1 и 7 специально рвёт пачку записей с одной и той же секундой съёмки:
//      такой пачке нужен тай-брейк по id, иначе часть кадров теряется между страницами;
//   2) порядок: по убыванию даты съёмки, записи без даты — хвостом в самом конце (после
//      них уже ничего быть не должно);
//   3) вырожденные курсоры: несуществующий entryId и запись вне зоны «Фото» дают 409 с
//      кодом cursor_stale. Пустая страница в этом случае означала бы «лента кончилась», и
//      клиент перестал бы догружать остаток; по коду 409 он откатывается на предыдущую
//      запись и продолжает с неё;
//   4) статусы превью по списку id: чужие и удалённые записи в ответ не попадают.
//
// Скрипт заводит своего пользователя с деревом (корень, «Фото», «Файлы») и удаляет за
// собой всё — включая данные прошлых упавших прогонов.
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'module';
import { PrismaClient } from '@prisma/client';

const require = createRequire(import.meta.url);
const dist = (p) => require(new URL(`../dist/${p}`, import.meta.url).pathname);

const { MediaService } = dist('media/media.service.js');
const { AuthService } = dist('auth/auth.service.js');
const { AuditService } = dist('audit/audit.service.js');
const { ChangesService } = dist('sync/changes.service.js');

const prisma = new PrismaClient();

let failures = 0;
function check(name, ok, extra = '') {
  const mark = ok ? '  ok  ' : ' FAIL ';
  if (!ok) failures += 1;
  console.log(`[${mark}] ${name}${extra ? ` — ${extra}` : ''}`);
}

// --- заглушка внешнего мира: S3 этим путём не трогается ---------------------------------
const s3 = {};
const audit = new AuditService(prisma);
const auth = new AuthService(prisma, audit, new ChangesService(prisma));
const media = new MediaService(prisma, s3, auth);

const LOGIN_PREFIX = 'check-timeline-';

/** Убрать всё, что оставили прошлые прогоны этой проверки (в т.ч. упавшие). */
async function cleanup() {
  const users = await prisma.user.findMany({
    where: { login: { startsWith: LOGIN_PREFIX } },
    select: { id: true, rootFolderId: true },
  });
  for (const u of users) {
    const folders = await prisma.folder.findMany({
      where: { OR: [{ id: u.rootFolderId ?? '' }, { parentId: u.rootFolderId ?? '' }] },
      select: { id: true },
    });
    const ids = folders.map((f) => f.id);
    const entries = await prisma.fileEntry.findMany({ where: { folderId: { in: ids } }, select: { assetId: true } });
    await prisma.fileEntry.deleteMany({ where: { folderId: { in: ids } } });
    await prisma.folder.deleteMany({ where: { id: { in: ids } } });
    await prisma.asset.deleteMany({ where: { id: { in: entries.map((e) => e.assetId) } } });
    await prisma.user.delete({ where: { id: u.id } });
  }
}

await cleanup();

const stamp = Date.now();
const userId = randomUUID();
const rootId = randomUUID();
const photoId = randomUUID();
const filesId = randomUUID();

/** Записи ленты: датированные, пачка с одной секундой съёмки и хвост без даты. */
const day = 86400000;
const rows = [];
// 30 датированных записей — по одной на разные дни, то есть несколько месяцев подряд
for (let i = 0; i < 30; i++) {
  rows.push({
    kind: 'датированные',
    folderId: photoId,
    zone: 'PHOTOS',
    name: `dated-${i}.jpg`,
    capturedAt: new Date(Date.UTC(2024, 0, 1) + i * 3 * day),
  });
}
// 10 записей с одной и той же секундой съёмки: без тай-брейка по id они рвутся на границе страницы
const sameSecond = new Date(Date.UTC(2024, 5, 15, 12, 0, 0));
for (let i = 0; i < 10; i++) {
  rows.push({ kind: 'одна секунда', folderId: photoId, zone: 'PHOTOS', name: `same-${i}.jpg`, capturedAt: sameSecond });
}
// 4 записи без даты съёмки — хвост ленты
for (let i = 0; i < 4; i++) {
  rows.push({ kind: 'без даты', folderId: photoId, zone: 'PHOTOS', name: `nodate-${i}.jpg`, capturedAt: null });
}
// мимо ленты: файлы вне зоны «Фото» и удалённая запись
for (let i = 0; i < 3; i++) {
  rows.push({ kind: 'вне зоны', folderId: filesId, zone: 'FILES', name: `files-${i}.jpg`, capturedAt: new Date() });
}
rows.push({ kind: 'удалённая', folderId: photoId, zone: 'PHOTOS', name: 'deleted.jpg', capturedAt: new Date(), deletedAt: new Date() });

/** Лента должна идти по убыванию даты, а записи без даты — в самом конце. */
function sortProblem(list) {
  let sawNull = false;
  for (let i = 0; i < list.length; i++) {
    const t = list[i].capturedAt ? Date.parse(list[i].capturedAt) : null;
    if (t === null) {
      sawNull = true;
      continue;
    }
    if (sawNull) return `датированная запись после записи без даты (#${i})`;
    if (i > 0 && list[i - 1].capturedAt && Date.parse(list[i - 1].capturedAt) < t) {
      return `порядок сломан на #${i}: ${list[i - 1].capturedAt} → ${list[i].capturedAt}`;
    }
  }
  return null;
}

try {
  await prisma.user.create({ data: { id: userId, login: `${LOGIN_PREFIX}${stamp}`, passwordHash: 'x' } });
  await prisma.folder.create({ data: { id: rootId, name: 'root', zone: 'FILES' } });
  await prisma.folder.create({ data: { id: photoId, parentId: rootId, name: 'Фото', zone: 'PHOTOS' } });
  await prisma.folder.create({ data: { id: filesId, parentId: rootId, name: 'Файлы', zone: 'FILES' } });
  await prisma.user.update({ where: { id: userId }, data: { rootFolderId: rootId, photoFolderId: photoId } });

  for (const [i, r] of rows.entries()) {
    const assetId = randomUUID();
    await prisma.asset.create({
      data: { id: assetId, sha256: createHash('sha256').update(`${LOGIN_PREFIX}${stamp}-${i}`).digest('hex'), size: 1n, mime: 'image/jpeg', masterReadyAt: new Date() },
    });
    await prisma.mediaMeta.create({ data: { assetId, capturedAt: r.capturedAt } });
    await prisma.fileEntry.create({
      data: { id: randomUUID(), folderId: r.folderId, assetId, name: r.name, zone: r.zone, deletedAt: r.deletedAt ?? null },
    });
  }

  // В ленте ожидаются только датированные + одна секунда + без даты (44), но не файлы
  // вне зоны «Фото» и не удалённая запись.
  const expected = 30 + 10 + 4;

  // === 1. пагинация разными страницами: ничего не теряется и не дублируется ==============
  for (const pageSize of [1, 7, 25, 300]) {
    const seen = [];
    const seenItems = [];
    let cursor;
    let guard = 0;
    for (;;) {
      const page = await media.timeline(userId, pageSize, cursor);
      if (!page.length) break;
      if (++guard > 200) break; // пагинация не сошлась: не крутимся вечно
      seen.push(...page.map((p) => p.entryId));
      seenItems.push(...page);
      cursor = page[page.length - 1].entryId;
    }
    const uniq = new Set(seen);
    check(`лимит ${pageSize}: вся лента`, seen.length === expected && guard <= 200, `получено ${seen.length}, ожидалось ${expected}`);
    check(`лимит ${pageSize}: без дубликатов`, uniq.size === seen.length, `дубликатов ${seen.length - uniq.size}`);
    const problem = sortProblem(seenItems);
    check(`лимит ${pageSize}: порядок`, problem === null, problem ?? '');
  }

  // === 2. лента целиком: порядок и хвост без даты ========================================
  const all = await media.timeline(userId, 1000);
  const orderProblem = sortProblem(all);
  check('порядок по убыванию даты', orderProblem === null, orderProblem ?? '');
  check('хвост без даты в конце', all.filter((f) => !f.capturedAt).length === 4, `без даты ${all.filter((f) => !f.capturedAt).length} из ${all.length}`);

  // === 3. вырожденные курсоры ============================================================
  /** Протухший курсор — это 409 cursor_stale, а не пустая страница (см. заголовок файла). */
  async function staleCursor(cursorId) {
    try {
      await media.timeline(userId, 10, cursorId);
      return 'страница отдана';
    } catch (e) {
      const status = typeof e?.getStatus === 'function' ? e.getStatus() : null;
      const code = e?.getResponse?.()?.code ?? null;
      return status === 409 && code === 'cursor_stale' ? null : `status ${status}, code ${code}`;
    }
  }
  const nobody = await staleCursor(randomUUID());
  check('несуществующий курсор → 409 cursor_stale', nobody === null, nobody ?? '');

  // курсор чужой записи (вне зоны «Фото») лентой не считается
  const foreign = await prisma.fileEntry.findFirst({ where: { folderId: filesId }, select: { id: true } });
  const foreignProblem = await staleCursor(foreign.id);
  check('курсор вне зоны «Фото» → 409 cursor_stale', foreignProblem === null, foreignProblem ?? '');

  // === 4. статусы превью по списку id ====================================================
  const firstPage = await media.timeline(userId, 5);
  const own = firstPage[0].entryId;
  const statuses = await media.timelineStatus(userId, [own, randomUUID(), foreign.id]);
  check('статусы: своя запись пришла', statuses.length === 1 && statuses[0].entryId === own, `записей ${statuses.length}`);
  check('статусы: чужая и несуществующая отброшены', !statuses.some((s) => s.entryId !== own), '');
  check('статусы: превью считается готовым', statuses.length === 1 && statuses[0].masterReady === true, JSON.stringify(statuses[0] ?? null));
} finally {
  await cleanup();
  await prisma.$disconnect();
}

console.log(failures ? `\n${failures} проверок упало` : '\nвсе проверки прошли');
process.exit(failures ? 1 : 0);
