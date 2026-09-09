import { Global, Module } from '@nestjs/common';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { AuditService } from '../audit/audit.service';

/**
 * @Global: AuthService (seed владельца, корень) и AuditService — единые инстансы
 * для всех модулей (Folders/Uploads/Trash используют AuthService).
 */
@Global()
@Module({
  controllers: [AuthController],
  providers: [AuthService, AuditService],
  exports: [AuthService, AuditService],
})
export class AuthModule {}
