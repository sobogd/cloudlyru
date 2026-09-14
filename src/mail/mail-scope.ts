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
