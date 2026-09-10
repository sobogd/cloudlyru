import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { UnzipService } from './unzip.service';
import { badRequest } from '../common/errors';

/** Разархивирование архивов прямо в хранилище (фоновая задача с прогрессом). */
@Controller('unzip')
export class UnzipController {
  constructor(private readonly unzip: UnzipService) {}

  /** Запустить распаковку архива: { entryId } → задача. */
  @Post()
  start(@Body() body: Record<string, unknown>) {
    const entryId = typeof body?.entryId === 'string' ? body.entryId : '';
    if (!entryId) throw badRequest('entryId обязателен');
    return this.unzip.start(entryId);
  }

  /** Последняя задача по архиву (для восстановления прогресса в UI). */
  @Get()
  latest(@Query('entryId') entryId?: string) {
    if (!entryId) throw badRequest('entryId обязателен');
    return this.unzip.latestForEntry(entryId);
  }

  @Get(':id')
  status(@Param('id') id: string) {
    return this.unzip.status(id);
  }

  @Post(':id/cancel')
  cancel(@Param('id') id: string) {
    return this.unzip.cancel(id);
  }
}
