// Пересборка превью для списка (сетка галереи) под актуальный GRID_SIZE и формат AVIF.
//
// Зачем: сетка лежит по ключу `view/<sha>-512.avif` (текущий формат) и `view/<sha>-512.webp`
// (прежний пайплайн: 512 px, 50×50, 100×100 WebP). Сервер отдаёт AVIF первым, а WebP — только
// как запасной, поэтому после перевода формата старую библиотеку нужно пересобрать из
// оригинала: иначе часть кадров продолжит отдаваться в WebP (то есть форматы будут вперемешку),
// а старые 50×50 останутся мыльными.
//
// Откуда берётся кадр: если у ассета есть собранное полное превью (`view/<sha>-1080.avif`),
// миниатюра делается из него — это в 20–25 раз быстрее декодирования оригинала (замер на
// HEIC: 0.2 с против 5 с), а разница с «из оригинала» — 4 из 255 на канал, то есть уровень
// повторного сжатия, на квадрате 100×100 невидимый. Оригинал читается только там, где
// полного превью нет. Отключить: `--no-from-full`.
//
// Важно: 50×50 в 100×100 не апскейлится — из миниатюры кадр не берётся никогда, только из
// полного превью или оригинала.
//
// Ключи не меняются: пишем тот же `-512.avif`, а легаси `-512.webp` остаётся на месте, пока
// его не удалят отдельным проходом `--drop-legacy`. Так превью доступны всё время пересборки:
// сервер перебирает кандидатов и отдаёт то, что уже есть.
//
// Признак «уже актуально» — фактическая ширина существующего AVIF-объекта, а не отметка в БД:
// схемы трогать не нужно, а скрипт становится возобновляемым (прерванный прогон продолжается
// с того же места). Порог: ширина > STALE_MAX_WIDTH — превью не старого поколения. 50×50
// отсекается по нему, а мелкий оригинал (кадр меньше GRID_SIZE, апскейла нет) считается
// актуальным — лишний прогон ему не страшен, пересборка идемпотентна.
//
// Запуск на сервере (там же, где БД и S3; параметры — из .env приложения):
//   node --env-file=.env scripts/rebuild-grid.mjs                        # dry-run: что и сколько
//   node --env-file=.env scripts/rebuild-grid.mjs --limit 5 --apply      # пять ассетов (проверка)
//   node --env-file=.env scripts/rebuild-grid.mjs --apply --concurrency 3
//   node --env-file=.env scripts/rebuild-grid.mjs --apply --drop-legacy  # и снести старые WebP
//
// Флаги: --apply (без него ничего не пишем), --limit N, --sha <префикс sha256>,
//        --kind photo|video|all (по умолчанию photo), --concurrency N (3),
//        --drop-legacy (удалять `-512.webp` после успешной записи AVIF),
//        --no-from-full (собирать из оригинала, а не из полного превью).
import { mkdtempSync, rmSync, createWriteStream, existsSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { promisify } from 'node:util';
import { PrismaClient } from '@prisma/client';
import {
  S3Client,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
} from '@aws-sdk/client-s3';
import sharp from 'sharp';

const run = promisify(execFile);
const env = process.env;

// ===== размер и параметры энкодера: те же, что в src/media/media.service.ts =====
// Дублируются здесь намеренно: скрипт — разовый инструмент выкладки, и тянуть в него
// серверный модуль (Nest-модуль с DI) ради двух констант дороже, чем повторить числа.
// При смене GRID_SIZE/GRID_QUALITY в media.service.ts их надо поменять и здесь.
const GRID_SIZE = 256;
const GRID_QUALITY = 60;
/**
 * Актуальным считается объект шириной не меньше GRID_SIZE: прежние размеры сетки (50, 100, 512)
 * уже целевого, поэтому пересобираются, а повторный прогон пропускает готовое. Кадр мельче
 * GRID_SIZE (совсем маленький оригинал, апскейла нет) в цели не нуждается и тоже пропускается
 * по этому же признаку — пересборка такого кадра дала бы тот же результат.
 */
const FRESH_MIN_WIDTH = GRID_SIZE;
const FFMPEG = ['ffmpeg', '-hide_banner', '-loglevel', 'error'];
/** Опции sharp для чтения исходника: анимация сохраняется, обрезанный файл не валит задачу. */
const SHARP_IN = { animated: true, failOn: 'truncated' };
// sharp по умолчанию берёт на одну операцию все ядра — а на сервере рядом живёт API, который
// должен отвечать. Один поток на задачу: суммарная нагрузка равна числу воркеров.
sharp.concurrency(1);

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}
const apply = !!arg('apply', false);
const limit = Number(arg('limit', 0)) || 0;
const shaPrefix = typeof arg('sha', '') === 'string' ? arg('sha', '') : '';
const kind = String(arg('kind', 'photo'));
const concurrency = Math.max(1, Number(arg('concurrency', 3)) || 3);
const dropLegacy = !!arg('drop-legacy', false);
const fromFull = !arg('no-from-full', false);

const bucket = env.S3_FILES_BUCKET;
if (!bucket) {
  console.error('нет S3_FILES_BUCKET — запускать с --env-file=.env приложения');
  process.exit(1);
}

const s3 = new S3Client({
  region: env.S3_FILES_REGION,
  endpoint: env.S3_FILES_ENDPOINT,
  forcePathStyle: env.S3_FILES_FORCE_PATH_STYLE === 'true',
  credentials: { accessKeyId: env.S3_FILES_ACCESS_KEY, secretAccessKey: env.S3_FILES_SECRET_KEY },
});
const prisma = new PrismaClient();

/** Ключ превью списка — тот же, что в MediaService.gridKey (текущий формат, AVIF). */
const gridKey = (sha) => `view/${sha}-512.avif`;
/** Ключ прежнего пайплайна в WebP — только чтение и (по флагу) удаление. */
const legacyGridKey = (sha) => `view/${sha}-512.webp`;
/** Полное превью фото — MediaService.photoFullKey (1080, AVIF; у анимации — WebP). */
const photoFullKey = (sha) => `view/${sha}-1080.avif`;
/** Прежние ключи полного превью: 2048 (AVIF — прошлый пайплайн, WebP — ещё более старый). */
const legacyFullKeys = (sha) => [`view/${sha}-2048.avif`, `view/${sha}-2048.webp`];
/** Ключ постера видео — MediaService.videoPosterKey. */
const posterKey = (sha) => `view/${sha}-poster.webp`;
/** Оригинал: content-addressed объект. */
const rawKey = (sha) => `files/${sha}`;

/** Размер объекта или 0, если его нет. */
const head = async (key) => {
  try {
    const r = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return Number(r.ContentLength);
  } catch {
    return 0;
  }
};

/** Тело объекта или null, если его нет. Только для мелких объектов — превью, не оригинала. */
const getObject = async (key) => {
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    return Buffer.concat(await r.Body.toArray());
  } catch {
    return null;
  }
};

/**
 * Скачать объект на диск потоком. Оригинал нельзя читать в память: у видео он доходит до
 * пары гигабайт, и один такой файл выбил бы процесс по памяти. Возвращает false, если объекта нет.
 */
async function download(key, destPath) {
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    await pipeline(r.Body, createWriteStream(destPath));
    return true;
  } catch {
    return false;
  }
}

/**
 * Ширина уже собранного превью или null, если объекта нет.
 * Мелкий объект (1–40 КБ) — это и есть смысл проверки: она дешевле чтения оригинала.
 */
async function currentWidth(key) {
  const buf = await getObject(key);
  if (!buf?.length) return null;
  try {
    const meta = await sharp(buf).metadata();
    return meta.width ?? null;
  } catch {
    return null;
  }
}

/**
 * Кадр сетки из картинки: квадрат GRID_SIZE×GRID_SIZE, кроп по центру, без апскейла.
 * Ориентация запекается в пиксели (`rotate`), ICC сохраняется — тот же конвейер, что в
 * очереди, иначе рядом с новыми превью старые выглядели бы иначе по цвету.
 * Формат — AVIF: единый со полным превью и легче WebP при том же качестве.
 */
async function encodeGrid(srcPath, animated) {
  return sharp(srcPath, { ...SHARP_IN, animated })
    .rotate()
    .keepIccProfile()
    .resize({ width: GRID_SIZE, height: GRID_SIZE, fit: 'cover', withoutEnlargement: true })
    .avif({ quality: GRID_QUALITY })
    .toBuffer();
}

/**
 * Кадр сетки из готового полного превью: без декодирования оригинала и без heif-convert.
 *
 * `sharp` читает AVIF (и подменённый WebP у анимации) сам, поэтому для HEIC-кассет этот путь
 * не запускает дорогой libheif: 0.2 с против 5 с на кадр. Возвращает null, если полного
 * превью нет вовсе — тогда вызывающий идёт обычным путём, через оригинал.
 */
async function encodeGridFromFull(sha) {
  for (const key of [photoFullKey(sha), ...legacyFullKeys(sha)]) {
    const buf = await getObject(key);
    if (!buf?.length) continue;
    try {
      const meta = await sharp(buf).metadata();
      // Кадр меньше целевого квадрата даст превью хуже, чем оригинал: у такого ассета полного
      // превью нет по сути, и правильнее собрать из оригинала.
      if ((meta.width ?? 0) < GRID_SIZE) return null;
      return await sharp(buf, { ...SHARP_IN, animated: (meta.pages ?? 1) > 1 })
        .keepIccProfile()
        .resize({ width: GRID_SIZE, height: GRID_SIZE, fit: 'cover', withoutEnlargement: true })
        .avif({ quality: GRID_QUALITY })
        .toBuffer();
    } catch {
      return null;
    }
  }
  return null;
}

/** Кадр постера из видео: тот же фильтр ffmpeg, что в convertVideo (кроп в квадрат). */
async function encodePoster(rawPath) {
  const dir = mkdtempSync(join(tmpdir(), 'clq-poster-'));
  const png = join(dir, 'poster.png');
  try {
    const vf = `scale=${GRID_SIZE}:${GRID_SIZE}:force_original_aspect_ratio=increase,crop=${GRID_SIZE}:${GRID_SIZE}`;
    // `-ss 1`: первый кадр у многих роликов чёрный. Если ролик короче полутора секунд,
    // кадра на этой секунде нет вовсе — ffmpeg выходит с кодом 0, но файла не создаёт,
    // поэтому нужен второй запуск без перемотки (та же ловушка, что в очереди).
    await run('ffmpeg', [...FFMPEG.slice(1), '-y', '-ss', '1', '-i', rawPath, '-frames:v', '1', '-vf', vf, png], { timeout: 180_000 });
    if (!existsSync(png)) {
      await run('ffmpeg', [...FFMPEG.slice(1), '-y', '-i', rawPath, '-frames:v', '1', '-vf', vf, png], { timeout: 180_000 });
    }
    // Постер остаётся WebP: его собирает ffmpeg, а перевод видео-конвейера на AVIF — отдельная
    // правка (в convertVideo формат постера зашит так же).
    return await sharp(png, SHARP_IN).webp({ quality: 78 }).toBuffer();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const stats = { total: 0, rebuilt: 0, skippedFresh: 0, skippedNoRaw: 0, failed: 0, bytesBefore: 0, bytesAfter: 0 };

/** Один ассет: проверить текущее превью, при необходимости пересобрать из оригинала. */
async function processAsset(asset) {
  const sha = asset.sha256;
  const isVideo = asset.mime.startsWith('video/');
  const target = isVideo ? posterKey(sha) : gridKey(sha);

  const width = await currentWidth(target);
  const before = width === null ? 0 : await head(target);
  if (width !== null && width >= FRESH_MIN_WIDTH) {
    stats.skippedFresh++;
    return `· ${sha.slice(0, 10)} уже ${width}px — пропуск`;
  }

  // Путь «из полного превью»: оригинал не читается вовсе — на библиотеке в 50 тысяч кадров
  // это и есть разница между часом и сутками работы.
  if (fromFull && !isVideo) {
    const fromFullBody = await encodeGridFromFull(sha);
    if (fromFullBody) {
      stats.rebuilt++;
      stats.bytesBefore += before;
      stats.bytesAfter += fromFullBody.length;
      if (apply) {
        await s3.send(new PutObjectCommand({ Bucket: bucket, Key: target, Body: fromFullBody, ContentType: 'image/avif' }));
        if (dropLegacy) {
          await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: legacyGridKey(sha) })).catch(() => undefined);
        }
      }
      const was = width === null ? 'нет' : `${width}px ${Math.round(before / 1024)}К`;
      return `✓ ${sha.slice(0, 10)} ${asset.mime.replace(/^(image|video)\//, '')} ${was} → ${GRID_SIZE}px ${(fromFullBody.length / 1024).toFixed(1)}К (из 1080)`;
    }
  }

  const raw = await head(rawKey(sha));
  const dir = mkdtempSync(join(tmpdir(), 'clq-grid-'));
  try {
    const rawPath = join(dir, 'raw');
    if (!raw || !(await download(rawKey(sha), rawPath))) {
      stats.skippedNoRaw++;
      return `— ${sha.slice(0, 10)} нет оригинала (легаси-ассет), пропуск`;
    }

    let body;
    if (isVideo) {
      body = await encodePoster(rawPath);
    } else {
      let decodedPath = rawPath;
      if (/^image\/(heic|heif)/i.test(asset.mime)) {
        // sharp prebuilt не декодирует HEIC — тот же обходной путь, что в очереди
        const png = join(dir, 'decoded.png');
        try {
          await run('heif-convert', [rawPath, png], { timeout: 300_000 });
          decodedPath = png;
        } catch (e) {
          stats.failed++;
          return `✗ ${sha.slice(0, 10)} heif-convert не смог: ${String(e.stderr || e.message).split('\n').pop()?.slice(0, 120)}`;
        }
      }
      const meta = await sharp(decodedPath, SHARP_IN).metadata().catch(() => null);
      body = await encodeGrid(decodedPath, (meta?.pages ?? 1) > 1);
    }

    stats.rebuilt++;
    stats.bytesBefore += before;
    stats.bytesAfter += body.length;
    if (apply) {
      await s3.send(new PutObjectCommand({
        Bucket: bucket,
        Key: target,
        Body: body,
        ContentType: isVideo ? 'image/webp' : 'image/avif',
      }));
      // Старый WebP-объект снимаем только по явному флагу: пока он есть, кадр отдаётся
      // даже тем сборкам клиента, которые AVIF не декодируют. Удаление — отдельный,
      // осознанный шаг после проверки на телефоне.
      if (dropLegacy && !isVideo) {
        await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: legacyGridKey(sha) })).catch(() => undefined);
      }
    }
    const was = width === null ? 'нет' : `${width}px ${Math.round(before / 1024)}К`;
    return `✓ ${sha.slice(0, 10)} ${asset.mime.replace(/^(image|video)\//, '')} ${was} → ${GRID_SIZE}px ${(body.length / 1024).toFixed(1)}К`;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Что пересобираем: только медиа-зона «Фото» (в «Файлах» превью не собираются) и только
// ассеты, у которых превью уже есть: у остальных работа впереди у очереди, и она соберёт
// их сразу в актуальном размере.
const mimeFilter = kind === 'video'
  ? { startsWith: 'video/' }
  : kind === 'photo'
    ? { in: ['image/jpeg', 'image/heic', 'image/heif', 'image/png', 'image/webp', 'image/tiff', 'image/gif', 'image/avif'] }
    : {};
const assets = await prisma.asset.findMany({
  where: {
    previewState: 'done',
    entries: { some: { zone: 'PHOTOS', deletedAt: null } },
    ...(kind === 'all' ? {} : { mime: mimeFilter }),
    ...(shaPrefix ? { sha256: { startsWith: shaPrefix } } : {}),
  },
  select: { sha256: true, mime: true },
  orderBy: { createdAt: 'asc' },
  take: limit || undefined,
});
stats.total = assets.length;
console.log(
  `${apply ? 'ПЕРЕСБОРКА' : 'DRY-RUN'}: ассетов ${assets.length} (${kind}), цель ${GRID_SIZE}px AVIF q${GRID_QUALITY}, ` +
  `параллельно ${concurrency}${limit ? `, лимит ${limit}` : ''}${dropLegacy ? ', старый WebP удаляем' : ''}`,
);

// Пул воркеров: каждая задача — скачать оригинал, декодировать и закодировать заново.
// Последовательный проход по 50 тысячам кадров занял бы часы, поэтому простой пул на N
// воркеров; каждый воркер — один поток sharp, то есть 3 воркера оставляют одно ядро из
// четырёх API-процессу, который работает на том же сервере.
let cursor = 0;
let done = 0;
async function worker() {
  for (;;) {
    const i = cursor++;
    if (i >= assets.length) return;
    const asset = assets[i];
    try {
      const line = await processAsset(asset);
      done++;
      console.log(`[${done}/${assets.length}] ${line}`);
    } catch (e) {
      stats.failed++;
      done++;
      console.log(`[${done}/${assets.length}] ✗ ${asset.sha256.slice(0, 10)} ошибка: ${e.message}`);
    }
  }
}
await Promise.all(Array.from({ length: concurrency }, worker));

const mb = (b) => `${(b / 1024 / 1024).toFixed(1)} МБ`;
console.log(
  `\nИтого: пересобрано ${stats.rebuilt}, уже актуальных ${stats.skippedFresh}, ` +
  `без оригинала ${stats.skippedNoRaw}, ошибок ${stats.failed}; ` +
  `было ${mb(stats.bytesBefore)} → стало ${mb(stats.bytesAfter)}` +
  `${apply ? '' : ' (в dry-run — оценочно, объекты не записаны)'}`,
);
await prisma.$disconnect();
