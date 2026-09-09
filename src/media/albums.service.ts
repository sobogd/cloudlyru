import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest, notFound } from '../common/errors';

@Injectable()
export class AlbumsService {
  constructor(private readonly prisma: PrismaService) {}

  async create(userId: string, name: string) {
    const clean = String(name ?? '').trim();
    if (!clean || clean.length > 200) throw badRequest('invalid album name');
    const album = await this.prisma.album.create({ data: { userId, name: clean } });
    return { id: album.id, name: album.name, createdAt: album.createdAt, count: 0 };
  }

  async list(userId: string) {
    const albums = await this.prisma.album.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { items: true } } },
    });
    return albums.map((a) => ({ id: a.id, name: a.name, createdAt: a.createdAt, count: a._count.items }));
  }

  async remove(userId: string, albumId: string) {
    const res = await this.prisma.album.deleteMany({ where: { id: albumId, userId } });
    if (!res.count) throw notFound('album not found');
    return { ok: true };
  }

  async addItems(userId: string, albumId: string, entryIds: string[]) {
    const album = await this.prisma.album.findFirst({ where: { id: albumId, userId } });
    if (!album) throw notFound('album not found');
    const ids = Array.isArray(entryIds) ? entryIds.slice(0, 500).filter((x) => typeof x === 'string') : [];
    if (!ids.length) throw badRequest('entryIds required');
    const existing = await this.prisma.fileEntry.findMany({
      where: { id: { in: ids }, deletedAt: null },
      select: { id: true },
    });
    const valid = new Set(existing.map((e) => e.id));
    const rows = ids.filter((id) => valid.has(id)).map((entryId) => ({ albumId, entryId }));
    if (rows.length) {
      await this.prisma.albumItem.createMany({ data: rows, skipDuplicates: true });
    }
    const added = await this.prisma.albumItem.count({ where: { albumId, entryId: { in: ids } } });
    return { ok: true, inAlbum: added };
  }

  async get(userId: string, albumId: string) {
    const album = await this.prisma.album.findFirst({ where: { id: albumId, userId } });
    if (!album) throw notFound('album not found');
    const items = await this.prisma.albumItem.findMany({
      where: { albumId },
      orderBy: { createdAt: 'desc' },
      include: {
        entry: {
          select: {
            id: true,
            name: true,
            asset: { select: { size: true, mime: true, media: { select: { capturedAt: true } } } },
          },
        },
      },
    });
    return {
      id: album.id,
      name: album.name,
      items: items
        .filter((i) => i.entry)
        .map((i) => ({
          entryId: i.entry.id,
          name: i.entry.name,
          size: Number(i.entry.asset.size),
          mime: i.entry.asset.mime,
          capturedAt: i.entry.asset.media?.capturedAt ?? null,
        })),
    };
  }

  async removeItem(userId: string, albumId: string, entryId: string) {
    const album = await this.prisma.album.findFirst({ where: { id: albumId, userId } });
    if (!album) throw notFound('album not found');
    await this.prisma.albumItem.deleteMany({ where: { albumId, entryId } });
    return { ok: true };
  }
}
