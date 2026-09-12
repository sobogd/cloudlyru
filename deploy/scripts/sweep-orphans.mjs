// Уборка «зомби»-объектов в бакете: ключи, на которые не ссылается ни один Asset в БД.
//
// Зачем: purge корзины удаляет объекты только по строкам Asset. Если строка исчезла
// иначе (сброс/пересоздание БД локального инстанса, ручной SQL, потеря БД), объект
// остаётся в бакете навсегда — приложению его уже ничто не напомнит. Такие объекты
// и создают картину «удалил и очистил корзину, а файлы в S3 остались».
//
// Запуск из каталога приложения (там же node_modules с @aws-sdk и @prisma/client),
// переменные — из .env приложения:
//   node deploy/scripts/sweep-orphans.mjs                 # только показать (dry-run)
//   node deploy/scripts/sweep-orphans.mjs --apply         # удалить
//   node deploy/scripts/sweep-orphans.mjs --min-age-hours=48 --apply
//
// По умолчанию не трогает объекты моложе 24 часов: при загрузке файл сначала
// копируется в files/<sha>, и только потом создаётся строка Asset — молодой объект
// без строки это нормальная загрузка «в полёте», а не мусор.
// Префикс db/ (дампы БД) не трогается никогда.
import { PrismaClient } from '@prisma/client';
import {
  S3Client,
  ListObjectsV2Command,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';

const args = process.argv.slice(2);
const apply = args.includes('--apply');
const force = args.includes('--force');
const minAgeArg = args.find((a) => a.startsWith('--min-age-hours='));
const MIN_AGE_HOURS = minAgeArg ? Number(minAgeArg.split('=')[1]) : 24;
if (!Number.isFinite(MIN_AGE_HOURS) || MIN_AGE_HOURS < 0) {
  console.error('[sweep] некорректный --min-age-hours');
  process.exit(2);
}

const bucket = process.env.S3_FILES_BUCKET;
if (!bucket || !process.env.S3_FILES_ACCESS_KEY || !process.env.S3_FILES_SECRET_KEY) {
  console.error('[sweep] нет S3_FILES_BUCKET / S3_FILES_ACCESS_KEY / S3_FILES_SECRET_KEY');
  process.exit(2);
}
if (!process.env.DATABASE_URL) {
  console.error('[sweep] нет DATABASE_URL');
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

// Производные медиа (view/<sha><суффикс>) — список из MediaService.derivativeKeys().
// Плюс превью страниц PDF: view/<sha>-p<N>-1080.webp — их число переменно, поэтому шаблон.
const SUFFIXES = [
  '-512.webp',
  '-2048.avif',
  '-poster.webp',
  '-1080.mp4',
  '-2048.webp',
  '-720.mp4',
  '.avif',
  '.mp4',
  '.webp',
  '',
];
const PAGE_KEY = /-p\d+-1080\.webp$/;

// Префикс ключей инстанса (S3_FILES_PREFIX): у прода пусто, у dev/тестов свой.
const PREFIX = (process.env.S3_FILES_PREFIX || '').trim().replace(/^\/+/, '').replace(/\/+$/, '');
const PREFIXED = PREFIX ? `${PREFIX}/` : '';

/** sha256 из ключа объекта; null — если ключ не наш (чужой префикс/формат). */
function shaOf(key) {
  if (key.startsWith('files/')) {
    const sha = key.slice('files/'.length);
    return /^[0-9a-f]{64}$/.test(sha) ? sha : null;
  }
  if (key.startsWith('view/')) {
    const rest = key.slice('view/'.length);
    // страницы PDF: view/<sha>-p<N>-1080.webp (суффиксов переменное число)
    const page = PAGE_KEY.exec(rest);
    if (page) {
      const sha = rest.slice(0, page.index);
      return /^[0-9a-f]{64}$/.test(sha) ? sha : null;
    }
    for (const sfx of SUFFIXES) {
      if (sfx && rest.endsWith(sfx)) {
        const sha = rest.slice(0, -sfx.length);
        return /^[0-9a-f]{64}$/.test(sha) ? sha : null;
      }
    }
    return null;
  }
  return null;
}

const prisma = new PrismaClient();
let assets;
try {
  assets = await prisma.asset.findMany({ select: { sha256: true } });
} finally {
  await prisma.$disconnect();
}

// Страховка от «пустой БД» (неверный DATABASE_URL): иначе снесём весь бакет.
if (assets.length === 0 && !force) {
  console.error('[sweep] в БД нет ни одного Asset — похоже на неверный DATABASE_URL. Стоп (--force чтобы продолжить).');
  process.exit(3);
}
const known = new Set(assets.map((a) => a.sha256));
console.log(`[sweep] бакет ${bucket}${PREFIXED ? `, префикс ${PREFIXED}` : ''}, Asset в БД: ${known.size}`);

const all = [];
let token;
do {
  const out = await s3.send(
    new ListObjectsV2Command({ Bucket: bucket, ContinuationToken: token, MaxKeys: 1000 }),
  );
  for (const o of out.Contents ?? []) all.push(o);
  token = out.IsTruncated ? out.NextContinuationToken : undefined;
} while (token);

const cutoff = new Date(Date.now() - MIN_AGE_HOURS * 3600 * 1000);
const young = (o) => o.LastModified && o.LastModified > cutoff;

const orphans = { master: [], view: [], tmp: [], unknown: [] };
for (const o of all) {
  const full = o.Key ?? '';
  // Чужие префиксы (в т.ч. объекты другого инстанса) не трогаем вообще.
  if (PREFIXED && !full.startsWith(PREFIXED)) continue;
  const key = PREFIXED ? full.slice(PREFIXED.length) : full;
  if (key.startsWith('db/')) continue; // дампы БД — не наше дело
  if (young(o)) continue; // свежие объекты могут быть загрузкой «в полёте»
  if (key.startsWith('files/tmp/')) {
    orphans.tmp.push(o);
    continue;
  }
  const sha = shaOf(key);
  if (!sha) {
    orphans.unknown.push(o);
    continue;
  }
  if (known.has(sha)) continue;
  (key.startsWith('view/') ? orphans.view : orphans.master).push(o);
}

const total = orphans.master.length + orphans.view.length + orphans.tmp.length;
const bytes = [...orphans.master, ...orphans.view, ...orphans.tmp].reduce(
  (s, o) => s + Number(o.Size ?? 0),
  0,
);
console.log(`[sweep] объектов всего: ${all.length}; моложе ${MIN_AGE_HOURS} ч пропущено`);
console.log(
  `[sweep] осиротевших: ${total} (${(bytes / 1e6).toFixed(2)} МБ) — ` +
    `оригиналы ${orphans.master.length}, производные ${orphans.view.length}, незавершённые загрузки ${orphans.tmp.length}`,
);
for (const list of [orphans.master, orphans.view, orphans.tmp]) {
  for (const o of list.slice(0, 10)) {
    console.log(`  ${o.LastModified?.toISOString()} ${(Number(o.Size) / 1e6).toFixed(2)} МБ ${o.Key}`);
  }
  if (list.length > 10) console.log(`  … ещё ${list.length - 10}`);
}
if (orphans.unknown.length) {
  console.log(`[sweep] непонятных ключей (не трогаю): ${orphans.unknown.length}`);
  for (const o of orphans.unknown.slice(0, 10)) console.log(`  ${o.Key}`);
}

const toDelete = [...orphans.master, ...orphans.view, ...orphans.tmp];
if (!apply) {
  console.log('[sweep] dry-run: ничего не удалено. Для удаления — --apply');
} else if (!toDelete.length) {
  console.log('[sweep] нечего удалять');
} else {
  // Перед удалением перепроверяем БД: за время обхода бакета (десятки секунд) у объекта
  // могла появиться строка Asset — например у только что загруженного файла. Такие пропускаем.
  const candidateShas = [
    ...new Set(toDelete.map((o) => shaOf(PREFIXED ? o.Key.slice(PREFIXED.length) : o.Key)).filter(Boolean)),
  ];
  const appeared = new Set();
  const prisma2 = new PrismaClient();
  try {
    for (let i = 0; i < candidateShas.length; i += 5000) {
      const rows = await prisma2.asset.findMany({
        where: { sha256: { in: candidateShas.slice(i, i + 5000) } },
        select: { sha256: true },
      });
      for (const r of rows) appeared.add(r.sha256);
    }
  } finally {
    await prisma2.$disconnect();
  }
  const finalList = toDelete.filter((o) => {
    const key = PREFIXED ? o.Key.slice(PREFIXED.length) : o.Key;
    return !key.startsWith('files/tmp/') ? !appeared.has(shaOf(key)) : true;
  });
  if (appeared.size) console.log(`[sweep] пропустил ${toDelete.length - finalList.length}: пока шёл обход, у объекта появилась строка в БД`);

  let deleted = 0;
  const failed = [];
  for (let i = 0; i < finalList.length; i += 1000) {
    const chunk = finalList.slice(i, i + 1000).map((o) => ({ Key: o.Key }));
    const out = await s3.send(new DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: chunk } }));
    deleted += out.Deleted?.length ?? 0;
    for (const e of out.Errors ?? []) failed.push(`${e.Key} (${e.Code ?? '?'})`);
  }
  console.log(`[sweep] удалено объектов: ${deleted}`);
  if (failed.length) {
    console.log(`[sweep] НЕ удалось удалить ${failed.length}:`);
    for (const f of failed.slice(0, 10)) console.log(`  ${f}`);
  }
}

s3.destroy();
