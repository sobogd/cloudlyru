import { SetMetadata, createParamDecorator, ExecutionContext } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';
/** Пропускает AuthGuard (например, /auth/login, /healthz). */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);

export const READ_ONLY_ALLOWED_KEY = 'readOnlyAllowed';
/**
 * Ручка читает данные, но вызывается POST-ом (например `/sync/have` с телом-списком sha).
 * Без этой пометки токен со scope `files:ro` получал бы на неё 403 просто за метод.
 */
export const ReadOnlyAllowed = () => SetMetadata(READ_ONLY_ALLOWED_KEY, true);

export const SESSION_ONLY_KEY = 'sessionOnly';
/**
 * Только веб-сессия (cookie), ApiToken в Bearer не пускается.
 * Нужно для ручек, которые не должны быть доступны устройству-клиенту: выпуск и отзыв
 * токенов (иначе украденный токен выдаёт себе новый и отзыв перестаёт работать)
 * и безвозвратная очистка корзины.
 */
export const SessionOnly = () => SetMetadata(SESSION_ONLY_KEY, true);

export const RATE_LIMIT_KEY = 'rateLimit';

export interface RateLimitOptions {
  limit: number;
  windowMs: number;
}

/**
 * Ограничение частоты запросов на IP для конкретной ручки. Задаёт своё окно и перебивает общий
 * дефолт гарда (RATE_LIMIT_DEFAULT_PER_MIN): у ручек с декоратором лимит строже общего, потому
 * что цена ошибки тут выше — перебор пароля, отправка почты, тяжёлые выборки.
 */
export const RateLimit = (limit: number, windowMs: number) =>
  SetMetadata(RATE_LIMIT_KEY, { limit, windowMs } satisfies RateLimitOptions);

export interface RequestUser {
  id: string;
  login: string;
  /** scope ApiToken'а (files:rw / files:ro); у веб-сессии не задан. */
  scope?: string;
  /** id ApiToken'а (identity устройства) при аутентификации по Bearer; у веб-сессии не задан. */
  deviceId?: string;
}

/** Текущий аутентифицированный пользователь (req.user), задаётся AuthGuard. */
export const CurrentUser = createParamDecorator((_data: unknown, ctx: ExecutionContext): RequestUser => {
  const request = ctx.switchToHttp().getRequest();
  return request.user;
});
