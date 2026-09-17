import { Prisma } from '@prisma/client';
import type { MailBox } from './mail-accounts.service';

/**
 * Письмо лежит в папке, если она у него основная (`box`) или дополнительная (`alsoBoxes`).
 *
 * Нужен один общий ответ на вопрос «что показывать в этой папке», иначе лента, счётчики у
 * ящиков и индекс месяцев разъедутся: письмо, отправленное себе, было бы видно в списке, но
 * не посчитано, или наоборот.
 */
export function inBox(box: MailBox): Prisma.MailMessageWhereInput {
  return { OR: [{ box }, { alsoBoxes: { has: box } }] };
}

/** То же условие для сырого SQL (индекс месяцев): папка основная или есть среди дополнительных. */
export function inBoxSql(box: MailBox): Prisma.Sql {
  return Prisma.sql`("box" = ${box} OR ${box} = ANY("alsoBoxes"))`;
}

/**
 * Условие «письмо лежит в папке» для сырого SQL — им лента, её счётчики и поиск ограничивают
 * выборку.
 *
 * Корзина почты — это не папка из box/alsoBoxes, а состояние `deletedAt`, поэтому у неё
 * своё условие; обычные папки фильтруются и по принадлежности, и по «не в корзине».
 * Условие общее для всех читающих запросов намеренно: своё в каждом месте означало бы,
 * что письмо видно в списке, но не находится поиском (или наоборот).
 */
export function boxConditionSql(box: MailBox): Prisma.Sql {
  if (box === 'trash') return Prisma.sql`"deletedAt" IS NOT NULL`;
  return Prisma.sql`"deletedAt" IS NULL AND ${inBoxSql(box)}`;
}

