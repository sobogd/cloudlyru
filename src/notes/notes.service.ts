import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest, notFound } from '../common/errors';

/** Приоритет заметки: три уровня. */
export type NotePriority = 'high' | 'medium' | 'low';

/** Числовой ранг приоритета для сортировки: чем меньше, тем выше заметка в списке. */
const PRIORITY_RANK: Record<NotePriority, number> = { high: 0, medium: 1, low: 2 };

/**
 * Потолок длины текста заметки. Postgres хранит TEXT без ограничения, но мегабайт текста —
 * это уже не заметка; 100 000 символов — с большим запасом к реальным записям и защита от
 * случайной вставки файла в поле.
 */
export const MAX_NOTE_CHARS = 100_000;

/**
 * Проверка приоритета. Колонка в БД текстовая, поэтому доверять её типу нельзя: значение
 * может прийти из чужого клиента или остаться от ручной правки, и `as NotePriority` просто
 * соврал бы компилятору, пропустив несуществующий уровень дальше в список.
 */
export function isNotePriority(v: unknown): v is NotePriority {
  return v === 'high' || v === 'medium' || v === 'low';
}

/** Ранг для сортировки; неизвестное значение считаем низким, чтобы порча записи не ломала список. */
function rankOf(priority: string): number {
  return isNotePriority(priority) ? PRIORITY_RANK[priority] : PRIORITY_RANK.low;
}

/** Заметка в том виде, в каком её видит клиент. */
export interface NoteView {
  id: string;
  text: string;
  priority: NotePriority;
  createdAt: string;
  updatedAt: string;
}

/** Приоритет для записи: неизвестное значение — ошибка запроса, а не повод подставить низкий. */
function cleanPriority(v: unknown): NotePriority {
  if (!isNotePriority(v)) throw badRequest('priority: high|medium|low');
  return v;
}

/**
 * Раздел «Заметки»: короткие тексты с приоритетом, одни на все устройства.
 *
 * Хранится на сервере (как чаты и память), поэтому заметка, написанная на телефоне, видна на
 * ноутбуке и переживает переустановку приложения. Ничего, кроме Prisma, сервису не нужно.
 *
 * Сортировку списка делает сервер, а не клиент: порядок «приоритет, затем свежие правки» должен
 * быть одинаковым на всех клиентах, а один источник правила — одна причина для расхождений
 * меньше. Пагинации нет: заметок у человека немного, и список читается одним запросом.
 */
@Injectable()
export class NotesService {
  private readonly logger = new Logger('Notes');

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Все заметки пользователя в порядке показа.
   *
   * Порядок собирается здесь, а не индексом в БД: `ORDER BY` по вычисляемому рангу приоритета
   * требует `CASE`, которого Prisma не умеет в `orderBy`, а держать ранг отдельной колонкой —
   * лишнее поле, которое надо не забыть обновить при каждом приоритете. Стабильная сортировка
   * массива сохраняет порядок «свежие правки сверху» внутри одного уровня.
   */
  async list(userId: string): Promise<NoteView[]> {
    const rows = await this.prisma.note.findMany({ where: { userId } });
    return rows
      .sort((a, b) => {
        const byPriority = rankOf(a.priority) - rankOf(b.priority);
        if (byPriority !== 0) return byPriority;
        return b.updatedAt.getTime() - a.updatedAt.getTime();
      })
      .map(toView);
  }

  /**
   * Новая заметка. [priority] необязателен — без него заметка создаётся низкой.
   *
   * Пустой текст отвергаем: заметка без текста не несёт ничего, и в списке она выглядела бы
   * пустой строкой, которую нельзя ни опознать, ни открыть осмысленно.
   */
  async create(userId: string, text: unknown, priority?: unknown): Promise<NoteView> {
    const clean = cleanText(text);
    const row = await this.prisma.note.create({
      data: { userId, text: clean, priority: priority === undefined ? 'low' : cleanPriority(priority) },
    });
    return toView(row);
  }

  /**
   * Правка текста и/или приоритета. Меняются только переданные поля, `updatedAt` ставит Prisma.
   *
   * Пустой патч — не ошибка, а ответ «ничего не менялось»: так клиент, сохраняющий заметку без
   * правок (например, автосейв сразу после открытия), получает текущее состояние, а не 400.
   */
  async update(
    userId: string,
    id: string,
    patch: { text?: unknown; priority?: unknown },
  ): Promise<NoteView> {
    const data: { text?: string; priority?: NotePriority } = {};
    if (patch.text !== undefined) data.text = cleanText(patch.text);
    if (patch.priority !== undefined) data.priority = cleanPriority(patch.priority);
    if (Object.keys(data).length === 0) return toView(await this.getOwn(userId, id));

    // Правка чужой/несуществующей заметки должна дать 404, а не создать новую строку: `update`
    // по несуществующему id падает с P2025, но собственность надо проверить до самого запроса,
    // иначе ошибка Prisma станет 500 вместо внятного 404.
    await this.getOwn(userId, id);
    const row = await this.prisma.note.update({ where: { id }, data });
    this.logger.log(`заметка обновлена: ${id}`);
    return toView(row);
  }

  /**
   * Удаление заметки — насовсем, без корзины: отдельная корзина для заметки была бы лишним
   * механизмом ради короткого текста.
   *
   * Удаляем по паре `(id, userId)` одним запросом, без предварительной проверки владельца: так
   * нет промежутка между «проверил» и «удалил», в который запись мог бы удалить другой клиент.
   * Ничего не удалилось — значит заметка чужая или её уже нет; обе причины для клиента
   * одинаковы — 404.
   */
  async remove(userId: string, id: string): Promise<void> {
    const { count } = await this.prisma.note.deleteMany({ where: { id, userId } });
    if (count === 0) throw notFound('note not found');
    this.logger.log(`заметка удалена: ${id}`);
  }

  /** Заметка пользователя или 404: чужая и несуществующая для клиента неразличимы. */
  private async getOwn(userId: string, id: string) {
    const row = await this.prisma.note.findFirst({ where: { id, userId } });
    if (!row) throw notFound('note not found');
    return row;
  }
}

/**
 * Проверка и очистка текста. Возвращает текст как есть: переносы строк и отступы, которые
 * человек сделал в поле ввода, должны дойти до базы без изменений — это и есть смысл заметки.
 * Проверяем только «не пусто» (по trim: пробелы и переводы строк заметкой не считаются) и длину.
 */
function cleanText(v: unknown): string {
  if (typeof v !== 'string') throw badRequest('text must be a string');
  if (v.trim().length === 0) throw badRequest('заметка не может быть пустой', 'note_empty');
  if (v.length > MAX_NOTE_CHARS) {
    throw badRequest(`текст заметки длиннее ${MAX_NOTE_CHARS} символов`, 'note_too_long');
  }
  return v;
}

/** Строка БД → ответ клиенту: даты в ISO, приоритет проверен на известность. */
function toView(row: {
  id: string;
  text: string;
  priority: string;
  createdAt: Date;
  updatedAt: Date;
}): NoteView {
  return {
    id: row.id,
    text: row.text,
    priority: isNotePriority(row.priority) ? row.priority : 'low',
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}
