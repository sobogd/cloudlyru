import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { RATE_LIMIT_KEY, RateLimitOptions } from '../decorators';
import { tooMany } from '../errors';

interface Window {
  count: number;
  resetAt: number;
}

/** Простой in-memory rate limit по IP (для login и чувствительных эндпоинтов). */
@Injectable()
export class RateLimitGuard implements CanActivate {
  private readonly windows = new Map<string, Window>();

  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const opts = this.reflector.get<RateLimitOptions>(RATE_LIMIT_KEY, context.getHandler());
    if (!opts) return true;

    const req = context.switchToHttp().getRequest();
    const ip: string = req.ip ?? req.socket?.remoteAddress ?? 'unknown';
    const now = Date.now();
    const key = `${ip}`;

    let w = this.windows.get(key);
    if (!w || w.resetAt <= now) {
      w = { count: 0, resetAt: now + opts.windowMs };
      this.windows.set(key, w);
    }
    w.count += 1;
    if (w.count > opts.limit) throw tooMany();

    // ленивая чистка
    if (this.windows.size > 10_000) {
      for (const [k, v] of this.windows) {
        if (v.resetAt <= now) this.windows.delete(k);
      }
    }
    return true;
  }
}
