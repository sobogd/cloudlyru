import { Body, Controller, Delete, Get, Param, Patch, Post, Query } from '@nestjs/common';
import { FoldersService } from './folders.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asOptionalString, asString, isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('folders')
export class FoldersController {
  constructor(private readonly folders: FoldersService) {}

  /** Список верхнего уровня: GET /folders ; вложенные: GET /folders?parentId= */
  @Get()
  list(@Query('parentId') parentId: string | undefined, @CurrentUser() user: RequestUser) {
    return this.folders.listChildren(parentId || undefined, user.id);
  }

  /** Список содержимого папки: GET /folders/:id/children */
  @Get(':id/children')
  children(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.folders.listChildren(id, user.id);
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
