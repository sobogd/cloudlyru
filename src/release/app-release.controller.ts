import { Controller, Get } from '@nestjs/common';
import { Public } from '../common/decorators';
import { notFound } from '../common/errors';
import { ReleaseService } from './release.service';

/**
 * Та же информация о сборке, но внутри API: телефон спрашивает её у своего сервера
 * (`{адрес}/api/v1/app/android`) и сравнивает versionCode со своим.
 *
 * Ручка без авторизации: проверка обновления не должна требовать валидного токена —
 * приложение как раз может стоять с отозванным, а починиться ему нужно.
 */
@Public()
@Controller('app/android')
export class AppReleaseController {
  constructor(private readonly release: ReleaseService) {}

  @Get()
  async latest() {
    const release = await this.release.latest('android');
    // metaKnown=false — APK лежит в бакете без описания: отдать приложению versionCode 0
    // и sha256 '' значило бы соврать про сборку. Клиент обязан увидеть тот же `no_release`,
    // что и при пустом бакете, а скачать файл руками по-прежнему можно через /apk.
    if (!release || !release.metaKnown) throw notFound('сборка ещё не опубликована', 'no_release');
    return release;
  }
}

/**
 * То же для настольной сборки macOS: приложение с мака спрашивает `{адрес}/api/v1/app/macos`
 * и сравнивает со своим номером сборки (`CFBundleVersion`) — он берётся из того же `+N`
 * в `flutter/pubspec.yaml`, что и `versionCode` на Android, поэтому счётчик у платформ общий.
 *
 * Отдельная ручка, а не параметр у предыдущей: сборки разных платформ лежат в бакете порознь
 * и публикуются порознь — если настольную ещё не собирали, мак не должен получить версию
 * мобильной сборки.
 */
@Public()
@Controller('app/macos')
export class AppReleaseMacosController {
  constructor(private readonly release: ReleaseService) {}

  @Get()
  async latest() {
    const release = await this.release.latest('macos');
    if (!release || !release.metaKnown) throw notFound('сборка ещё не опубликована', 'no_release');
    return release;
  }
}
