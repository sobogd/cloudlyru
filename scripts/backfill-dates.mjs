// Восстановление дат у уже загруженных фото и видео.
//
// Зачем: импорт архивов Google Takeout не сохранял дату файла вообще, поэтому у ~92 тысяч
// записей в базе нет ни даты файла, ни даты съёмки. В самих архивах дат нет — Google при
// упаковке переписал их на время упаковки (проверено на архиве 53.7 ГБ: все 12 513 записей
// датированы днём упаковки, расширенных полей с unix-временем нет). Реальные источники:
//   1) сайдкар Takeout `<имя файла>.supplemental-metadata.json` рядом с файлом — есть у почти
//      каждого фото и видео, содержит photoTakenTime и geoData;
//   2) EXIF самого фото и контейнер видео (ffprobe) — есть не у всех (скриншоты, мессенджеры).
//
// Запуск без записи (только считает, ничего не меняет):
//   node scripts/backfill-dates.mjs
// Запись:
//   node scripts/backfill-dates.mjs --write            # из сайдкаров (быстро)
//   node scripts/backfill-dates.mjs --write --exif     # ещё и EXIF/ffprobe из файлов (долго)
//
// Требуется DATABASE_URL и доступ к S3 (ключи в .env приложения).
import { PrismaClient } from '@prisma/client';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const dist = (p) => require(new URL(`../dist/${p}`, import.meta.url).pathname);

const { S3Service } = dist('s3/s3.service.js');
const { mediaKey } = dist('unzip/s3-zip.js');
const { MediaService } = dist('media/media.service.js');

const WRITE = process.argv.includes('--write');
const WITH_EXIF = process.argv.includes('--exif');

const prisma = new PrismaClient();
const s3 = new S3Service();
const media = new MediaService(prisma, s3, { rootFolderId: async () => null });

const IMAGE = ['image/jpeg', 'image/heic', 'image/heif', 'image/png', 'image/webp', 'image/tiff', 'image/avif', 'image/gif'];
const VIDEO = ['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska', 'video/avi', 'video/ogg', 'video/mpeg'];

/**
 * Сайдкары: «имя целевого файла» → список записей сайдкаров. Одно и то же фото Google кладёт
 * в несколько папок (год и альбомы), поэтому искать только в своей папке нельзя — сопоставляем
 * по имени, предпочитая сайдкар из той же папки.
 */
async function sidecarIndex() {
  const rows = await prisma.fileEntry.findMany({
    where: { deletedAt: null, name: { endsWith: '.json' } },
    select: { id: true, name: true, folderId: true },
  });
  const byName = new Map();
  const byKey = new Map();
  for (const row of rows) {
    const base = row.name.replace(/\.supplemental-metadata(\(\d+\))?\.json$/i, '').replace(/\.json$/i, '');
    const list = byName.get(base) ?? [];
    list.push(row);
    byName.set(base, list);
    const key = mediaKey(row.name);
    byKey.set(key, byKey.has(key) ? null : row);
  }
  return { byName, byKey };
}

/** Сайдкар для записи: сначала из той же папки, иначе единственный кандидат по имени. */
function pickSidecar(index, name, folderId) {
  const list = index.byName.get(name);
  if (list?.length) {
    const exact = list.find((s) => s.folderId === folderId) ?? (list.length === 1 ? list[0] : null);
    if (exact) return exact;
  }
  // маркеры дублей (`IMG_1234 (2).HEIC`, `…~4.mp4`, `.supplemental-metadata(29).json`)
  return index.byKey.get(mediaKey(name)) ?? null;
}

/** Прочитанные сайдкары: одно фото встречается в нескольких папках — читаем объект один раз. */
const sidecarCache = new Map();

async function readSidecar(entryId) {
  if (sidecarCache.has(entryId)) return sidecarCache.get(entryId);
  const value = await loadSidecar(entryId);
  sidecarCache.set(entryId, value);
  return value;
}

async function loadSidecar(entryId) {
  const entry = await prisma.fileEntry.findUnique({ where: { id: entryId }, include: { asset: true } });
  if (!entry?.asset || Number(entry.asset.size) > 1_000_000) return null;
  const bytes = await s3.getObjectBytes(`files/${entry.asset.sha256}`, 1_000_000).catch(() => null);
  if (!bytes) return null;
  try {
    const parsed = JSON.parse(bytes.toString('utf8'));
    const seconds = Number(parsed?.photoTakenTime?.timestamp);
    const date = Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null;
    const lat = Number(parsed?.geoData?.latitude);
    const lon = Number(parsed?.geoData?.longitude);
    const geo =
      Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && (lat !== 0 || lon !== 0)
        ? { latitude: lat, longitude: lon }
        : null;
    return { date, geo };
  } catch {
    return null;
  }
}

async function main() {
  const index = await sidecarIndex();
  const sidecarCount = [...index.byName.values()].reduce((n, list) => n + list.length, 0);
  console.log(`сайдкаров в дереве: ${sidecarCount} (уникальных имён: ${index.byName.size})`);

  const rows = await prisma.fileEntry.findMany({
    where: { deletedAt: null, asset: { mime: { in: [...IMAGE, ...VIDEO] } } },
    select: { id: true, name: true, folderId: true, clientMtime: true, assetId: true, asset: { select: { mime: true, sha256: true, size: true } } },
  });
  const withoutDate = rows.filter((r) => !r.clientMtime);
  const matched = withoutDate.filter((r) => pickSidecar(index, r.name, r.folderId));
  const sameFolder = matched.filter((r) => pickSidecar(index, r.name, r.folderId).folderId === r.folderId);
  console.log(`медиа всего: ${rows.length}`);
  console.log(`без даты файла: ${withoutDate.length}`);
  console.log(`из них с сайдкаром: ${matched.length} (в той же папке: ${sameFolder.length}, найдены по имени: ${matched.length - sameFolder.length})`);

  if (!WRITE) {
    console.log('\nпример (ничего не меняем):');
    for (const row of matched.slice(0, 8)) {
      const side = await readSidecar(pickSidecar(index, row.name, row.folderId).id);
      console.log(`  ${row.name} → ${side?.date?.toISOString().slice(0, 10) ?? 'даты нет'}${side?.geo ? `, ${side.geo.latitude.toFixed(4)},${side.geo.longitude.toFixed(4)}` : ''}`);
    }
    console.log('\nэто прогон без записи. Для записи: node scripts/backfill-dates.mjs --write');
    return;
  }

  let written = 0;
  let failed = 0;
  const queue = WITH_EXIF ? withoutDate : matched;
  for (const [i, row] of queue.entries()) {
    try {
      const sidecar = pickSidecar(index, row.name, row.folderId);
      const fromSide = sidecar ? await readSidecar(sidecar.id) : null;
      if (fromSide?.date) {
        await prisma.fileEntry.update({ where: { id: row.id }, data: { clientMtime: fromSide.date } });
      }
      if (fromSide?.date || fromSide?.geo) {
        await media.fillDateAndGeo(row.assetId, fromSide.date, fromSide.geo);
      }
      if (WITH_EXIF && !fromSide?.date) {
        // ни сайдкара, ни даты в нём: пробуем вытащить из самого файла (EXIF фото / ffprobe видео)
        await media.captureAny(row.assetId, row.asset.sha256, Number(row.asset.size), row.asset.mime);
      }
      written += 1;
    } catch (e) {
      failed += 1;
      if (failed < 5) console.error(`  ${row.name}: ${e.message}`);
    }
    if ((i + 1) % 500 === 0) console.log(`  обработано ${i + 1} из ${queue.length} (ошибок ${failed})`);
  }
  console.log(`\nготово: обработано ${written}, ошибок ${failed}`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
