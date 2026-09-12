import { Body, Controller, Delete, Get, Param, Patch, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { FilesService } from './files.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('files')
export class FilesController {
  constructor(private readonly files: FilesService) {}

  @Get(':id')
  meta(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.files.getEntryMeta(id, user.id);
  }

  /**
   * Правка записи клиентом синхронизации: переименование, перенос, «держать офлайн»,
   * mtime с устройства. Перенос — отдельная операция, а не «удали + создай».
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
