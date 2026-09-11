import { HttpException, HttpStatus } from '@nestjs/common';

export class ApiError extends HttpException {
  constructor(status: HttpStatus, message: string, code?: string, extra?: Record<string, unknown>) {
    super({ statusCode: status, message, code: code ?? 'error', ...(extra ?? {}) }, status);
  }
}

export const badRequest = (msg: string, code = 'bad_request') => new ApiError(HttpStatus.BAD_REQUEST, msg, code);
export const unauthorized = (msg = 'unauthorized', code = 'unauthorized') => new ApiError(HttpStatus.UNAUTHORIZED, msg, code);
export const forbidden = (msg = 'forbidden', code = 'forbidden') => new ApiError(HttpStatus.FORBIDDEN, msg, code);
export const notFound = (msg = 'not found', code = 'not_found') => new ApiError(HttpStatus.NOT_FOUND, msg, code);
export const conflict = (msg: string, code = 'conflict', extra?: Record<string, unknown>) =>
  new ApiError(HttpStatus.CONFLICT, msg, code, extra);
/**
 * retryAfterSec — сколько секунд ждать до сброса окна. Тем же значением гард частоты
 * заполняет заголовок Retry-After (HTTP-стандарт), а в теле оно нужно клиентам, которые
 * заголовки не разбирают: телефон по нему откладывает повтор, а не долбит сервер сразу.
 */
export const tooMany = (msg = 'too many requests', code = 'rate_limited', retryAfterSec?: number) =>
  new ApiError(
    HttpStatus.TOO_MANY_REQUESTS,
    msg,
    code,
    retryAfterSec === undefined ? undefined : { retryAfterSec },
  );
export const payloadTooLarge = (msg = 'payload too large', code = 'payload_too_large') =>
  new ApiError(HttpStatus.PAYLOAD_TOO_LARGE, msg, code);
export const notImplemented = (msg = 'not implemented', code = 'not_implemented') =>
  new ApiError(HttpStatus.NOT_IMPLEMENTED, msg, code);
