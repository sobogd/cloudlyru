import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { badRequest, notFound } from '../common/errors';

/** Что телефон прислал про файл: структура и состояние в очереди. */
export interface DeviceEntryInput {
  section: string;
  path: string;
  name: string;
  isDir?: boolean;
  size?: number;
  mtime?: string | null;
  /** Абсолютный путь на телефоне: веб по нему просит выгрузить файл. */
  localPath?: string | null;
  state?: string;
  error?: string | null;
}

export interface DeviceCommandDto {
  id: string;
  kind: string;
  payload: unknown;
  createdAt: string;
}

/** Что веб может попросить у телефона. Список закрытый: команду придумывает не клиент. */
export const COMMAND_KINDS = [
  /** Пройти папки и пересобрать очередь. */
  'SYNC_NOW',
  /** Остановить текущую выгрузку. */
  'PAUSE',
  /** Продолжить выгрузку. */
  'RESUME',
  /** Выгрузить конкретный путь (или всё из папки). */
  'UPLOAD_PATH',
  /** Забрать изменения облака (переименования, новые версии) и применить на телефоне. */
  'APPLY_CHANGES',
] as const;

const ENTRY_STATES = ['LOCAL', 'PENDING', 'RUNNING', 'DONE', 'SKIPPED', 'FAILED'];
const MAX_ENTRIES = 50_000;
const MAX_PATH = 1024;

/**
 * Телефоны-исполнители: чем они представились, что у них лежит и что им велено сделать.
 *
 * Приложение здесь исполнитель, а пульт — веб: очередь и команды живут на сервере, телефон
 * забирает их, выполняет и отчитывается. Отдельного канала наружу телефону не нужно:
 * он сам спрашивает команды, поэтому «нажал в вебе, а телефон был не в сети» не теряется —
 * команда дождётся следующего подключения.
 */
@Injectable()
export class DevicesService {
  private readonly logger = new Logger(DevicesService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** Телефон представился: заводим устройство и сразу отдаём то, что для него накопилось. */
  async hello(userId: string, labelRaw: unknown): Promise<{ deviceId: string; commands: DeviceCommandDto[] }> {
    const label = typeof labelRaw === 'string' && labelRaw.trim() ? labelRaw.trim().slice(0, 64) : 'android';
    const now = new Date();
    const device = await this.prisma.device.upsert({
      where: { userId_label: { userId, label } },
      create: { userId, label, connectedAt: now, lastSeenAt: now },
      update: { connectedAt: now, lastSeenAt: now },
    });
    return { deviceId: device.id, commands: await this.pending(userId, device.id) };
  }

  /**
   * Снимок состояния телефона. Приходит целиком и заменяет прошлый: телефон присылает
   * и структуру выбранных папок, и состояние файлов, поэтому «дописать недописанное»
   * было бы сложнее, чем переписать снимок.
   */
  async saveState(
    userId: string,
    deviceIdRaw: unknown,
    entriesRaw: unknown,
  ): Promise<{ saved: number; commands: DeviceCommandDto[] }> {
    const deviceId = await this.ownDevice(userId, deviceIdRaw);
    if (!Array.isArray(entriesRaw)) throw badRequest('entries must be an array');
    if (entriesRaw.length > MAX_ENTRIES) throw badRequest(`too many entries (max ${MAX_ENTRIES})`);

    const rows = entriesRaw.map((raw) => this.parseEntry(raw));
    const now = new Date();
    await this.prisma.$transaction(async (tx) => {
      await tx.deviceEntry.deleteMany({ where: { deviceId } });
      const chunk = 500;
      for (let i = 0; i < rows.length; i += chunk) {
        await tx.deviceEntry.createMany({
          data: rows.slice(i, i + chunk).map((row) => ({ ...row, deviceId, seenAt: now })),
        });
      }
      await tx.device.update({ where: { id: deviceId }, data: { lastSeenAt: now, connectedAt: now } });
    });
    this.logger.log(`состояние телефона ${deviceId}: записей ${rows.length}`);
    // команды отдаём сразу в ответе: телефону не нужен отдельный запрос после отчёта
    return { saved: rows.length, commands: await this.pending(userId, deviceId) };
  }

  /** Команды, которые телефон ещё не забрал. */
  async pending(userId: string, deviceIdRaw: unknown): Promise<DeviceCommandDto[]> {
    const deviceId = await this.ownDevice(userId, deviceIdRaw);
    const rows = await this.prisma.deviceCommand.findMany({
      where: { deviceId, state: 'pending' },
      orderBy: { createdAt: 'asc' },
      take: 100,
    });
    if (rows.length) {
      await this.prisma.deviceCommand.updateMany({
        where: { id: { in: rows.map((r) => r.id) } },
        data: { state: 'sent', sentAt: new Date() },
      });
    }
    return rows.map((row) => ({
      id: row.id,
      kind: row.kind,
      payload: row.payload ?? null,
      createdAt: row.createdAt.toISOString(),
    }));
  }

  /** Телефон отчитался о команде: выполнена или нет, с причиной. */
  async ack(userId: string, deviceIdRaw: unknown, commandId: unknown, body: Record<string, unknown>) {
    const deviceId = await this.ownDevice(userId, deviceIdRaw);
    const id = String(commandId ?? '');
    if (!id) throw badRequest('commandId is required');
    const command = await this.prisma.deviceCommand.findFirst({ where: { id, deviceId } });
    if (!command) throw notFound('command not found');
    const failed = body.error != null && String(body.error).trim() !== '';
    await this.prisma.deviceCommand.update({
      where: { id },
      data: {
        state: failed ? 'failed' : 'done',
        error: failed ? String(body.error).slice(0, 500) : null,
        doneAt: new Date(),
      },
    });
    return { ok: true };
  }

  /** Веб: список телефонов с их свежестью. */
  async list(userId: string) {
    const devices = await this.prisma.device.findMany({
      where: { userId },
      orderBy: { createdAt: 'asc' },
    });
    const counts = await this.prisma.deviceEntry.groupBy({
      by: ['deviceId', 'state'],
      where: { deviceId: { in: devices.map((d) => d.id) } },
      _count: { _all: true },
    });
    return devices.map((device) => ({
      id: device.id,
      label: device.label,
      lastSeenAt: device.lastSeenAt?.toISOString() ?? null,
      connectedAt: device.connectedAt?.toISOString() ?? null,
      states: counts
        .filter((c) => c.deviceId === device.id)
        .reduce<Record<string, number>>((acc, c) => ({ ...acc, [c.state]: c._count._all }), {}),
    }));
  }

  /** Веб: что на телефоне — структура выбранных папок и состояние файлов. */
  async tree(userId: string, deviceIdRaw: unknown) {
    const deviceId = await this.ownDevice(userId, deviceIdRaw);
    const [device, entries] = await Promise.all([
      this.prisma.device.findUnique({ where: { id: deviceId } }),
      this.prisma.deviceEntry.findMany({ where: { deviceId }, orderBy: { path: 'asc' } }),
    ]);
    return {
      deviceId,
      label: device?.label ?? '',
      lastSeenAt: device?.lastSeenAt?.toISOString() ?? null,
      entries: entries.map((e) => ({
        section: e.section,
        path: e.path,
        name: e.name,
        isDir: e.isDir,
        size: Number(e.size),
        mtime: e.mtime?.toISOString() ?? null,
        localPath: e.localPath,
        state: e.state,
        error: e.error,
      })),
    };
  }

  /** Веб: поставить команду телефону. */
  async command(userId: string, deviceIdRaw: unknown, kindRaw: unknown, payloadRaw: unknown) {
    const deviceId = await this.ownDevice(userId, deviceIdRaw);
    const kind = typeof kindRaw === 'string' ? kindRaw : '';
    if (!(COMMAND_KINDS as readonly string[]).includes(kind)) {
      throw badRequest(`unknown command: ${kind || '(пусто)'}`);
    }
    const payload =
      payloadRaw != null && typeof payloadRaw === 'object' && !Array.isArray(payloadRaw) ? payloadRaw : null;
    const command = await this.prisma.deviceCommand.create({
      data: { deviceId, kind, payload: payload as never },
    });
    return { id: command.id, kind: command.kind, payload: command.payload ?? null, createdAt: command.createdAt.toISOString() };
  }

  /** Устройство должно принадлежать этому пользователю: по чужому id делать нечего. */
  private async ownDevice(userId: string, deviceIdRaw: unknown): Promise<string> {
    const deviceId = typeof deviceIdRaw === 'string' ? deviceIdRaw.trim() : '';
    if (!deviceId) throw badRequest('deviceId is required');
    const device = await this.prisma.device.findFirst({ where: { id: deviceId, userId } });
    if (!device) throw notFound('device not found');
    return device.id;
  }

  private parseEntry(raw: unknown): Omit<DeviceEntryInput, 'isDir' | 'size' | 'mtime'> & {
    isDir: boolean;
    size: bigint;
    mtime: Date | null;
  } {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw badRequest('entry must be an object');
    const entry = raw as Record<string, unknown>;
    const section = String(entry.section ?? '');
    if (section !== 'FILES' && section !== 'PHOTOS') throw badRequest(`bad section: ${section || '(пусто)'}`);
    const path = String(entry.path ?? '');
    if (!path || path.length > MAX_PATH) throw badRequest('bad path');
    const name = String(entry.name ?? path.split('/').pop() ?? '');
    const state = String(entry.state ?? 'LOCAL');
    if (!ENTRY_STATES.includes(state)) throw badRequest(`bad state: ${state}`);
    const sizeRaw = Number(entry.size ?? 0);
    const mtimeRaw = entry.mtime;
    const mtime = typeof mtimeRaw === 'string' && mtimeRaw ? new Date(mtimeRaw) : null;
    return {
      section,
      path,
      name: name.slice(0, 255),
      isDir: entry.isDir === true,
      size: BigInt(Number.isFinite(sizeRaw) && sizeRaw > 0 ? Math.floor(sizeRaw) : 0),
      mtime: mtime && !Number.isNaN(mtime.getTime()) ? mtime : null,
      localPath:
        typeof entry.localPath === 'string' && entry.localPath ? entry.localPath.slice(0, MAX_PATH) : null,
      state,
      error: entry.error == null ? null : String(entry.error).slice(0, 500),
    };
  }
}
