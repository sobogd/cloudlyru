import { Body, Controller, Delete, Get, Param, Post, Query } from '@nestjs/common';
import { MediaService } from './media.service';
import { AlbumsService } from './albums.service';
import { CurrentUser, RequestUser } from '../common/decorators';
import { asString, isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller()
export class MediaController {
  constructor(
    private readonly media: MediaService,
    private readonly albums: AlbumsService,
  ) {}

  // ===== Таймлайн / поездки =====

  @Get('timeline')
  timeline(@Query('limit') limit?: string, @Query('before') before?: string) {
    const lim = limit ? Number(limit) : 300;
    return this.media.timeline(Number.isFinite(lim) ? lim : 300, typeof before === 'string' ? before : undefined);
  }

  @Get('trips')
  trips() {
    return this.media.trips();
  }

  // ===== Альбомы =====

  @Get('albums')
  listAlbums(@CurrentUser() user: RequestUser) {
    return this.albums.list(user.id);
  }

  @Post('albums')
  createAlbum(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.albums.create(user.id, asString(body.name, 'name'));
  }

  @Get('albums/:id')
  getAlbum(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.albums.get(user.id, id);
  }

  @Post('albums/:id/items')
  addItems(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    if (!isPlainObject(body) || !Array.isArray(body.entryIds)) throw badRequest('entryIds array required');
    return this.albums.addItems(user.id, id, body.entryIds as string[]);
  }

  @Delete('albums/:id')
  removeAlbum(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.albums.remove(user.id, id);
  }

  @Delete('albums/:id/items/:entryId')
  removeItem(@Param('id') id: string, @Param('entryId') entryId: string, @CurrentUser() user: RequestUser) {
    return this.albums.removeItem(user.id, id, entryId);
  }
}
