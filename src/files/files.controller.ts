import { Body, Controller, Delete, Get, Param, Patch, Post, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { FilesService } from './files.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

const BULK_IDS_MAX = 500;

/** Массив строк, без дублей и пустых, не больше [BULK_IDS_MAX]. */
function bulkIds(body: unknown): string[] {
  if (!isPlainObject(body) || !Array.isArray(body.ids)) throw badRequest('invalid body');
  const ids = [...new Set(body.ids.filter((v): v is string => typeof v === 'string' && v.length > 0))];
  if (!ids.length) throw badRequest('no ids');
  if (ids.length > BULK_IDS_MAX) throw badRequest('too many ids');
  return ids;
}

@Controller('files')
export class FilesController {
  constructor(private readonly files: FilesService) {}

  /** Пакетный soft-delete: список id из тела. До маршрутов с `:id`, чтобы id не перехватывал путь. */
  @Post('bulk-delete')
  bulkDelete(@Body() body: unknown, @CurrentUser() user: RequestUser) {
    return this.files.softDeleteMany(bulkIds(body), user.id);
  }

  @Get(':id')
  meta(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.files.getEntryMeta(id, user.id);
  }

  /**
   * Правка записи клиентом синхронизации: переименование, перенос и mtime с устройства.
   * Перенос — отдельная операция, а не «удали + создай». Флага «держать офлайн» в контракте
   * нет: фича снята с поддержки, поле в схеме осталось легаси и кодом не читается.
   */
  @Patch(':id')
  patch(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.files.patch(id, user.id, body);
  }

  /**
   * Скачивание оригинала. Стримим через сервис: никаких presigned-ссылок наружу
   * (ссылка на S3 работает без авторизации) и никакого рендера в браузере —
   * Content-Disposition: attachment плюс имя файла из дерева.
   */
  @Get(':id/content')
  async content(
    @Param('id') id: string,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    return this.files.download(id, user.id, req, res);
  }

  /** Показ картинки в интерфейсе (миниатюры альбомов); всё опасное уходит на скачивание. */
  @Get(':id/inline')
  async inline(
    @Param('id') id: string,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    return this.files.inlineImage(id, user.id, req, res);
  }

  /** Миниатюра 50×50 для списка файлов (собранная очередью, а не оригинал). */
  @Get(':id/thumb')
  async thumb(
    @Param('id') id: string,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    return this.files.thumb(id, user.id, req, res);
  }

  @Delete(':id')
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.files.softDelete(id, user.id);
  }
}
