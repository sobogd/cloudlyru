import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import type { Request, Response } from 'express';
import { badRequest, conflict, notFound, payloadTooLarge } from '../errors';

/**
 * Ошибка body-parser'а (express.json): своего класса Nest у неё нет, только поле type.
 * Битое тело — это 400, а не 500: клиент прислал мусор, сервер тут ни при чём.
 */
interface BodyParserError {
  type?: string;
}

/** Ответ неудачного запроса: статус и тело в том же формате, что у ApiError. */
interface Mapped {
  status: number;
  body: Record<string, unknown>;
}

function asBody(exception: HttpException, status: number): Record<string, unknown> {
  const response = exception.getResponse();
  return typeof response === 'string'
    ? { statusCode: status, message: response }
    : (response as Record<string, unknown>);
}

/** Тело ответа берём у самого исключения: у ApiError это уже готовый `{statusCode, message, code}`. */
function mapped(exception: HttpException): Mapped {
  const status = exception.getStatus();
  return { status, body: asBody(exception, status) };
}

function mapException(exception: unknown): Mapped {
  if (exception instanceof HttpException) return mapped(exception);
  // Ошибки Prisma до этого фильтра уходили дефолтным путём Nest, то есть 500 «Internal server
  // error»: клиент считал сервер сломанным там, где на самом деле конфликт имени или запись
  // уже удалена. Гонки за уникальным именем сервисы разбирают сами (conflict 'in_trash'), а
  // это — общий случай, который иначе оставался необъяснимым.
  if (exception instanceof Prisma.PrismaClientKnownRequestError) {
    if (exception.code === 'P2002') return mapped(conflict('unique constraint violated'));
    if (exception.code === 'P2025') return mapped(notFound('record not found'));
  }
  const { type } = (exception ?? {}) as BodyParserError;
  if (type === 'entity.parse.failed') return mapped(badRequest('invalid json body'));
  if (type === 'entity.too.large') return mapped(payloadTooLarge());
  // Всё остальное — наша ошибка. Наружу отдаём общий текст: подробности (имена таблиц,
  // пути в S3, куски запроса) в ответе не нужны, они уходят в лог вместе с id запроса.
  return {
    status: HttpStatus.INTERNAL_SERVER_ERROR,
    body: {
      statusCode: HttpStatus.INTERNAL_SERVER_ERROR,
      message: 'internal server error',
      code: 'internal_error',
    },
  };
}

/**
 * Последний обработчик ошибок: приводит ЛЮБОЕ исключение к формату `{statusCode, message, code}`
 * (его разбирает клиент) и логирует 5xx со стеком и id запроса.
 *
 * Зачем нужен: до него формат существовал только у ApiError. Ошибки Prisma (P2002/P2025),
 * битое тело от express.json и падения S3 выходили дефолтным путём Nest — 500 без кода, по
 * которому клиент мог бы отличить «повтори» от «исправь запрос», и без единой строки в логе
 * с идентификатором запроса, по которому это падение можно найти.
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('http');

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest<Request>();
    const res = ctx.getResponse<Response>();
    const { status, body } = mapException(exception);
    // id запроса ставит RequestLogInterceptor (и отдаёт его в заголовке ответа) — та же строка
    // есть в логе nginx, поэтому по ней сшиваются оба журнала.
    const requestId = String(res.getHeader('x-request-id') ?? '');
    const where = `${req.method ?? '-'} ${req.originalUrl ?? '-'}`;
    const suffix = requestId ? ` [${requestId}]` : '';

    if (status >= HttpStatus.INTERNAL_SERVER_ERROR) {
      const error = exception as Error;
      this.logger.error(`${where} → ${status}${suffix}: ${error?.message ?? String(exception)}`, error?.stack);
    } else if (status === HttpStatus.TOO_MANY_REQUESTS) {
      // 429 — не «наш» сбой, но его появление стоит видеть без включения отладочного уровня
      this.logger.warn(`${where} → ${status}${suffix}`);
    } else {
      this.logger.debug(`${where} → ${status}${suffix}`);
    }

    if (res.headersSent) {
      // отдача уже началась (например, стрим объекта оборвался в середине): тело отправить нечем
      res.end();
      return;
    }
    res.status(status).json(body);
  }
}
