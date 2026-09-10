import { Controller, Delete, Get, Param, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { FilesService } from './files.service';
import { CurrentUser, RequestUser } from '../common/decorators';

@Controller('files')
export class FilesController {
  constructor(private readonly files: FilesService) {}

  @Get(':id')
  meta(@Param('id') id: string) {
    return this.files.getEntryMeta(id);
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

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.files.softDelete(id);
  }
}
