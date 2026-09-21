import { Body, Controller, Delete, Get, Param, Patch, Post } from '@nestjs/common';
import { NotesService, NoteView } from './notes.service';
import { CurrentUser, RequestUser, SessionOnly } from '../common/decorators';
import { badRequest } from '../common/errors';
import { isPlainObject } from '../common/utils';

/**
 * Раздел «Заметки»: список, создание, правка и удаление личных заметок.
 *
 * Пометка `@SessionOnly` на весь контроллер: заметки — личный раздел, и device-токену
 * синхронизатора (Bearer) здесь делать нечего. Иначе украденный токен читал бы заметки, хотя
 * ему нужны только ручки `/sync/*`.
 *
 * Тело разбирается руками (в проекте нет `ValidationPipe`): типы полей проверяет сервис, а
 * контроллер лишь убеждается, что пришёл объект, — иначе `body.text` на строке или числе дал бы
 * невнятную ошибку вместо понятного «text must be a string».
 */
@SessionOnly()
@Controller('notes')
export class NotesController {
  constructor(private readonly notes: NotesService) {}

  /** Список заметок в порядке показа (приоритет, затем свежие правки сверху). */
  @Get()
  async list(@CurrentUser() user: RequestUser): Promise<{ notes: NoteView[] }> {
    return { notes: await this.notes.list(user.id) };
  }

  /** Новая заметка: `text` обязателен, `priority` необязателен (по умолчанию низкий). */
  @Post()
  async create(
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ): Promise<{ note: NoteView }> {
    if (!isPlainObject(body)) throw badRequest('body must be an object');
    return { note: await this.notes.create(user.id, body.text, body.priority) };
  }

  /** Правка текста и/или приоритета; `updatedAt` обновляется сам. */
  @Patch(':id')
  async update(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ): Promise<{ note: NoteView }> {
    if (!isPlainObject(body)) throw badRequest('body must be an object');
    return { note: await this.notes.update(user.id, id, { text: body.text, priority: body.priority }) };
  }

  /** Удаление заметки: без корзины, с подтверждением на стороне клиента. */
  @Delete(':id')
  async remove(
    @Param('id') id: string,
    @CurrentUser() user: RequestUser,
  ): Promise<{ ok: true }> {
    await this.notes.remove(user.id, id);
    return { ok: true };
  }
}
