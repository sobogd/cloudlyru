import { HttpException, HttpStatus } from '@nestjs/common';

export class ApiError extends HttpException {
  constructor(status: HttpStatus, message: string, code?: string) {
    super({ statusCode: status, message, code: code ?? 'error' }, status);
  }
}

export const badRequest = (msg: string, code = 'bad_request') => new ApiError(HttpStatus.BAD_REQUEST, msg, code);
export const unauthorized = (msg = 'unauthorized', code = 'unauthorized') => new ApiError(HttpStatus.UNAUTHORIZED, msg, code);
export const forbidden = (msg = 'forbidden', code = 'forbidden') => new ApiError(HttpStatus.FORBIDDEN, msg, code);
export const notFound = (msg = 'not found', code = 'not_found') => new ApiError(HttpStatus.NOT_FOUND, msg, code);
export const conflict = (msg: string, code = 'conflict') => new ApiError(HttpStatus.CONFLICT, msg, code);
export const tooMany = (msg = 'too many requests', code = 'rate_limited') =>
  new ApiError(HttpStatus.TOO_MANY_REQUESTS, msg, code);
export const payloadTooLarge = (msg = 'payload too large', code = 'payload_too_large') =>
  new ApiError(HttpStatus.PAYLOAD_TOO_LARGE, msg, code);
export const notImplemented = (msg = 'not implemented', code = 'not_implemented') =>
  new ApiError(HttpStatus.NOT_IMPLEMENTED, msg, code);
