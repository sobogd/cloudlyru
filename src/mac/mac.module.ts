import { Module } from '@nestjs/common';
import { MacController } from './mac.controller';
import { MacService } from './mac.service';

/**
 * Раздел «Mac»: статус и управление домашним маком.
 *
 * Модулю не нужно ничего, кроме самого сервиса: состояние и действия живут на маке в
 * `mac-status-server.py`, а сервер только проксирует ручки `/mac/*` к панели
 * (`http://127.0.0.1:18810`), видимой через reverse-SSH туннель (`com.agent.mac-tunnel`),
 * открытый на loopback самого VPS.
 *
 * Ни базы, ни ключей: клиент приложения не знает ни адреса панели, ни порта туннеля.
 */
@Module({
  controllers: [MacController],
  providers: [MacService],
})
export class MacModule {}
