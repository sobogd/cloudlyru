#!/usr/bin/env node
// Проверка хеш-цепочки VeriFactu по данным из базы: не «строки совпали», а «цепочка цела».
//
// Зачем отдельный скрипт, если есть scripts/factura-invariants.sql: тот сравнивает слепки
// источника и цели (и этого достаточно для переноса), а этот отвечает на другой вопрос —
// внутренне ли согласована цепочка в самой базе. Для каждой записи проверяется, что
//   • currentHash = sha256(hashInput) в верхнем регистре — то есть запись не подменили;
//   • previousHash равен currentHash предыдущей записи — цепочка не разорвана;
//   • внутри hashInput есть ссылка `&Huella=<previousHash>` — цепочка замкнута и в самом
//     входе хеша, а не только в колонке.
// Так проверяется не только перенос, но и то, что продолжение серии (следующая запись
// сошлётся на последний хеш) не сломает цепочку в AEAT.
//
// Запуск (DATABASE_URL читается из .env приложения или из окружения):
//   node --env-file=.env scripts/factura-chain-check.mjs
//   # или по конкретной базе-копии:
//   DATABASE_URL=postgresql://user@localhost:5432/cloudly_cutover_dry node scripts/factura-chain-check.mjs

import { createHash } from 'node:crypto';
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

/**
 * Проверяет цепочку одной компании.
 *
 * @param {string} companyId идентификатор компании.
 * @returns {Promise<{rows:number, broken:string[], lastHash:string|null, lastSeq:number|null}>}
 *   число записей, список найденных разрывов, последний хеш и его номер.
 *   Побочных эффектов нет: только чтение.
 */
async function checkCompany(companyId) {
  const rows = await prisma.verifactuRegistry.findMany({
    where: { companyId },
    orderBy: { sequenceNumber: 'asc' },
    select: { sequenceNumber: true, previousHash: true, currentHash: true, hashInput: true },
  });

  const broken = [];
  let prev = '';
  for (const r of rows) {
    const computed = createHash('sha256').update(r.hashInput).digest('hex').toUpperCase();
    if (computed !== r.currentHash) {
      broken.push(`#${r.sequenceNumber}: currentHash не совпал с sha256(hashInput)`);
    }
    if (r.previousHash !== prev) {
      broken.push(`#${r.sequenceNumber}: previousHash != хеш предыдущей записи`);
    }
    if (!r.hashInput.includes(`&Huella=${r.previousHash}`)) {
      broken.push(`#${r.sequenceNumber}: в hashInput нет ссылки на предыдущий хеш`);
    }
    prev = r.currentHash;
  }

  const last = rows[rows.length - 1];
  return {
    rows: rows.length,
    broken,
    lastHash: last ? last.currentHash : null,
    lastSeq: last ? last.sequenceNumber : null,
  };
}

/** Точка входа: проверяет цепочки всех компаний и печатает отчёт. */
async function main() {
  const companies = await prisma.company.findMany({ select: { id: true, name: true } });
  let failed = false;
  for (const c of companies) {
    const res = await checkCompany(c.id);
    if (res.rows === 0) {
      console.log(`${c.name} (${c.id}): записей нет`);
      continue;
    }
    const status = res.broken.length === 0 ? 'OK' : 'СЛОМАНА';
    console.log(
      `${c.name} (${c.id}): ${status}, записей ${res.rows}, последняя #${res.lastSeq} ` +
        `${res.lastHash.slice(0, 16)}…`,
    );
    for (const b of res.broken.slice(0, 5)) console.log(`   - ${b}`);
    if (res.broken.length) failed = true;
  }
  await prisma.$disconnect();
  if (failed) process.exit(1);
}

main().catch(async (e) => {
  console.error(`[chain-check] ошибка: ${e?.message ?? e}`);
  await prisma.$disconnect();
  process.exit(1);
});
