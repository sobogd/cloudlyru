import { Body, Controller, Delete, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { RateLimit } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { FoldersService } from './folders.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asOptionalString, asString, isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('folders')
export class FoldersController {
  constructor(private readonly folders: FoldersService) {}

  /** Список верхнего уровня: GET /folders ; вложенные: GET /folders?parentId= */
  @Get()
  list(
    @Query('parentId') parentId: string | undefined,
    @Query('after') after: string | undefined,
    @Query('limit') limit: string | undefined,
    @CurrentUser() user: RequestUser,
  ) {
    return this.folders.listChildren(parentId || undefined, user.id, after || undefined, Number(limit) || undefined);
  }

  /** Список содержимого папки: GET /folders/:id/children */
  /** Содержимое папки порциями: `?after=<последнее имя>&limit=1000` (keyset-пагинация). */
  @Get(':id/children')
  children(
    @Param('id') id: string,
    @Query('after') after: string | undefined,
    @Query('limit') limit: string | undefined,
    @CurrentUser() user: RequestUser,
  ) {
    return this.folders.listChildren(id, user.id, after || undefined, Number(limit) || undefined);
  }

  /** Метаданные папки: GET /folders/:id/meta */
  @Get(':id/meta')
  meta(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.folders.meta(id, user.id);
  }

  @Post()
  create(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const parentId = asOptionalString(body.parentId, 'parentId');
    const name = asString(body.name, 'name');
    return this.folders.create(parentId, name, user.id);
  }

  /**
   * Идемпотентный mkdir по пути: `{ path: "Files/2025/07", parentId? }`.
   * Нужен клиенту синхронизации, чтобы не строить дерево руками.
   */
  @UseGuards(RateLimitGuard)
  // Клиент синхронизации заводит папки по мере обхода дерева: 60/мин упирались в лимит
  // на первом проходе большой папки и роняли весь проход.
  @RateLimit(600, 60_000)
  @Post('ensure-path')
  ensurePath(@Body() body: Record<string, unknown> = {}, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    const path = asString(body.path, 'path');
    const parentId = asOptionalString(body.parentId, 'parentId');
    return this.folders.ensurePath(user.id, path, parentId);
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: RequestUser,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    const hasName = typeof body.name === 'string';
    const hasParent = typeof body.parentId === 'string';
    const hasPin = typeof body.keepOffline === 'boolean';
    if (!hasName && !hasParent && !hasPin) throw badRequest('provide name, parentId or keepOffline');
    return this.folders.patch(
      id,
      {
        name: hasName ? (body.name as string) : undefined,
        parentId: hasParent ? (body.parentId as string) : undefined,
        keepOffline: hasPin ? (body.keepOffline as boolean) : undefined,
      },
      user.id,
    );
  }

  @Delete(':id')
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.folders.softDelete(id, user.id);
  }
}
