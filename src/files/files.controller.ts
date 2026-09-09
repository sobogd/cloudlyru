import { Controller, Delete, Get, Param, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FilesService } from './files.service';

@Controller('files')
export class FilesController {
  constructor(private readonly files: FilesService) {}

  @Get(':id')
  meta(@Param('id') id: string) {
    return this.files.getEntryMeta(id);
  }

  /** 302 → presigned S3 URL (скачивание оригинала). */
  @Get(':id/content')
  async content(@Param('id') id: string, @Res() res: Response) {
    const url = await this.files.presignedUrl(id);
    return res.redirect(302, url);
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.files.softDelete(id);
  }
}
