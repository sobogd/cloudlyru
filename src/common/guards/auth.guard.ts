import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { env } from '../../config/env';
import { sha256Hex } from '../utils';
import { PrismaService } from '../../prisma/prisma.service';
import { IS_PUBLIC_KEY } from '../decorators';
import { unauthorized } from '../errors';

const COOKIE = env.COOKIE_NAME;

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly prisma: PrismaService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const req = context.switchToHttp().getRequest();
    const token: unknown = req.cookies?.[COOKIE];
    if (typeof token !== 'string' || token.length === 0) throw unauthorized();

    const session = await this.prisma.session.findUnique({
      where: { tokenHash: sha256Hex(token) },
      include: { user: { select: { id: true, login: true } } },
    });
    if (!session || session.expiresAt.getTime() <= Date.now()) throw unauthorized();

    req.user = { id: session.user.id, login: session.user.login };
    return true;
  }
}
