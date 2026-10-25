// Разовая чистка данных раздела «Фото» (PHOTOS) после удаления медиараздела из приложения.
//
// Что делает:
//   - удаляет записи зоны PHOTOS: FileEntry (zone='PHOTOS') и все папки зоны PHOTOS
//     (поддерево целиком; записи в них удаляются и каскадом — на FileEntry.folder это CASCADE);
//   - удаляет альбомы (Album, AlbumItem) — были только ручками API, с разделом ушли;
//   - для «фото-ассетов» (Asset, у которого не осталось ни одной записи после чистки):
//     MediaMeta (EXIF), задачи очереди превью (Job), и сброс полей превью
//     (previewState='none', previewError=null, pageCount=null);
//   - очищает статистику конвертации (ConvertStat) и снимает паузу очереди (QueueState);
//   - ассеты, у которых есть записи в других зонах (файл дедуплицирован с фото), не трогает.
//
// Чего НЕ делает:
//   - S3 не трогает: оригиналы files/<sha> и производные view/<sha><суффикс> остаются лежать
//     (БД уезжала на другой инстанс, повторная загрузка не требуется). Строки Asset именно
//     потому и сохраняются: deploy/scripts/sweep-orphans.mjs --apply убрал бы их объекты
//     в бакете, поэтому за чисткой sweep НЕ прогонять.
//   - ChangeLog не трогает (append-only журнал: tombstone не связан ключами с записями).
//
// Запуск из каталога приложения (там же node_modules с @prisma/client),
// переменные — из .env приложения:
//   node deploy/scripts/purge-media.mjs           # только показать, что будет (dry-run)
//   node deploy/scripts/purge-media.mjs --apply   # удалить
import { PrismaClient } from '@prisma/client';

const args = process.argv.slice(2);
const apply = args.includes('--apply');

if (!process.env.DATABASE_URL) {
  console.error('[purge-media] нет DATABASE_URL');
  process.exit(2);
}

const prisma = new PrismaClient();

// in-запросы режем на порции: Postgres ограничивает число параметров в одном запросе,
// а фото-ассетов может быть десятки тысяч.
const CHUNK = 5000;
function* chunks(list) {
  for (let i = 0; i < list.length; i += CHUNK) yield list.slice(i, i + CHUNK);
}

async function main() {
  // 1. Записи зоны PHOTOS — всё, что уезжает, включая корзину.
  const photoEntries = await prisma.fileEntry.findMany({
    where: { zone: 'PHOTOS' },
    select: { id: true, assetId: true, folderId: true },
  });

  // 2. Папки зоны PHOTOS — поддерево целиком. Порядок удаления не важен: FK на родителя
  //    ON DELETE SET NULL, а все строки уезжают в одной транзакции.
  const photoFolders = await prisma.folder.findMany({
    where: { zone: 'PHOTOS' },
    select: { id: true },
  });

  // 3. «Фото-ассеты»: у Asset не осталось ни одной записи кроме PHOTOS. Ассет, на который
  //    ссылаются записи других зон (дедуп: тот же файл лежит и в «Файлах»), не чистим —
  //    его EXIF и превью ещё показывают деталка файла и списки.
  const assetsByEntry = new Map();
  for (const e of photoEntries) {
    if (!assetsByEntry.has(e.assetId)) assetsByEntry.set(e.assetId, { total: 0, photo: 0 });
    const rec = assetsByEntry.get(e.assetId);
    rec.photo += 1;
  }
  const assetIds = [...assetsByEntry.keys()];
  const photoOnlyAssetIds = [];
  for (const c of chunks(assetIds)) {
    const rows = await prisma.fileEntry.groupBy({
      by: ['assetId'],
      where: { assetId: { in: c } },
      _count: { _all: true },
    });
    for (const r of rows) {
      const rec = assetsByEntry.get(r.assetId);
      rec.total = r._count._all;
      if (rec.total === rec.photo) photoOnlyAssetIds.push(r.assetId);
    }
  }

  const albums = await prisma.album.count();
  const albumItems = await prisma.albumItem.count();
  const convertStats = await prisma.convertStat.count();
  const queuePaused = await prisma.queueState.findUnique({ where: { id: 1 } });

  console.log('[purge-media]');
  console.log(`  записи PHOTOS:        ${photoEntries.length}`);
  console.log(`  папки PHOTOS:         ${photoFolders.length}`);
  console.log(`  ассетов затронуто:    ${assetIds.length}`);
  console.log(`  фото-ассетов (чистых): ${photoOnlyAssetIds.length}`);
  console.log(`  альбомов / элементов: ${albums} / ${albumItems}`);
  console.log(`  ConvertStat строк:    ${convertStats}`);
  console.log(`  очередь превью:       ${queuePaused?.paused ? 'на паузе' : 'работает'}`);

  if (!apply) {
    console.log('\n[purge-media] dry-run: ничего не удалено. --apply — удалить.');
    return;
  }

  await prisma.$transaction(async (tx) => {
    // Связки «ассет ↔ запись» уходят первыми: на Asset это RESTRICT, и пока есть хоть одна
    // живая запись, ассет удалять нельзя — мы её не удаляем, но порядок тот же, что в purge.
    await tx.fileEntry.deleteMany({ where: { zone: 'PHOTOS' } });
    await tx.folder.deleteMany({ where: { zone: 'PHOTOS' } });

    // Альбомы: сначала элементы (FK на запись CASCADE, но удаляем явно — запись уже ушла).
    await tx.albumItem.deleteMany();
    await tx.album.deleteMany();

    // Фото-ассеты: EXIF, задачи превью и поля превью. Сами строки Asset остаются —
    // они удерживают объекты S3 от sweep-orphans.
    if (photoOnlyAssetIds.length) {
      for (const c of chunks(photoOnlyAssetIds)) {
        await tx.mediaMeta.deleteMany({ where: { assetId: { in: c } } });
        await tx.job.deleteMany({ where: { assetId: { in: c } } });
        await tx.asset.updateMany({
          where: { id: { in: c } },
          data: { previewState: 'none', previewError: null, pageCount: null },
        });
      }
    }

    // Статистика конвертации — только метрика очереди (30 дней живёт), её сброс без потерь.
    await tx.convertStat.deleteMany();
    await tx.queueState.update({ where: { id: 1 }, data: { paused: false } });
  });

  console.log('\n[purge-media] готово:');
  console.log(`  удалено записей PHOTOS:  ${photoEntries.length}`);
  console.log(`  удалено папок PHOTOS:    ${photoFolders.length}`);
  console.log(`  очищено фото-ассетов:    ${photoOnlyAssetIds.length}`);
  console.log(`  удалено альбомов:        ${albums}`);
  console.log('  S3 не тронут. sweep-orphans --apply за этим не прогонять.');
}

main()
  .catch((e) => {
    console.error('[purge-media] сбой:', e);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
