// Пересборка полных превью фото под актуальные настройки энкодера.
//
// Зачем: ключ `view/<sha>-2048.avif` — это то, что открывается в полноэкранном просмотре.
// После смены параметров энкодера (2048 px, AVIF q60 вместо q85) старые превью остаются
// тяжёлыми (~940 КБ на кадр 4000×3000), пока их не пересоберут из оригиналов.
//
// Оригиналы на месте (KEEP_ORIGINALS=true), поэтому пересборка идёт из исходника, а не
// из старого превью — второго поколения потерь нет. Ассеты, у которых оригинал удалён
// старым пайплайном, пропускаются: их полное превью лежит под легаси-ключом `-2048.webp`.
//
// Запуск на сервере (там же, где БД и S3; параметры — из .env приложения):
//   node --env-file=.env scripts/rebuild-previews.mjs                     # dry-run: что и насколько
//   node --env-file=.env scripts/rebuild-previews.mjs --sha 761905a2      # один ассет (проверка)
//   node --env-file=.env scripts/rebuild-previews.mjs --apply --limit 20  # первые 20 по-настоящему
//   node --env-file=.env scripts/rebuild-previews.mjs --apply             # вся медиатека
//
// Флаги: --apply (без него ничего не пишем), --limit N, --sha <префикс sha256>,
//        --min-kb N (порог: превью легче — не трогаем, по умолчанию 450),
//        --width N (2048), --quality N (60 — те же значения, что в src/queue/queue.service.ts).
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { PrismaClient } from '@prisma/client';
import { S3Client, GetObjectCommand, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import sharp from 'sharp';

const run = promisify(execFile);
const env = process.env;

// ===== ключи производных: те же, что в MediaService (viewKey(sha, suffix)) =====
const photoFullKey = (sha) => `view/${sha}-2048.avif`;
const legacyPhotoFullWebpKey = (sha) => `view/${sha}-2048.webp`;

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}
const apply = !!arg('apply', false);
const limit = Number(arg('limit', 0)) || 0;
const shaPrefix = typeof arg('sha', '') === 'string' ? arg('sha', '') : '';
const minKb = Number(arg('min-kb', 450));
const width = Number(arg('width', 2048));
const quality = Number(arg('quality', 60));

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

const head = async (key) => {
  try {
    const r = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return Number(r.ContentLength);
  } catch {
    return 0;
  }
};

const kb = (bytes) => `${Math.round(bytes / 1024)}К`;

/** Полное превью как в queue.service.convertPhoto: 2048 px, AVIF q60 (анимация — WebP). */
async function encodeFull(srcPath, animated) {
  const pipe = sharp(srcPath, { animated }).rotate().resize({ width, withoutEnlargement: true }).keepIccProfile();
  if (animated) return { body: await pipe.webp({ quality: 80 }).toBuffer(), mime: 'image/webp' };
  return { body: await pipe.avif({ quality }).toBuffer(), mime: 'image/avif' };
}

const stats = { total: 0, rebuilt: 0, skippedSmall: 0, skippedNoRaw: 0, skippedBigger: 0, savedBytes: 0 };

async function processAsset(asset) {
  const sha = asset.sha256;
  const fullKey = photoFullKey(sha);
  const current = await head(fullKey);
  const legacy = current ? 0 : await head(legacyPhotoFullWebpKey(sha));

  if (current && current <= minKb * 1024) {
    stats.skippedSmall++;
    return;
  }
  const rawKey = `files/${sha}`;
  const rawSize = await head(rawKey);
  if (!rawSize) {
    stats.skippedNoRaw++;
    console.log(`— ${sha.slice(0, 10)} нет оригинала (легаси-ассет), пропуск${legacy ? ' (превью — старый WebP)' : ''}`);
    return;
  }

  const dir = mkdtempSync(join(tmpdir(), 'clq-rebuild-'));
  try {
    const rawPath = join(dir, 'raw');
    const raw = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: rawKey }));
    writeFileSync(rawPath, Buffer.concat(await raw.Body.toArray()));

    let decodedPath = rawPath;
    if (/^image\/(heic|heif)/i.test(asset.mime)) {
      // sharp prebuilt не декодирует HEIC — тот же обходной путь, что в очереди
      const png = join(dir, 'decoded.png');
      try {
        await run('heif-convert', [rawPath, png], { timeout: 300_000 });
        decodedPath = png;
      } catch (e) {
        console.log(`✗ ${sha.slice(0, 10)} heif-convert не смог: ${String(e.stderr || e.message).split('\n').pop()?.slice(0, 120)}`);
        return;
      }
    }

    const meta = await sharp(decodedPath, { animated: true }).metadata().catch(() => null);
    const animated = (meta?.pages ?? 1) > 1;
    const { body, mime } = await encodeFull(decodedPath, animated);
    const before = current || legacy; // 0 — превью ещё нет (или есть только легаси-WebP)

    if (before && body.length >= before) {
      stats.skippedBigger++;
      console.log(`· ${sha.slice(0, 10)} ${kb(before)} → ${kb(body.length)} — не меньше текущего, оставляю как есть`);
      return;
    }

    console.log(
      `${apply ? '✓' : '·'} ${sha.slice(0, 10)} ${asset.mime.replace('image/', '')} ` +
      `${before ? `${kb(before)} → ` : ''}${kb(body.length)}` +
      `${before ? ` (−${Math.round((1 - body.length / before) * 100)}%)` : ''}` +
      `${animated ? ' [анимация → WebP]' : ''}`,
    );
    if (apply) {
      // у анимированных источников ключ тот же, а содержимое — WebP (как делает очередь)
      await s3.send(new PutObjectCommand({ Bucket: bucket, Key: fullKey, Body: body, ContentType: mime }));
    }
    if (before) stats.savedBytes += before - body.length;
    stats.rebuilt++;
    if (!current && legacy) console.log('   (ляжет по ключу -2048.avif, легаси-WebP останется как есть)');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const where = {
  mime: { startsWith: 'image/' },
  masterReadyAt: { not: null },
  entries: { some: { zone: 'PHOTOS', deletedAt: null } },
  ...(shaPrefix ? { sha256: { startsWith: shaPrefix } } : {}),
};
const assets = await prisma.asset.findMany({
  where,
  select: { sha256: true, mime: true, size: true, masterReadyAt: true },
  orderBy: { masterReadyAt: 'asc' },
  take: limit || undefined,
});

stats.total = assets.length;
console.log(
  `${apply ? 'ПЕРЕСБОРКА' : 'DRY-RUN'}: фото-ассетов ${assets.length} ` +
  `(ширина ${width}, AVIF q${quality}, порог ${minKb} КБ${limit ? `, лимит ${limit}` : ''})`,
);

let i = 0;
for (const a of assets) {
  i++;
  process.stdout.write(`[${i}/${assets.length}] `);
  try {
    await processAsset(a);
  } catch (e) {
    console.log(`✗ ${a.sha256.slice(0, 10)} ошибка: ${e.message}`);
  }
}

const saved = stats.savedBytes >= 1024 * 1024
  ? `${(stats.savedBytes / 1024 / 1024).toFixed(1)} МБ`
  : `${Math.round(stats.savedBytes / 1024)} КБ`;
console.log(
  `\nИтого: пересобрано ${stats.rebuilt}, уже лёгких ${stats.skippedSmall}, ` +
  `без оригинала ${stats.skippedNoRaw}, не выиграли ${stats.skippedBigger}; ` +
  `экономия ~${saved}${apply ? '' : ' (в dry-run — оценочно)'}`,
);
await prisma.$disconnect();
