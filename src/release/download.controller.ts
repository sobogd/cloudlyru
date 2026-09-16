import { Controller, Get, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { Public, RateLimit } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { sendObjectOr404 } from '../common/http-object';
import { S3Service } from '../s3/s3.service';
import { RELEASE_ARTIFACTS, ReleasePlatform, ReleaseService } from './release.service';

/**
 * Постоянные ссылки на последние сборки: `/apk` для Android и `/macos` для настольной сборки
 * (без префикса api/v1 — их открывают руками в браузере). Всегда отдают то, что лежит
 * в релизном артефакте, поэтому ссылку никому не приходится обновлять.
 *
 * Файлы публичные намеренно: приложения уже отдаются по ссылке, а секретов в сборке нет
 * (адрес сервера и токен вводятся в приложении, в сборку ничего не зашито).
 *
 * Но публичность не значит «без ограничений»: десятки мегабайт через Node на каждый запрос —
 * это готовый способ выесть канал и память процесса, поэтому здесь стоит тот же лимит по IP,
 * что и на остальных ручках.
 */
@Public()
@UseGuards(RateLimitGuard)
@Controller()
export class ReleaseDownloadController {
  constructor(
    private readonly release: ReleaseService,
    private readonly s3: S3Service,
  ) {}

  /** Скачать последнюю сборку Android-клиента. Через сервис, а не 302 на S3: ссылка не истекает. */
  @RateLimit(30, 60_000)
  @Get(RELEASE_ARTIFACTS.android.path)
  async downloadApk(@Req() req: Request, @Res() res: Response) {
    return this.send('android', req, res);
  }

  /**
   * Что именно отдаётся по /apk: версия, размер, sha256.
   * `published: false, fileAvailable: true` — в бакете лежит APK без описания: скачать его
   * можно, но версии и контрольной суммы у нас нет, и выдавать нули за факт нельзя.
   */
  @RateLimit(60, 60_000)
  @Get(`${RELEASE_ARTIFACTS.android.path}/version`)
  async versionApk() {
    return this.version('android');
  }

  /** Скачать последнюю настольную сборку (архив с `Cloudly.app`). */
  @RateLimit(30, 60_000)
  @Get(RELEASE_ARTIFACTS.macos.path)
  async downloadMacos(@Req() req: Request, @Res() res: Response) {
    return this.send('macos', req, res);
  }

  /** Версия настольной сборки — то же, что `/apk/version`, но для macOS. */
  @RateLimit(60, 60_000)
  @Get(`${RELEASE_ARTIFACTS.macos.path}/version`)
  async versionMacos() {
    return this.version('macos');
  }

  /**
   * Отдать файл сборки платформы или честный 404, если её ещё не публиковали.
   *
   * Кэш на минуту: свежая сборка должна разъезжаться сразу, а не после истечения суток.
   */
  private async send(platform: ReleasePlatform, req: Request, res: Response) {
    const artifact = RELEASE_ARTIFACTS[platform];
    const release = await this.release.latest(platform);
    if (!release) {
      res.status(404).type('text/plain; charset=utf-8').send('сборка ещё не опубликована');
      return;
    }
    return sendObjectOr404(req, res, this.s3, artifact.key, {
      mime: artifact.mime,
      disposition: 'attachment',
      filename: artifact.name,
      cache: 'public, max-age=60',
    });
  }

  private async version(platform: ReleasePlatform) {
    const release = await this.release.latest(platform);
    if (!release) return { published: false };
    if (!release.metaKnown) return { published: false, fileAvailable: true };
    return { published: true, ...release };
  }
}
