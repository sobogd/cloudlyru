import { Controller, Get, Req, Res } from '@nestjs/common';
import type { Request, Response } from 'express';
import { Public } from '../common/decorators';
import { sendObjectOr404 } from '../common/http-object';
import { S3Service } from '../s3/s3.service';
import { APK_KEY, APK_MIME, APK_NAME, ReleaseService } from './release.service';

/**
 * Постоянная ссылка на последнюю сборку Android-клиента: `/apk` (без префикса api/v1 —
 * её открывают руками в браузере и вбивают в телефон). Всегда отдаёт то, что лежит
 * в релизном артефакте, поэтому ссылку никому не приходится обновлять.
 *
 * Файл публичный намеренно: приложения уже отдаются по ссылке, а секретов в APK нет
 * (адрес сервера и токен вводятся на телефоне, в сборку ничего не зашито).
 */
@Public()
@Controller('apk')
export class ApkController {
  constructor(
    private readonly release: ReleaseService,
    private readonly s3: S3Service,
  ) {}

  /** Скачать последнюю сборку. Через сервис, а не 302 на S3: ссылка не истекает. */
  @Get()
  async download(@Req() req: Request, @Res() res: Response) {
    const release = await this.release.latest();
    if (!release) {
      res.status(404).type('text/plain; charset=utf-8').send('сборка ещё не опубликована');
      return;
    }
    return sendObjectOr404(req, res, this.s3, APK_KEY, {
      mime: APK_MIME,
      disposition: 'attachment',
      filename: APK_NAME,
      // минута: свежая сборка должна разъезжаться сразу, а не после истечения суток кэша
      cache: 'public, max-age=60',
    });
  }

  /** Что именно отдаётся по /apk: версия, размер, sha256. */
  @Get('version')
  async version() {
    const release = await this.release.latest();
    if (!release) return { published: false };
    return { published: true, ...release };
  }
}
