import { SetMetadata, createParamDecorator, ExecutionContext } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';
/** Пропускает AuthGuard (например, /auth/login, /healthz). */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);

export const RATE_LIMIT_KEY = 'rateLimit';

export interface RateLimitOptions {
  limit: number;
  windowMs: number;
}

/** Ограничение частоты запросов на IP. */
export const RateLimit = (limit: number, windowMs: number) =>
  SetMetadata(RATE_LIMIT_KEY, { limit, windowMs } satisfies RateLimitOptions);

export interface RequestUser {
  id: string;
  login: string;
}

/** Текущий аутентифицированный пользователь (req.user), задаётся AuthGuard. */
export const CurrentUser = createParamDecorator((_data: unknown, ctx: ExecutionContext): RequestUser => {
  const request = ctx.switchToHttp().getRequest();
  return request.user;
});
