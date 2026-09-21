import { Controller, Get, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { Public, RateLimit } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { sendObjectOr404 } from '../common/http-object';
import { S3Service } from '../s3/s3.service';
import {
  AppRelease,
  RELEASE_ARTIFACTS,
  ReleasePlatform,
  ReleaseService,
} from './release.service';

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

  /** Скачать последнюю сборку для iPad и iPhone (Ad Hoc архив `.ipa`). */
  @RateLimit(30, 60_000)
  @Get(RELEASE_ARTIFACTS.ios.path)
  async downloadIos(@Req() req: Request, @Res() res: Response) {
    return this.send('ios', req, res);
  }

  /**
   * Манифест, по которому iPad ставит сборку сам (`itms-services`).
   *
   * Генерируется на каждый запрос, а не лежит рядом с архивом: адрес архива, идентификатор
   * приложения и версия берутся из `latest.json`, поэтому после новой публикации манифест
   * не нужно обновлять руками.
   *
   * Без описания сборки (`metaKnown=false`) отвечаем 404: в манифест нечего положить —
   * пустые идентификатор и версию система прочитает как битую сборку, и человек получит
   * «не удалось установить» вместо понятного «сборка ещё не опубликована».
   */
  @RateLimit(60, 60_000)
  @Get(`${RELEASE_ARTIFACTS.ios.path}/manifest.plist`)
  async iosManifest(@Res() res: Response) {
    const release = await this.release.latest('ios');
    if (!release || !release.metaKnown) {
      res.status(404).type('text/plain; charset=utf-8').send('сборка ещё не опубликована');
      return;
    }
    res
      .type('application/xml; charset=utf-8')
      .send(otaManifest(release, this.release.publicUrl('ios')));
  }

  /**
   * Страница установки для самого устройства: её открывают на iPad, и оттуда одним нажатием
   * ставится сборка.
   *
   * Отдельная страница нужна потому, что ссылку `itms-services` Safari принимает только
   * из адресной строки и только по нажатию человека: если отправить её письмом или в чат,
   * установка не начнётся. Ссылка на эту страницу как раз переносится куда угодно.
   */
  @RateLimit(60, 60_000)
  @Get(`${RELEASE_ARTIFACTS.ios.path}/install`)
  async iosInstall(@Res() res: Response) {
    const release = await this.release.latest('ios');
    if (!release || !release.metaKnown) {
      res.status(404).type('text/plain; charset=utf-8').send('сборка ещё не опубликована');
      return;
    }
    const manifestUrl = `${this.release.publicUrl('ios')}/manifest.plist`;
    res.type('text/html; charset=utf-8').send(installPage(release, manifestUrl));
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

/**
 * Манифест установки по воздуху — формат Apple для `itms-services`.
 *
 * `bundle-version` — короткая версия (`CFBundleShortVersionString`), а не номер сборки:
 * система показывает её человеку и сверяет с той, что лежит в самой сборке.
 * Ссылка на архив постоянная (`/ios`), поэтому манифест всегда указывает на последнюю сборку.
 */
function otaManifest(release: AppRelease, ipaUrl: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>${esc(ipaUrl)}</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>${esc(release.applicationId)}</string>
				<key>bundle-version</key>
				<string>${esc(release.versionName)}</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>Cloudly</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
`;
}

/**
 * Страница с кнопкой установки. Разметка внутри строки, а не шаблоном: страница одна,
 * и держать ради неё отдельный файл с шаблонизатором несоразмерно.
 */
function installPage(release: AppRelease, manifestUrl: string): string {
  const link = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cloudly — установка</title>
<style>
	:root { color-scheme: dark; }
	body { margin: 0; padding: 40px 20px; background: #101114; color: #e9eaee;
	       font: 16px/1.5 -apple-system, system-ui, sans-serif; text-align: center; }
	.card { max-width: 420px; margin: 0 auto; }
	a.button { display: inline-block; margin: 24px 0 8px; padding: 14px 28px; border-radius: 12px;
	           background: #4c8dff; color: #fff; text-decoration: none; font-weight: 600; }
	.muted { color: #9aa0ab; font-size: 14px; }
	ol { text-align: left; color: #9aa0ab; font-size: 14px; }
</style>
</head>
<body>
	<div class="card">
		<h1>Cloudly</h1>
		<p class="muted">версия ${esc(release.versionName)} (сборка ${release.versionCode}), ${sizeMb(release.size)}</p>
		<a class="button" href="${esc(link)}">Установить</a>
		<p class="muted">Открывать нужно в Safari и на том устройстве, для которого собрана сборка:
			в профиль подписи вписаны конкретные устройства по UDID.</p>
		<ol>
			<li>Нажмите «Установить» и подтвердите.</li>
			<li>Если система спросит про доверие разработчику, разрешите установку.</li>
			<li>Иконка Cloudly появится на домашнем экране.</li>
		</ol>
	</div>
</body>
</html>
`;
}

/** Размер сборки словами: мегабайт с одним знаком — больше в этой строке и не нужно. */
function sizeMb(size: number): string {
  return `${(size / 1048576).toFixed(1)} МБ`;
}

/**
 * Экранирование подставляемых значений. Данные приходят из `latest.json`, который пишет наш
 * скрипт публикации, но в бакете мог оказаться и чужой файл: без экранирования его содержимое
 * исполнилось бы как разметка на нашем домене.
 */
function esc(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
