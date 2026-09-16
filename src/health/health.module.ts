import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { PrismaModule } from '../prisma/prisma.module';

// PrismaModule импортируется явно, хотя он @Global: зависимость контроллера должна быть видна
// из самого модуля, иначе порядок инициализации начинает зависеть от того, что кто-то другой
// уже подключил Prisma.
@Module({ imports: [PrismaModule], controllers: [HealthController] })
export class HealthModule {}
