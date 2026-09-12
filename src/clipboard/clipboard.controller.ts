import { Body, Controller, Delete, Get, Post } from '@nestjs/common';
import { ClipboardService, ClipboardKind, ClipboardMode, ClipboardView } from './clipboard.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

/**
 * Буфер копирования/вырезания. Отдельная ручка, а не поля в PATCH файла: вставка — это
 * действие над буфером и папкой, а не правка одного файла, и работает для папок тоже.
 */
@Controller('clipboard')
export class ClipboardController {
  constructor(private readonly clipboard: ClipboardService) {}

  @Get()
  get(@CurrentUser() user: RequestUser): Promise<ClipboardView | null> {
    return this.clipboard.get(user.id);
  }

  /** «Скопировать»/«вырезать» из деталки файла или папки. */
  @Post()
  set(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser): Promise<ClipboardView> {
    if (!isPlainObject(body)) throw badRequest('body must be an object');
    const kind = asString(body.kind, 'kind');
    const mode = asString(body.mode, 'mode');
    if (kind !== 'file' && kind !== 'folder') throw badRequest('kind: file|folder');
    if (mode !== 'copy' && mode !== 'cut') throw badRequest('mode: copy|cut');
    return this.clipboard.set(user.id, kind as ClipboardKind, asString(body.id, 'id'), mode as ClipboardMode);
  }

  /** Очистить буфер вручную (крестик рядом с «вставить»). */
  @Delete()
  async clear(@CurrentUser() user: RequestUser): Promise<{ ok: true }> {
    await this.clipboard.clear(user.id);
    return { ok: true };
  }

  /** «Вставить» в папку: перенос для вырезанного, копия для скопированного. */
  @Post('paste')
  paste(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('body must be an object');
    return this.clipboard.paste(user.id, asString(body.folderId, 'folderId'));
  }
}
