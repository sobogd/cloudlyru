import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class AuditService {
  private readonly logger = new Logger(AuditService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Аудит — best-effort: ошибка записи наружу не пробрасывается никогда, иначе недоступная
   * таблица роняла бы логин, выпуск токенов и чистку корзины.
   *
   * Читателей и ретенции у журнала в коде нет: он ведётся «на разбор» — по нему восстанавливают,
   * кто и когда входил, выпускал и отзывал токены, чистил корзину. Записи при этом не привязаны
   * к пользователю: в строке есть только action/meta/ip, поэтому «всё, что делал пользователь»
   * по ней не выбрать. Колонка userId и уборка старых строк требуют миграции схемы; до неё
   * владельца операции приходится класть в meta руками (в очистке корзины этого пока нет).
   */
  async log(action: string, meta?: Record<string, unknown>, ip?: string) {
    try {
      await this.prisma.auditLog.create({
        data: { action, meta: meta ? (meta as Prisma.InputJsonValue) : undefined, ip },
      });
    } catch (err) {
      // аудит не должен ронять бизнес-операции, но и падать молча он не должен: без этой строки
      // «в журнале пусто» выглядело как «ничего не происходило», и потерянная запись о
      // необратимой операции (например, очистке корзины) не находилась потом ничем.
      const error = err as Error;
      this.logger.error(
        `не удалось записать аудит ${action}: ${error?.message ?? String(err)}`,
        error?.stack,
      );
    }
  }
}
