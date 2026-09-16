import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Response } from 'express';
import { env } from '../../config/env';
import { RATE_LIMIT_KEY, RateLimitOptions } from '../decorators';
import { tooMany } from '../errors';

interface Window {
  count: number;
  resetAt: number;
}

/**
 * Потолок для ручек без своего @RateLimit. Гард зарегистрирован глобально (см. app.module.ts),
 * потому что без этого целые разделы оставались без ограничений вовсе: /apk, WebDAV, файловая
 * часть. Значение задаёт RATE_LIMIT_DEFAULT_PER_MIN, и оно заведомо выше лимитов у ручек с
 * явным @RateLimit (самый щедрый из них — 3000/мин на превью): те пользуются своим числом.
 * 0 в переменной выключает дефолт полностью — аварийный выход, если потолок кому-то помешает.
 */
const DEFAULT_OPTS: RateLimitOptions | null =
  env.RATE_LIMIT_DEFAULT_PER_MIN > 0
    ? { limit: env.RATE_LIMIT_DEFAULT_PER_MIN, windowMs: 60_000 }
    : null;

/**
 * Простой in-memory rate limit по IP. Приоритет у лимита ручки: @RateLimit задаёт своё окно,
 * без декоратора работает общий потолок из RATE_LIMIT_DEFAULT_PER_MIN (0 — не работает).
 * Окна живут в памяти процесса: рестарт обнуляет счётчики, а несколько инстансов считают
 * каждый своё, то есть реальный лимит умножается на их число. Для одного процесса под pm2
 * этого достаточно, но при масштабировании счётчик придётся выносить (например, в Postgres).
 */
@Injectable()
export class RateLimitGuard implements CanActivate {
  private readonly windows = new Map<string, Window>();

  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const opts =
      this.reflector.get<RateLimitOptions>(RATE_LIMIT_KEY, context.getHandler()) ?? DEFAULT_OPTS;
    if (!opts) return true;

    const req = context.switchToHttp().getRequest();
    const ip: string = req.ip ?? req.socket?.remoteAddress ?? 'unknown';
    const now = Date.now();
    // Окно на маршрут, а не на IP: общий счётчик означал, что ручка с щедрым лимитом
    // (ensure-path, 600/мин) съедала бюджет строгой (sync/changes, 240/мин) — телефон
    // получал 429 на догоне журнала и «зеркало сломалось» вместо «подожди минуту».
    // Ключ строится по классу и методу контроллера, а не по req.route.path: он не зависит
    // от версии Express и одинаков для всех запросов к одной ручке.
    const route = `${context.getClass().name}.${context.getHandler().name}`;
    const key = `${ip}:${route}`;

    let w = this.windows.get(key);
    if (!w || w.resetAt <= now) {
      w = { count: 0, resetAt: now + opts.windowMs };
      this.windows.set(key, w);
    }
    w.count += 1;
    if (w.count > opts.limit) {
      // Retry-After ставим прямо на ответ: Nest отдаёт исключение через дефолтный фильтр,
      // который не трогает уже выставленные заголовки, а клиенту без него остаётся только
      // гадать, когда повторять.
      const retryAfterSec = Math.max(1, Math.ceil((w.resetAt - now) / 1000));
      const res = context.switchToHttp().getResponse<Response>();
      res?.setHeader?.('Retry-After', String(retryAfterSec));
      throw tooMany('too many requests', 'rate_limited', retryAfterSec);
    }

    // ленивая чистка
    if (this.windows.size > 10_000) {
      for (const [k, v] of this.windows) {
        if (v.resetAt <= now) this.windows.delete(k);
      }
    }
    return true;
  }
}
