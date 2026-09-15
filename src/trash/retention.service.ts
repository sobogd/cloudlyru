import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AuditService } from '../audit/audit.service';
import { TrashService } from './trash.service';
import { MailFeedService } from '../mail/mail-feed.service';
import { TRASH_RETENTION_MS } from '../config/env';

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Срок хранения журнала изменений. Tombstones живут вечно по замыслу (клиент иначе зальёт
 * удалённый файл обратно), но и расти без предела им незачем: клиент, отставший от головы
 * журнала сильнее, получает от `/sync/changes` `resetRequired` и делает полный проход —
 * механизм уже есть. 90 дней — заведомо больше, чем телефон бывает выключен.
 */
export const CHANGELOG_RETENTION_MS = 90 * DAY_MS;

/** Как часто прогоняем уборку. Корзина живёт 30 дней, журнал — 90: чаще незачем. */
const SWEEP_MS = 6 * 60 * 60 * 1000;

/**
 * Порция удаления журнала и потолок порций за один проход: одна DELETE на миллионы строк
 * держала бы таблицу заблокированной, а первый прогон после деплоя не должен занимать
 * весь старт сервиса — остаток доберёт следующая уборка.
 */
const PRUNE_BATCH = 5000;
const MAX_PRUNE_BATCHES = 200;

/**
 * Сроки хранения: без него «корзина чистится через 30 дней» было только обещанием
 * (`TRASH_RETENTION_MS` был объявлен и не использовался), а запись в корзине занимала имя
 * навсегда — файл с тем же именем нельзя было залить уже никогда.
 *
 * Устроено как свип брошенных upload-сессий в UploadsService: интервал + прогон при старте.
 */
@Injectable()
export class RetentionService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RetentionService.name);
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly trash: TrashService,
    private readonly mail: MailFeedService,
    private readonly audit: AuditService,
  ) {}

  async onModuleInit() {
    await this.sweep();
    this.timer = setInterval(() => void this.sweep(), SWEEP_MS);
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  /** Один проход уборки. Ошибка не должна ронять ни процесс, ни следующую уборку. */
  private async sweep(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await this.purgeExpiredTrash();
      await this.pruneChangeLog();
    } catch (e) {
      this.logger.warn(`retention: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      this.running = false;
    }
  }

  /**
   * Физическое удаление корзины старше срока хранения — существующим purge() (он сам пишет
   * tombstones, удаляет строки и осиротевшие объекты в S3), а не второй реализацией.
   */
  private async purgeExpiredTrash(): Promise<void> {
    const cutoff = new Date(Date.now() - TRASH_RETENTION_MS);
    // Дешёвый предохранитель перед уборкой: purge() дополнительно сканирует все ассеты
    // на осиротевшие, и гонять это каждые 6 часов на пустой корзине незачем. Письма — тоже
    // часть корзины: без них в проверке корзина из одних писем не чистилась бы никогда.
    const [entries, folders, messages] = await Promise.all([
      this.prisma.fileEntry.count({ where: { deletedAt: { lt: cutoff } } }),
      this.prisma.folder.count({ where: { deletedAt: { lt: cutoff } } }),
      this.prisma.mailMessage.count({ where: { deletedAt: { lt: cutoff } } }),
    ]);
    if (!entries && !folders && !messages) return;

    const days = Math.round(TRASH_RETENTION_MS / DAY_MS);
    const users = await this.prisma.user.findMany({ select: { id: true } });
    for (const user of users) {
      try {
        const res = await this.trash.purge(user.id, days);
        if (res.purgedEntries || res.purgedFolders) {
          this.logger.log(
            `корзина файлов старше ${days} дней: удалено файлов ${res.purgedEntries}, папок ${res.purgedFolders}, ` +
              `объектов ${res.purgedAssets}`,
          );
        }
      } catch (e) {
        // уборка одного дерева не должна мешать остальным и следующей уборке
        this.logger.warn(`purge корзины файлов (${user.id}): ${e instanceof Error ? e.message : String(e)}`);
      }
      try {
        const res = await this.mail.purgeTrash(user.id, days);
        if (res.purged) this.logger.log(`корзина почты старше ${days} дней: удалено писем ${res.purged}`);
      } catch (e) {
        this.logger.warn(`purge корзины почты (${user.id}): ${e instanceof Error ? e.message : String(e)}`);
      }
    }
  }

  /**
   * Подрезка журнала изменений по сроку хранения. Строки удаляем пачками от самых старых:
   * клиент, чей курсор оказался старше новой головы журнала, получит `resetRequired`
   * и сделает полный проход (см. SyncService.changes).
   */
  private async pruneChangeLog(): Promise<void> {
    const cutoff = new Date(Date.now() - CHANGELOG_RETENTION_MS);
    let deleted = 0;
    for (let batch = 0; batch < MAX_PRUNE_BATCHES; batch++) {
      const rows = await this.prisma.changeLog.findMany({
        where: { at: { lt: cutoff } },
        select: { seq: true },
        orderBy: { seq: 'asc' },
        take: PRUNE_BATCH,
      });
      if (!rows.length) break;
      const res = await this.prisma.changeLog.deleteMany({ where: { seq: { in: rows.map((r) => r.seq) } } });
      deleted += res.count;
    }
    if (!deleted) return;
    const days = Math.round(CHANGELOG_RETENTION_MS / DAY_MS);
    this.logger.log(`журнал изменений: удалено строк старше ${days} дней — ${deleted}`);
    await this.audit.log('changelog.prune', { deleted, olderThanDays: days });
  }
}
