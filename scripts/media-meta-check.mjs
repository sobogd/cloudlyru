// Проверка метаданных: фото и видео получают EXIF/ffprobe независимо от зоны.
//
// Раньше разбор был только у медиа-зоны «Фото», и файлы в «Файлах» оставались без даты,
// координат и параметров кадра — на проде это была треть библиотеки. Здесь проверяется
// сам разбор (без S3: объект подставляется локальным файлом) и что он не зависит от зоны.
//
// Запуск (нужны ffmpeg и собранный dist):
//   DATABASE_URL=postgresql://user@127.0.0.1:5432/cloudly_dev SESSION_SECRET=dev-secret-0123456789 \
//     node scripts/media-meta-check.mjs
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'module';
import { PrismaClient } from '@prisma/client';

const require = createRequire(import.meta.url);
const dist = (p) => require(new URL(`../dist/${p}`, import.meta.url).pathname);

const { MediaService } = dist('media/media.service.js');
const { RemoteZip } = dist('unzip/s3-zip.js');
const prisma = new PrismaClient();

let failures = 0;
function check(name, ok, extra = '') {
  const mark = ok ? '  ok  ' : ' FAIL ';
  if (!ok) failures += 1;
  console.log(`[${mark}] ${name}${extra ? ` — ${extra}` : ''}`);
}

/**
 * Минимальный JPEG с EXIF: SOI + APP1(Exif) + EOI. Внутри — TIFF с IFD0 (Make, Model,
 * указатель на ExifIFD) и ExifIFD.DateTimeOriginal, то есть ровно то, что пишет камера.
 */
function jpegWithExif({ make, model, dateTimeOriginal }) {
  const ascii = (str) => Buffer.concat([Buffer.from(str, 'latin1'), Buffer.from([0])]);
  const makeBuf = ascii(make);
  const modelBuf = ascii(model);
  const dtoBuf = ascii(dateTimeOriginal);
  const ifd0Offset = 8;
  const ifd0Size = 2 + 3 * 12 + 4;
  const makeOffset = ifd0Offset + ifd0Size;
  const modelOffset = makeOffset + makeBuf.length;
  const exifIfdOffset = modelOffset + modelBuf.length;
  const dtoOffset = exifIfdOffset + (2 + 12 + 4);
  const tiff = Buffer.alloc(dtoOffset + dtoBuf.length);

  tiff.write('MM', 0, 'latin1');
  tiff.writeUInt16BE(42, 2);
  tiff.writeUInt32BE(ifd0Offset, 4);
  tiff.writeUInt16BE(3, ifd0Offset);
  const entry = (off, tag, type, count, value) => {
    tiff.writeUInt16BE(tag, off);
    tiff.writeUInt16BE(type, off + 2);
    tiff.writeUInt32BE(count, off + 4);
    tiff.writeUInt32BE(value, off + 8);
  };
  entry(ifd0Offset + 2, 0x010f, 2, makeBuf.length, makeOffset);
  entry(ifd0Offset + 14, 0x0110, 2, modelBuf.length, modelOffset);
  entry(ifd0Offset + 26, 0x8769, 4, 1, exifIfdOffset);
  tiff.writeUInt32BE(0, ifd0Offset + 38);
  makeBuf.copy(tiff, makeOffset);
  modelBuf.copy(tiff, modelOffset);
  tiff.writeUInt16BE(1, exifIfdOffset);
  entry(exifIfdOffset + 2, 0x9003, 2, dtoBuf.length, dtoOffset);
  tiff.writeUInt32BE(0, exifIfdOffset + 14);
  dtoBuf.copy(tiff, dtoOffset);

  const len = Buffer.alloc(2);
  len.writeUInt16BE(tiff.length + 2 + 6, 0);
  return Buffer.concat([
    Buffer.from([0xff, 0xd8, 0xff, 0xe1]),
    len,
    Buffer.from('Exif\0\0', 'latin1'),
    tiff,
    Buffer.from([0xff, 0xd9]),
  ]);
}

const dir = mkdtempSync(join(tmpdir(), 'clq-meta-'));
const made = [];

/** Куда подставляем локальный файл вместо объекта в S3. */
const objects = new Map();

const s3 = {
  readRange: async (key, start, end) => {
    const buf = objects.get(key);
    if (!buf) throw new Error(`нет объекта ${key}`);
    return buf.subarray(start, end + 1);
  },
  // ffprobe умеет читать локальный путь — этого достаточно, чтобы проверить разбор видео
  presignedGet: async (key) => {
    if (!objects.has(key)) throw new Error(`нет объекта ${key}`);
    return objects.get(key + ':path');
  },
};

async function seed(name, mime, path, zone) {
  const buf = readFileSync(path);
  const sha256 = createHash('sha256').update(buf).digest('hex');
  const asset = await prisma.asset.create({
    data: { sha256, size: BigInt(buf.length), mime, ext: name.split('.').pop() },
  });
  objects.set(`files/${sha256}`, buf);
  objects.set(`files/${sha256}:path`, path);
  made.push({ assetId: asset.id, sha256, zone });
  return { assetId: asset.id, sha256, size: buf.length };
}

try {
  // Снимок с настоящим EXIF: sharp пишет дату в IFD0 (ModifyDate), а камеры — в
  // ExifIFD.DateTimeOriginal, с которого и берётся дата съёмки. Собираем минимальный JPEG.
  const photo = join(dir, 'photo.jpg');
  writeFileSync(photo, jpegWithExif({ make: 'TestCam', model: 'Model-X', dateTimeOriginal: '2021:07:04 18:30:15' }));

  const video = join(dir, 'video.mp4');
  execFileSync('ffmpeg', [
    '-v', 'quiet',
    '-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=10:duration=2',
    '-metadata', 'creation_time=2022-05-06T07:08:09.000000Z',
    '-y', video,
  ]);

  const media = new MediaService(prisma, s3, { rootFolderId: async () => null });

  // === фото в зоне «Файлы»: метаданные всё равно разбираются ============================
  const image = await seed('photo.jpg', 'image/jpeg', photo, 'FILES');
  await media.captureAny(image.assetId, image.sha256, image.size, 'image/jpeg');
  const imageMeta = await prisma.mediaMeta.findUnique({ where: { assetId: image.assetId } });
  const raw = imageMeta?.raw ?? {};
  check('фото: строка метаданных появилась', Boolean(imageMeta));
  check('фото: дата съёмки из EXIF', imageMeta?.capturedAt?.toISOString().startsWith('2021-07-04') === true, String(imageMeta?.capturedAt));
  check('фото: камера из EXIF', imageMeta?.make === 'TestCam', String(imageMeta?.make));
  check('фото: модель из EXIF', imageMeta?.model === 'Model-X', String(imageMeta?.model));
  check('фото: полный набор тегов сохранён', raw.kind === 'image' && raw.model === 'Model-X', String(raw.kind));
  check('фото: повторный разбор не ходит в S3', await media['metaAlreadyParsed'](image.assetId));
  const before = imageMeta?.createdAt?.getTime();
  await media.captureAny(image.assetId, image.sha256, image.size, 'image/jpeg');
  const again = await prisma.mediaMeta.findUnique({ where: { assetId: image.assetId } });
  check('фото: повторный вызов ничего не переписывает', again?.createdAt?.getTime() === before);

  // === видео в зоне «Файлы»: ffprobe сохраняет длительность, кодек и дату ===============
  const clip = await seed('video.mp4', 'video/mp4', video, 'FILES');
  await media.captureAny(clip.assetId, clip.sha256, clip.size, 'video/mp4');
  let videoMeta = await prisma.mediaMeta.findUnique({ where: { assetId: clip.assetId } });
  for (let i = 0; i < 40 && !videoMeta?.raw?.videoCodec; i++) {
    await new Promise((r) => setTimeout(r, 250));
    videoMeta = await prisma.mediaMeta.findUnique({ where: { assetId: clip.assetId } });
  }
  const vraw = videoMeta?.raw ?? {};
  check('видео: строка метаданных появилась сразу', Boolean(videoMeta));
  check('видео: ffprobe добрал длительность', Number(vraw.durationSec) > 1.5 && Number(vraw.durationSec) < 2.5, String(vraw.durationSec));
  check('видео: кодек и разрешение', vraw.videoCodec === 'h264' && vraw.width === 64 && vraw.height === 48, `${vraw.videoCodec} ${vraw.width}x${vraw.height}`);
  check('видео: дата из контейнера', String(vraw.createdAt ?? '').startsWith('2022-05-06'), String(vraw.createdAt));

  // === сайдкары и даты архивов =========================================================
  // Настоящие архивы Takeout: даты файлов внутри — время упаковки, поэтому дата съёмки
  // берётся из сайдкара. Здесь проверяем, что обе вещи читаются из архива.
  const archDir = join(dir, 'arch');
  require('node:fs').mkdirSync(join(archDir, 'Takeout/Google Photos/2022'), { recursive: true });
  const photoInZip = join(archDir, 'Takeout/Google Photos/2022/IMG_0001.jpg');
  writeFileSync(photoInZip, jpegWithExif({ make: 'ZipCam', model: 'Z1', dateTimeOriginal: '2018:03:01 09:00:00' }));
  writeFileSync(
    join(archDir, 'Takeout/Google Photos/2022/IMG_0001.jpg.supplemental-metadata.json'),
    JSON.stringify({
      title: 'IMG_0001.jpg',
      photoTakenTime: { timestamp: '1519999200' },
      geoData: { latitude: 55.75, longitude: 37.61, altitude: 150 },
    }),
  );
  execFileSync('zip', ['-q', '-r', join(dir, 'takeout.zip'), 'Takeout'], { cwd: archDir });

  const archive = readFileSync(join(dir, 'takeout.zip'));
  const zipOverFile = new RemoteZip({
    size: () => archive.length,
    readRange: async (start, end) => archive.subarray(start, end + 1),
  });
  const zipEntries = await zipOverFile.entries();
  const photoEntry = zipEntries.find((e) => e.name.endsWith('IMG_0001.jpg'));
  const sidecarEntry = zipEntries.find((e) => e.name.endsWith('.json'));
  check('архив: даты файлов читаются', zipEntries.every((e) => e.lastModified instanceof Date), `${zipEntries.length} записей`);
  const sidecarJson = JSON.parse((await zipOverFile.readEntryBuffer(sidecarEntry)).toString('utf8'));
  check('архив: сайдкар читается и в нём дата съёмки', sidecarJson.photoTakenTime?.timestamp === '1519999200');
  check('архив: имя сайдкара — имя файла плюс суффикс', sidecarEntry.name === `${photoEntry.name}.supplemental-metadata.json`);

  // файл без EXIF (скриншот) + дата и координаты из сайдкара
  const shot = join(dir, 'screenshot.png');
  writeFileSync(shot, Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000a49444154789c6300010000050001', 'hex'));
  const shotAsset = await seed('screenshot.png', 'image/png', shot, 'FILES');
  await media.captureAny(shotAsset.assetId, shotAsset.sha256, shotAsset.size, 'image/png');
  const beforeFill = await prisma.mediaMeta.findUnique({ where: { assetId: shotAsset.assetId } });
  check('скриншот: EXIF нет — даты нет', !beforeFill?.capturedAt);
  const takenDate = new Date(Number(sidecarJson.photoTakenTime.timestamp) * 1000);
  await media.fillDateAndGeo(shotAsset.assetId, takenDate, {
    latitude: sidecarJson.geoData.latitude,
    longitude: sidecarJson.geoData.longitude,
  });
  const filled = await prisma.mediaMeta.findUnique({ where: { assetId: shotAsset.assetId } });
  check('скриншот: дата съёмки взята из сайдкара', filled?.capturedAt?.toISOString() === takenDate.toISOString(), String(filled?.capturedAt));
  check('скриншот: координаты из сайдкара', filled?.latitude === 55.75 && filled?.longitude === 37.61, `${filled?.latitude},${filled?.longitude}`);
  // EXIF точнее сайдкара: уже найденную дату не перетираем
  await media.fillDateAndGeo(image.assetId, new Date('1990-01-01T00:00:00Z'), { latitude: 1, longitude: 2 });
  const kept = await prisma.mediaMeta.findUnique({ where: { assetId: image.assetId } });
  check('EXIF не перетирается датой из архива', kept?.capturedAt?.toISOString().startsWith('2021-07-04') === true, String(kept?.capturedAt));

  // === не медиа: разбор не запускается ==================================================
  const other = join(dir, 'doc.txt');
  require('node:fs').writeFileSync(other, 'привет');
  const doc = await seed('doc.txt', 'text/plain', other, 'FILES');
  await media.captureAny(doc.assetId, doc.sha256, doc.size, 'text/plain');
  check('документ: метаданных нет и не появляется', (await prisma.mediaMeta.findUnique({ where: { assetId: doc.assetId } })) === null);
} finally {
  for (const m of made) {
    await prisma.mediaMeta.deleteMany({ where: { assetId: m.assetId } }).catch(() => {});
    await prisma.fileEntry.deleteMany({ where: { assetId: m.assetId } }).catch(() => {});
    await prisma.asset.deleteMany({ where: { id: m.assetId } }).catch(() => {});
  }
  await prisma.$disconnect();
  rmSync(dir, { recursive: true, force: true });
}

console.log(failures ? `\n${failures} проверок упало` : '\nвсе проверки прошли');
process.exit(failures ? 1 : 0);
