import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { env } from '../../config/env';
import { sha256Hex } from '../utils';
import { PrismaService } from '../../prisma/prisma.service';
import { AuthService } from '../../auth/auth.service';
import { IS_PUBLIC_KEY, READ_ONLY_ALLOWED_KEY, SESSION_ONLY_KEY } from '../decorators';
import { forbidden, unauthorized } from '../errors';
import { setCurrentDeviceId } from '../request-context';

const COOKIE = env.COOKIE_NAME;
const SAFE_METHODS = ['GET', 'HEAD', 'OPTIONS'];

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const req = context.switchToHttp().getRequest();
    const sessionOnly = this.reflector.getAllAndOverride<boolean>(SESSION_ONLY_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    // Живая cookie проверяется первой и побеждает Bearer: браузер шлёт её сам, и это
    // единственный признак веб-сессии (у неё нет ни scope, ни deviceId). Но МЁРТВАЯ cookie
    // (протухла, удалена на сервере, осталась от другого аккаунта) больше не запирает ручку:
    // раньше при ней отвечали 401, не глядя на Bearer, и клиент с валидным device-токеном
    // не мог ничего сделать, пока в браузере живёт просроченная cookie (logout её не чистит).
    // Теперь мёртвая cookie просто не аутентифицирует, и разбор идёт дальше — до Bearer.
    const token: unknown = req.cookies?.[COOKIE];
    if (typeof token === 'string' && token.length > 0) {
      const session = await this.prisma.session.findUnique({
        where: { tokenHash: sha256Hex(token) },
        include: { user: { select: { id: true, login: true } } },
      });
      if (session && session.expiresAt.getTime() > Date.now()) {
        req.user = { id: session.user.id, login: session.user.login };
        return true;
      }
    }

    // ApiToken в Bearer — тот же app-password, что и Basic в WebDAV: мобильному клиенту
    // не нужны ни cookie-сессия, ни логин с паролем на телефоне. Токен со scope files:ro
    // пускается только на чтение.
    const header: unknown = req.headers['authorization'];
    if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
      if (sessionOnly) throw forbidden('this endpoint requires a web session, not an API token');
      const resolved = await this.auth.resolveApiToken(header.slice(7).trim());
      if (!resolved) throw unauthorized('invalid token');
      const readOnlyAllowed = this.reflector.getAllAndOverride<boolean>(READ_ONLY_ALLOWED_KEY, [
        context.getHandler(),
        context.getClass(),
      ]);
      const writes = !SAFE_METHODS.includes(String(req.method)) && !readOnlyAllowed;
      if (writes && !resolved.scope.endsWith(':rw')) {
        throw forbidden('token is read-only');
      }
      const user = await this.prisma.user.findUnique({
        where: { id: resolved.userId },
        select: { id: true, login: true },
      });
      if (!user) throw unauthorized('invalid token');
      req.user = { id: user.id, login: user.login, scope: resolved.scope, deviceId: resolved.tokenId };
      // id токена = identity устройства: из контекста его читает журнал изменений,
      // иначе клиент не отличит свои правки от чужих (common/request-context.ts)
      setCurrentDeviceId(resolved.tokenId);
      return true;
    }

    throw unauthorized();
  }
}
