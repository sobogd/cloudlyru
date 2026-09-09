import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { env } from '../../config/env';
import { forbidden } from '../errors';

/**
 * CSRF-защита: для небезопасных методов, если браузер прислал Origin/Referer,
 * он обязан совпадать с BASE_URL. Запросы без Origin (curl, мобильные клиенты) — разрешены.
 */
@Injectable()
export class OriginGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest();
    if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return true;

    const origin: unknown = req.headers['origin'];
    const referer: unknown = req.headers['referer'];
    const baseOrigin = new URL(env.BASE_URL).origin;

    for (const header of [origin, referer]) {
      if (typeof header === 'string' && header.length > 0) {
        let hOrigin: string;
        try {
          hOrigin = new URL(header).origin;
        } catch {
          throw forbidden('bad origin header');
        }
        if (hOrigin !== baseOrigin) throw forbidden('cross-origin request rejected');
      }
    }
    return true;
  }
}
