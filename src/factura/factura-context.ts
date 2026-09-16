import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import type { Request } from 'express';
import { env } from '../config/env';
import { unauthorized } from '../common/errors';

/**
 * Контекст фактурных ручек: чей это запрос и в какой компании он работает.
 *
 * В исходном сервисе (iq-factura-api) этот контекст собирал собственный `AuthGuard`: читал
 * куку сессии, находил пользователя и выбирал активную компанию из `x-company-id`, куки
 * `iqf_active_company` или первой привязки в `users_companies`. Здесь пользователя уже
 * аутентифицировал глобальный `AuthGuard` облака (`src/common/guards/auth.guard.ts`), а
 * компания ровно одна — она задана в конфиге (`FACTURA_COMPANY_ID`), поэтому от мультиарендности
 * остаётся только имя: все 60 с лишним мест в перенесённом коде читают `authUser.companyId`
 * и продолжают работать без правок.
 *
 * Гард ставится на каждый фактурный контроллер (`@UseGuards(FacturaContextGuard)`): глобальные
 * гарды Nest выполняют раньше контроллерных, поэтому `req.user` здесь уже заполнен.
 */
export interface AuthedRequest extends Request {
  /** Заполняется этим гардом; форма совпадает с прежним `AuthedRequest` фактуры. */
  authUser: {
    userId: string;
    email: string;
    companyId: string;
  };
}

/** Пользователь, которого глобальный `AuthGuard` положил в запрос. */
interface RequestWithUser extends Request {
  user?: { id: string; login: string };
}

@Injectable()
export class FacturaContextGuard implements CanActivate {
  /**
   * Переносит аутентифицированного пользователя в `authUser` и подставляет компанию из конфига.
   *
   * @param context контекст выполнения Nest.
   * @returns всегда true: если пользователя нет, глобальный гард уже ответил 401, а сюда мы
   *   попадаем только с ним. Проверка ниже — страховка на случай, если гард однажды снимут
   *   с глобальных и запрос дойдёт до фактурной ручки без аутентификации.
   * @throws ApiError 401, если пользователя в запросе нет.
   * Побочный эффект: мутирует объект запроса, добавляя `authUser`.
   */
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest<RequestWithUser>();
    const user = req.user;
    if (!user?.id) throw unauthorized();

    (req as AuthedRequest).authUser = {
      userId: user.id,
      email: user.login,
      companyId: env.FACTURA_COMPANY_ID,
    };
    return true;
  }
}
