import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { UnzipService } from './unzip.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { badRequest } from '../common/errors';

/** Разархивирование архивов прямо в хранилище (фоновая задача с прогрессом). */
@Controller('unzip')
export class UnzipController {
  constructor(private readonly unzip: UnzipService) {}

  /** Запустить распаковку архива: { entryId } → задача. */
  @Post()
  start(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const entryId = typeof body?.entryId === 'string' ? body.entryId : '';
    if (!entryId) throw badRequest('entryId обязателен');
    return this.unzip.start(entryId, user.id);
  }

  /** Последняя задача по архиву (для восстановления прогресса в UI). */
  @Get()
  latest(@Query('entryId') entryId: string | undefined, @CurrentUser() user: RequestUser) {
    if (!entryId) throw badRequest('entryId обязателен');
    return this.unzip.latestForEntry(entryId, user.id);
  }

  @Get(':id')
  status(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.unzip.status(id, user.id);
  }

  @Post(':id/cancel')
  cancel(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.unzip.cancel(id, user.id);
  }
}
