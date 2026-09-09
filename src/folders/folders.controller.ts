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

  @Post()
  create(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const parentId = asOptionalString(body.parentId, 'parentId');
    const name = asString(body.name, 'name');
    return this.folders.create(parentId, name, user.id);
  }

  @Patch(':id')
  update(
    @Param('id') id: string,
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: RequestUser,
  ) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    if (typeof body.name === 'string') return this.folders.rename(id, body.name, user.id);
    if (typeof body.parentId === 'string') return this.folders.move(id, body.parentId, user.id);
    throw badRequest('provide name or parentId');
  }

  @Delete(':id')
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.folders.softDelete(id, user.id);
  }
}
