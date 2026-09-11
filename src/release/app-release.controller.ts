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
    const release = await this.release.latest();
    if (!release) throw notFound('сборка ещё не опубликована', 'no_release');
    return release;
  }
}
