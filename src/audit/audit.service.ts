import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class AuditService {
  constructor(private readonly prisma: PrismaService) {}

  async log(action: string, meta?: Record<string, unknown>, ip?: string) {
    try {
      await this.prisma.auditLog.create({
        data: { action, meta: meta ? (meta as Prisma.InputJsonValue) : undefined, ip },
      });
    } catch {
      // аудит не должен ронять бизнес-операции
    }
  }
}
