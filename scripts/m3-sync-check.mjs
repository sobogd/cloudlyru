// Проверка контракта синхронизации (M3.0/M3.1) на локальной БД без S3 и без сервера.
//
// Запуск (из каталога приложения, там же node_modules и собранный dist):
//   DATABASE_URL=postgresql://user@127.0.0.1:5432/cloudly_dev SESSION_SECRET=dev-secret-0123456789 \
//     node scripts/m3-sync-check.mjs
//
// Что проверяется: создание/перезапись записи в дереве, журнал изменений (create/update/
// move/pin/delete/restore), tombstones после очистки корзины, GC осиротевших ассетов,
// идемпотентный ensure-path и его лимиты, пагинация и resetRequired курсора, /sync/have,
// проброс replace/clientMtime через HTTP-контроллер загрузки.
//
// Скрипт создаёт свои данные под корнем администратора и удаляет их в конце.
import { PrismaClient } from '@prisma/client';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const dist = (p) => require(new URL(`../dist/${p}`, import.meta.url).pathname);

const { AuthService } = dist('auth/auth.service.js');
const { AuditService } = dist('audit/audit.service.js');
const { ChangesService } = dist('sync/changes.service.js');
const { SyncService } = dist('sync/sync.service.js');
const { FilesService } = dist('files/files.service.js');
const { FoldersService } = dist('folders/folders.service.js');
const { TrashService } = dist('trash/trash.service.js');
const { UploadsController } = dist('uploads/uploads.controller.js');
const { UploadsService, firstMissingPart } = dist('uploads/uploads.service.js');
const { STORAGE_HOST } = dist('config/env.js');

const prisma = new PrismaClient();

let failures = 0;
function check(name, ok, extra = '') {
  const mark = ok ? '  ok  ' : ' FAIL ';
  if (!ok) failures += 1;
  console.log(`[${mark}] ${name}${extra ? ` — ${extra}` : ''}`);
}

// --- заглушки внешнего мира: S3, медиа, очередь -------------------------------------------
const s3Deleted = [];
const s3 = {
  headObject: async () => false,
  objectSize: async () => 0,
  deleteObjects: async (keys) => {
    s3Deleted.push(...keys);
    return [];
  },
  deleteObject: async () => {},
  copyObject: async () => {},
  putObject: async () => {},
  presignedGet: async () => '',
  createMultipartUpload: async () => 's3-init',
  abortMultipartUpload: async () => {},
};
const media = { captureMeta: async () => {}, extractDetail: async () => {}, captureAny: async () => {} };
const queue = { enqueue: async () => {}, cancelForAssets: async () => {}, requeueForAssets: async () => {}, previewsAlive: async () => false };

const audit = new AuditService(prisma);
const auth = new AuthService(prisma, audit);
const changes = new ChangesService(prisma);
const files = new FilesService(prisma, s3, media, auth, changes, queue);
const folders = new FoldersService(prisma, auth, media, queue, changes);
const trash = new TrashService(prisma, s3, folders, files, auth, changes, audit);
const sync = new SyncService(prisma, auth);

// владелец, корневая папка и «Фото» создаются при старте приложения — здесь тот же сид
await auth.onModuleInit();

const user = await prisma.user.findFirstOrThrow();
const rootId = await auth.rootFolderId(user.id);
const sha = (ch) => ch.repeat(64).slice(0, 64);
const mkAsset = (ch, size = 10) =>
  prisma.asset.upsert({
    where: { sha256: sha(ch) },
    create: { sha256: sha(ch), size: BigInt(size), mime: 'text/plain' },
    update: {},
  });
const head = async (n = 1) => {
  const rows = await prisma.changeLog.findMany({ where: { userId: user.id }, orderBy: { seq: 'desc' }, take: n });
  return rows.reverse();
};

const cleanupFolders = [];
const sessionIds = [];
try {
  // === 1. ensure-path: идемпотентность, лимиты, журнал ====================================
  const made = await folders.ensurePath(user.id, 'm3-check/2025/07');
  cleanupFolders.push(made.id);
  check('ensure-path создаёт отсутствующие сегменты', made.created === 3, `created=${made.created}`);
  const again = await folders.ensurePath(user.id, 'm3-check/2025/07');
  check('ensure-path идемпотентен', again.created === 0 && again.id === made.id);
  const tooDeep = await folders
    .ensurePath(user.id, Array.from({ length: 40 }, (_, i) => `d${i}`).join('/'))
    .then(() => null)
    .catch((e) => e);
  check('ensure-path режет слишком длинный путь', Boolean(tooDeep) && tooDeep.status === 400, tooDeep?.message);
  const reserved = await folders.ensurePath(user.id, '__root__').then(() => null).catch((e) => e);
  check('ensure-path не создаёт зарезервированный корень', reserved === null || Boolean(reserved));

  // === 2. createEntry: create → replace → конфликты =======================================
  const a1 = await mkAsset('d');
  const a2 = await mkAsset('e');
  const folderId = cleanupFolders[0];
  const first = await files.createEntry(folderId, 'x.bin', a1.id, {
    userId: user.id,
    asset: { sha256: a1.sha256, size: 10, mime: 'text/plain' },
  });
  check('createEntry создаёт запись', Boolean(first.id) && !first.replaced);
  const dup = await files.createEntry(folderId, 'x.bin', a2.id, { userId: user.id }).catch((e) => e);
  check('без replace — 409', dup?.status === 409, String(dup?.message));

  s3Deleted.length = 0;
  const replaced = await files.createEntry(folderId, 'x.bin', a2.id, {
    userId: user.id,
    replace: true,
    asset: { sha256: a2.sha256, size: 10, mime: 'text/plain' },
  });
  check('replace сохраняет id записи', replaced.id === first.id && replaced.replaced);
  const oldAssetGone = (await prisma.asset.findUnique({ where: { id: a1.id } })) === null;
  check('осиротевший ассет удалён из БД', oldAssetGone);
  check('объекты осиротевшего ассета ушли в S3', s3Deleted.includes(`files/${sha('d')}`), `ключей ${s3Deleted.length}`);

  // журнал: create + update с новым sha
  const log = await prisma.changeLog.findMany({ where: { targetId: first.id }, orderBy: { seq: 'asc' } });
  check('журнал: create и update', log.map((l) => l.op).join(',') === 'create,update', log.map((l) => l.op).join(','));
  check('журнал: update несёт новый sha', log[1]?.sha256 === sha('e') && log[1]?.size === 10n);

  // === 3. перезапись записи из корзины ====================================================
  await files.softDelete(first.id, user.id);
  // a1 уже удалён сборщиком выше — для проверки возврата из корзины нужен живой ассет
  const a3 = await mkAsset('f');
  const restoreAttempt = await files.createEntry(folderId, 'x.bin', a3.id, { userId: user.id, replace: true }).catch((e) => e);
  check('replace не воскрешает удалённое (409)', restoreAttempt?.status === 409, String(restoreAttempt?.message));
  const davLike = await files.createEntry(folderId, 'x.bin', a3.id, { userId: user.id, replace: true, restoreDeleted: true });
  check('WebDAV-режим возвращает из корзины', davLike.replaced === true);

  // === 3.1 строгая перезапись: предполётное условие =======================================
  const a5 = await mkAsset('b');
  const a6 = await mkAsset('c');
  // восстановили запись (шаг 3) — она ссылается на a3 (sha «f»)
  const stale = await files
    .createEntry(folderId, 'x.bin', a5.id, { userId: user.id, replace: true, expect: { sha256: sha('b') } })
    .catch((e) => e);
  // код ошибки лежит в теле ответа (HttpException), а не в самом объекте ошибки
  const staleBody = stale?.getResponse?.() ?? {};
  check('stale: не та версия → 409 stale_version', staleBody.statusCode === 409 && staleBody.code === 'stale_version', String(staleBody.code));
  check('stale: в ответе снимок текущей версии', typeof staleBody.sha256 === 'string' && staleBody.sha256 === sha('f'), String(staleBody.sha256));
  const okVersion = await files.createEntry(folderId, 'x.bin', a6.id, {
    userId: user.id,
    replace: true,
    expect: { sha256: sha('f') },
    asset: { sha256: a6.sha256, size: 10, mime: 'text/plain' },
  });
  check('stale: верная версия проходит', okVersion.replaced === true);
  const expectMissing = await files
    .createEntry(folderId, 'нет-такого.bin', a5.id, { userId: user.id, expect: { sha256: sha('b') } })
    .catch((e) => e);
  const missingBody = expectMissing?.getResponse?.() ?? {};
  check('stale: ждали запись, её нет → 409', missingBody.statusCode === 409 && missingBody.code === 'stale_version', String(missingBody.code));
  // === 4. journal: move / restore ========================================================
  const dest = await folders.ensurePath(user.id, 'm3-check/other');
  cleanupFolders.push(dest.id);
  const moved = await files.patch(first.id, user.id, { folderId: dest.id, name: 'y.bin', clientMtime: '2026-09-01T10:00:00.000Z' });
  check('patch: перенос + переименование', moved.changed && moved.entry.name === 'y.bin' && moved.entry.folderId === dest.id);
  check('patch: clientMtime записан', moved.entry.clientMtime instanceof Date);
  // одно событие на правку: op — подсказка, клиент применяет снимок целиком,
  // поэтому перенос+переименование приходят как move с новым именем в снимке
  const lastMove = (await head(1))[0];
  check('journal: перенос записан как move', lastMove.target === 'entry' && lastMove.op === 'move', `${lastMove.target}:${lastMove.op}`);
  check('journal: снимок несёт новое имя', lastMove.name === 'y.bin');

  const restoredFolder = await folders.ensurePath(user.id, 'm3-check/tree/inner');
  cleanupFolders.push(restoredFolder.id);
  const a4 = await mkAsset('a');
  const inTree = await files.createEntry(restoredFolder.id, 'z.bin', a4.id, { userId: user.id });
  const parentId = (await prisma.folder.findUniqueOrThrow({ where: { id: restoredFolder.id } })).parentId;
  await folders.softDelete(parentId, user.id);
  const delOps = (await head(1)).map((c) => `${c.target}:${c.op}`);
  check('journal: удаление папки одним событием', delOps[0] === 'folder:delete', delOps.join(','));
  await folders.restore(parentId, user.id);
  const restoreRows = await prisma.changeLog.findMany({ where: { userId: user.id, targetId: { in: [parentId, restoredFolder.id, inTree.id] } }, orderBy: { seq: 'asc' } });
  const restoreIds = restoreRows.filter((r) => r.op === 'restore').map((r) => r.targetId);
  check('journal: восстановление папки пишет и детей', restoreIds.includes(restoredFolder.id) && restoreIds.includes(inTree.id), restoreIds.join(','));

  // === 5. курсор: пагинация, hasMore, resetRequired, границы ==============================
  const page1 = await sync.changes(user.id, '0', '2');
  check('changes: пагинация с hasMore', page1.changes.length === 2 && page1.hasMore === true, `nextSeq=${page1.nextSeq}`);
  const page2 = await sync.changes(user.id, page1.nextSeq, '500');
  check('changes: продолжение с курсора', page2.changes.length > 0 && BigInt(page2.changes[0].seq) > BigInt(page1.nextSeq));
  const resetAhead = await sync.changes(user.id, '999999999999', '10');
  check('changes: reset при курсоре впереди журнала', resetAhead.resetRequired === true);
  const garbage = await sync.changes(user.id, 'abc', '10');
  check('changes: мусор в since не роняет', garbage.since === '0' && garbage.resetRequired === false);
  const bigSeq = await sync.changes(user.id, '99999999999999999999', '10');
  check('changes: seq вне BIGINT обрабатывается', bigSeq.since === '0');
  const badLimit = await sync.changes(user.id, '0', '-5');
  check('changes: отрицательный limit → дефолт', badLimit.changes.length <= 200);

  // === 6. /sync/have =====================================================================
  const haveLive = await sync.have(user.id, [sha('c')]);
  check('have: своё живое содержимое подтверждается', haveLive.present.length === 1);
  const foreign = await sync.have(user.id, [sha('9')]);
  check('have: неизвестное содержимое не подтверждается', foreign.present.length === 0);
  const junk = await sync.have(user.id, ['не-хэш', 123, null]);
  check('have: мусор отбрасывается', junk.present.length === 0);
  await files.softDelete(moved.entry.id, user.id);
  const haveTrashed = await sync.have(user.id, [sha('c')]);
  check('have: содержимое только в корзине не считается «есть»', haveTrashed.present.length === 0);

  // === 7. purge: tombstones + осиротевшие ассеты =========================================
  const purged = await trash.purge(user.id, 0);
  check('purge отработал', purged.purgedEntries >= 1, JSON.stringify(purged));
  const entryRow = await prisma.fileEntry.findUnique({ where: { id: moved.entry.id } });
  check('purge физически удалил запись', entryRow === null);
  // важно последнее событие удаления: у записи их два — soft delete и tombstone от purg'а
  const tomb = await prisma.changeLog.findFirst({
    where: { targetId: moved.entry.id, op: 'delete' },
    orderBy: { seq: 'desc' },
  });
  check('purge оставил tombstone с именем', Boolean(tomb) && tomb.name === 'y.bin', `entry=${moved.entry.id} tomb=${tomb ? `${tomb.name}@${tomb.seq}` : 'нет'}`);

  // === 8. HTTP-граница загрузки: replace/clientMtime доезжают до сервиса ==================
  const captured = [];
  const controller = new UploadsController({ init: async (body) => (captured.push(body), { ok: true }) });
  await controller.init({ name: 'p.bin', size: 10, mime: 'text/plain', replace: true, clientMtime: '2026-09-01T10:00:00.000Z', mode: 'direct' }, { id: user.id, login: 'admin' });
  check('HTTP: replace доезжает до init', captured[0]?.replace === true);
  check('HTTP: clientMtime доезжает до init', captured[0]?.clientMtime === '2026-09-01T10:00:00.000Z');
  check('HTTP: mode доезжает до init', captured[0]?.mode === 'direct');

  // === 8b. Номера частей и хост хранилища ================================================
  // «Сколько принято» вместо «первой дырки» навсегда запирало сессию: параллельный батч
  // терял часть, счётчик уезжал за дырку, и complete вечно отвечал 400 «missing part N».
  check('nextPart: первая пропущенная часть, а не счётчик', firstMissingPart([1, 3], 4) === 2, `→ ${firstMissingPart([1, 3], 4)}`);
  check('nextPart: дырка в начале', firstMissingPart([2, 3], 3) === 1, `→ ${firstMissingPart([2, 3], 3)}`);
  check('nextPart: ничего не принято', firstMissingPart([], 2) === 1, `→ ${firstMissingPart([], 2)}`);
  check('nextPart: принято всё → на единицу больше', firstMissingPart([1, 2, 3], 3) === 4, `→ ${firstMissingPart([1, 2, 3], 3)}`);
  check(
    'клиент узнаёт хост хранилища при старте загрузки',
    typeof STORAGE_HOST === 'string' && STORAGE_HOST.length > 0,
    STORAGE_HOST,
  );

  // Сессия с «дыркой» в принятых частях: ровно тот случай, когда счётчик врал и complete
  // потом вечно отвечал 400 «missing part N».
  const uploads = new UploadsService(prisma, s3, files, auth, media, queue);
  const gappy = await prisma.uploadSession.create({
    data: {
      userId: user.id,
      folderId: cleanupFolders[0],
      name: 'gappy.bin',
      size: BigInt(3 * 16 * 1024 * 1024),
      mime: 'application/octet-stream',
      uploadKey: 'tmp/gappy.bin',
      s3UploadId: 's3-gappy',
      direct: true,
      parts: [
        { partNumber: 1, etag: 'a', size: 16 * 1024 * 1024 },
        { partNumber: 3, etag: 'c', size: 16 * 1024 * 1024 },
      ],
    },
  });
  const gappyStatus = await uploads.status(gappy.id, user.id);
  check('status: продолжать с первой пропущенной части', gappyStatus.nextPart === 2, `nextPart=${gappyStatus.nextPart}`);
  const full = await prisma.uploadSession.create({
    data: {
      userId: user.id,
      folderId: cleanupFolders[0],
      name: 'full.bin',
      size: BigInt(2 * 16 * 1024 * 1024),
      mime: 'application/octet-stream',
      uploadKey: 'tmp/full.bin',
      s3UploadId: 's3-full',
      direct: true,
      parts: [
        { partNumber: 1, etag: 'a', size: 16 * 1024 * 1024 },
        { partNumber: 2, etag: 'b', size: 16 * 1024 * 1024 },
      ],
    },
  });
  const fullStatus = await uploads.status(full.id, user.id);
  check('status: всё принято → следующей части нет', fullStatus.nextPart === 3, `nextPart=${fullStatus.nextPart}`);
  sessionIds.push(gappy.id, full.id);

  // Форма ответа init: хост хранилища нужен клиенту для диагностики DNS
  const inited = await uploads.init({ folderId: cleanupFolders[0], name: 'init-check.bin', size: 10, mime: 'text/plain', mode: 'relay' }, user.id);
  check('init отдаёт хост хранилища', inited.storageHost === STORAGE_HOST, String(inited.storageHost));
  await prisma.uploadSession.deleteMany({ where: { id: inited.uploadId } });

  // === 9. Схема: новые поля на месте =====================================================
  const cols = await prisma.$queryRawUnsafe(
    `SELECT table_name, column_name FROM information_schema.columns
     WHERE column_name IN ('updatedAt','clientMtime','completedAt','result','seq')
       AND table_name IN ('FileEntry','Folder','UploadSession','ChangeLog')`,
  );
  const colSet = new Set(cols.map((c) => `${c.table_name}.${c.column_name}`));
  for (const need of ['FileEntry.updatedAt', 'FileEntry.clientMtime', 'UploadSession.completedAt', 'UploadSession.result', 'ChangeLog.seq']) {
    check(`схема: ${need}`, colSet.has(need));
  }
} finally {
  // уборка: удаляем созданные папки вместе с содержимым (жёстко, минуя корзину)
  for (const id of cleanupFolders) {
    await prisma.fileEntry.deleteMany({ where: { folderId: id } }).catch(() => {});
    await prisma.folder.deleteMany({ where: { id } }).catch(() => {});
  }
  const top = await prisma.folder.findFirst({ where: { parentId: rootId, name: 'm3-check' } });
  if (top) {
    const subtree = await folders.collectSubtreeIds(top.id).catch(() => [top.id]);
    await prisma.fileEntry.deleteMany({ where: { folderId: { in: subtree } } }).catch(() => {});
    await prisma.folder.deleteMany({ where: { id: { in: subtree } } }).catch(() => {});
  }
  await prisma.uploadSession.deleteMany({ where: { id: { in: sessionIds } } }).catch(() => {});
  await prisma.changeLog.deleteMany({ where: { userId: user.id, targetId: { in: [] } } }).catch(() => {});
  await prisma.$disconnect();
}

console.log(failures ? `\n${failures} проверок упало` : '\nвсе проверки прошли');
process.exit(failures ? 1 : 0);
