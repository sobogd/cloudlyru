import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { CurrentUser, RateLimit, RequestUser } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { isPlainObject } from '../common/utils';
import { DevicesService } from './devices.service';
import { badRequest } from '../common/errors';

/**
 * Телефоны-исполнители. Одни ручки для телефона (представиться, отдать состояние, забрать
 * команды и подтвердить их), другие для веба (список устройств, дерево телефона, команда).
 * Авторизация одна: device-токен в Bearer у телефона, cookie-сессия у веба.
 */
@Controller('devices')
export class DevicesController {
  constructor(private readonly devices: DevicesService) {}

  /** Телефон представился: `POST /devices/hello { label }`. */
  @UseGuards(RateLimitGuard)
  @RateLimit(60, 60_000)
  @Post('hello')
  hello(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.devices.hello(user.id, body.label);
  }

  /** Телефон отдал состояние: `POST /devices/state { deviceId, entries }`. */
  @UseGuards(RateLimitGuard)
  @RateLimit(120, 60_000)
  @Post('state')
  state(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.devices.saveState(user.id, body.deviceId, body.entries);
  }

  /** Телефон забирает команды: `GET /devices/:id/commands`. */
  @UseGuards(RateLimitGuard)
  @RateLimit(240, 60_000)
  @Get(':id/commands')
  pending(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.devices.pending(user.id, id);
  }

  /** Телефон подтверждает команду: `POST /devices/:id/commands/:commandId/ack`. */
  @UseGuards(RateLimitGuard)
  @RateLimit(240, 60_000)
  @Post(':id/commands/:commandId/ack')
  ack(
    @Param('id') id: string,
    @Param('commandId') commandId: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.devices.ack(user.id, id, commandId, body);
  }

  /** Веб ставит команду телефону: `POST /devices/:id/commands { kind, payload }`. */
  @Post(':id/commands')
  command(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @CurrentUser() user: RequestUser,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    return this.devices.command(user.id, id, body.kind, body.payload);
  }

  /** Веб: какие телефоны подключены и что у них с очередью. */
  @Get()
  list(@CurrentUser() user: RequestUser) {
    return this.devices.list(user.id);
  }

  /** Веб: дерево телефона — структура выбранных папок и состояние файлов. */
  @Get(':id/tree')
  tree(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.devices.tree(user.id, id);
  }
}
