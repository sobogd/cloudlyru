// Доразбор метаданных у уже загруженных фото и видео.
//
// Зачем: разбор обрезанного начала файла (512 КБ) считался успешным, поэтому у HEIC/HEIF
// метаданные не читались никогда — в «Инфо» у фото не было ни даты, ни камеры, ни кадра,
// а у видео не было длительности и кодеков (ffprobe ходил по presigned-ссылке, которая
// на сервере не резолвится). Код исправлен, но строки в БД остались пустыми: их надо
// переразобрать. Отдельные фото чинятся сами при открытии «Инфо» (ленивый разбор),
// этот скрипт делает то же самое пачкой и без ручного открытия каждого файла.
//
// Запуск без записи (только считает и показывает объём чтения из S3):
//   node scripts/backfill-media-meta.mjs
// Запись (по умолчанию только фото — они читаются кусками по мегабайтам):
//   node scripts/backfill-media-meta.mjs --write
// Видео тоже (каждый файл качается целиком — это часы и терабайты):
//   node scripts/backfill-media-meta.mjs --write --videos
// Только файлы без даты съёмки — самый заметный дефект (лента и поездки) и в разы меньше чтения:
//   node scripts/backfill-media-meta.mjs --write --no-date
// Пробный прогон на нескольких файлах:
//   node scripts/backfill-media-meta.mjs --write --limit 20
//
// Требуется DATABASE_URL и доступ к S3 (ключи в .env приложения) и собранный dist.
import { PrismaClient } from '@prisma/client';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const dist = (p) => require(new URL(`../dist/${p}`, import.meta.url).pathname);

const { MediaService, IMAGE_MIMES, VIDEO_MIMES, hasUsefulRaw } = dist('media/media.service.js');
const { S3Service } = dist('s3/s3.service.js');

const WRITE = process.argv.includes('--write');
const WITH_VIDEO = process.argv.includes('--videos');
const ONLY_NO_DATE = process.argv.includes('--no-date');
const limitArg = process.argv.indexOf('--limit');
const LIMIT = limitArg > -1 ? Number(process.argv[limitArg + 1]) || 0 : 0;
/** Сколько файлов разбираем одновременно: каждое чтение — запрос в S3 на мегабайты. */
const CONCURRENCY = 4;
/**
 * Сколько байт уйдёт на разбор одного файла: фото читается началом, а если тегов в начале нет —
 * ещё раз целиком; видео скачивается целиком. Оценка нужна, чтобы прогон не оказался сюрпризом.
 */
const HEAD_BYTES = 4 * 1024 * 1024;
const readBytes = (row) => {
  const size = Number(row.size);
  if (VIDEO_MIMES.includes(row.mime)) return size;
  return size <= HEAD_BYTES ? size : size + HEAD_BYTES;
};

const prisma = new PrismaClient();
const media = new MediaService(prisma, new S3Service(), { rootFolderId: async () => null });

const gb = (bytes) => (bytes < 1024 ** 3 ? `${Math.round(bytes / 1024 ** 2)} МБ` : `${(bytes / 1024 ** 3).toFixed(1)} ГБ`);

/** Все живые медиа-ассеты и то, что уже разобрано у каждого. */
async function candidates() {
  const mimes = WITH_VIDEO ? [...IMAGE_MIMES, ...VIDEO_MIMES] : IMAGE_MIMES;
  const rows = await prisma.asset.findMany({
    where: {
      mime: { in: mimes },
      entries: { some: { deletedAt: null } }, // удалённое и сироты не чиним: открывать их негде
    },
    select: {
      id: true,
      sha256: true,
      mime: true,
      size: true,
      media: { select: { raw: true, capturedAt: true } },
    },
    orderBy: { createdAt: 'desc' },
  });
  const need = rows.filter((r) => !hasUsefulRaw(r.media?.raw));
  // Без даты съёмки — это файлы, у которых лента, поездки и карта стоят не на своём месте
  return ONLY_NO_DATE ? need.filter((r) => !r.media?.capturedAt) : need;
}

async function main() {
  const all = await candidates();
  const queue = LIMIT ? all.slice(0, LIMIT) : all;

  const byMime = new Map();
  for (const r of all) byMime.set(r.mime, (byMime.get(r.mime) ?? 0) + 1);
  console.log(`без подробных метаданных: ${all.length} из живых медиа-ассетов${WITH_VIDEO ? '' : ' (без видео — добавьте --videos)'}`);
  for (const [mime, n] of [...byMime.entries()].sort((a, b) => b[1] - a[1])) console.log(`  ${mime}: ${n}`);
  console.log(`из них с датой съёмки (остались без камеры/кадров/тегов): ${all.filter((r) => r.media?.capturedAt).length}`);
  console.log(`чтения из S3 на весь прогон: ≈${gb(queue.reduce((sum, r) => sum + readBytes(r), 0))}`);

  if (!WRITE) {
    console.log('\nпример (ничего не меняем):');
    for (const r of queue.slice(0, 8)) {
      const state = r.media ? `raw=${JSON.stringify(r.media.raw).slice(0, 40)}` : 'строки MediaMeta нет';
      console.log(`  ${r.mime} ${Number(r.size)} байт ${r.sha256.slice(0, 8)}… — ${state}`);
    }
    console.log('\nэто прогон без записи. Для записи: node scripts/backfill-media-meta.mjs --write');
    return;
  }

  let done = 0;
  let repaired = 0;
  let failed = 0;
  let i = 0;
  const workers = Array.from({ length: Math.min(CONCURRENCY, queue.length) }, async () => {
    for (;;) {
      const row = queue[i++];
      if (!row) return;
      try {
        await media.extractDetail(row.id, row.sha256, Number(row.size), row.mime);
        const after = await prisma.mediaMeta.findUnique({ where: { assetId: row.id }, select: { raw: true } });
        if (hasUsefulRaw(after?.raw)) repaired += 1;
        else failed += 1;
      } catch (e) {
        failed += 1;
        if (failed < 5) console.error(`  ${row.sha256.slice(0, 8)}…: ${e.message}`);
      }
      done += 1;
      if (done % 200 === 0) console.log(`  обработано ${done} из ${queue.length} (починено ${repaired}, без метаданных ${failed})`);
    }
  });
  await Promise.all(workers);

  console.log(`\nготово: обработано ${done}, починено ${repaired}, без метаданных ${failed}`);
  if (failed) {
    console.log('«без метаданных» — это файлы, в которых тегов нет вообще (скриншоты, мессенджеры, AVIF без EXIF)');
    console.log('либо объект оригинала уже удалён из S3 — повторный прогон их не изменит.');
  }
}

main()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
