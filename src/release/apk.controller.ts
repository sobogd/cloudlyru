import { Controller, Get, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { Public, RateLimit } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
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
 *
 * Но публичность не значит «без ограничений»: десятки мегабайт через Node на каждый запрос —
 * это готовый способ выесть канал и память процесса, поэтому здесь стоит тот же лимит по IP,
 * что и на остальных ручках.
 */
@Public()
@UseGuards(RateLimitGuard)
@Controller('apk')
export class ApkController {
  constructor(
    private readonly release: ReleaseService,
    private readonly s3: S3Service,
  ) {}

  /** Скачать последнюю сборку. Через сервис, а не 302 на S3: ссылка не истекает. */
  @RateLimit(30, 60_000)
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

  /**
   * Что именно отдаётся по /apk: версия, размер, sha256.
   * `published: false, fileAvailable: true` — в бакете лежит APK без описания: скачать его
   * можно, но версии и контрольной суммы у нас нет, и выдавать нули за факт нельзя.
   */
  @RateLimit(60, 60_000)
  @Get('version')
  async version() {
    const release = await this.release.latest();
    if (!release) return { published: false };
    if (!release.metaKnown) return { published: false, fileAvailable: true };
    return { published: true, ...release };
  }
}
