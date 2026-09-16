import { Body, Controller, Get, Post, Req } from '@nestjs/common';
import type { Request } from 'express';
import { TrashService } from './trash.service';
import { CurrentUser, RequestUser, SessionOnly } from '../common/decorators';
import { isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('trash')
export class TrashController {
  constructor(private readonly trash: TrashService) {}

  @Get()
  list(@CurrentUser() user: RequestUser) {
    return this.trash.list(user.id);
  }

  @Post('restore')
  restore(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    if (body.type !== 'folder' && body.type !== 'file') throw badRequest('type must be folder|file');
    if (typeof body.id !== 'string') throw badRequest('id required');
    return this.trash.restore(body.type, body.id, user.id);
  }

  /**
   * Безвозвратная очистка корзины — только из веб-сессии: устройство со своим токеном
   * не должно уметь вычистить единственную точку восстановления одним запросом.
   * IP передаём в аудит: операция необратима, и по одной записи должно быть видно, откуда
   * она пришла (владелец и источник пишет сам сервис).
   */
  @SessionOnly()
  @Post('purge')
  purge(
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    const raw = typeof body.olderThanDays === 'number' ? body.olderThanDays : undefined;
    // NaN и отрицательное раньше означали «вычистить всё» (cutoff в будущем) — клампим
    const days = raw === undefined || !Number.isFinite(raw) ? undefined : Math.max(0, raw);
    return this.trash.purge(user.id, days, { ip: req.ip, source: 'user' });
  }
}
