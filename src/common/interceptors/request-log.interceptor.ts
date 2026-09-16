import { CallHandler, ExecutionContext, Injectable, Logger, NestInterceptor } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { Request, Response } from 'express';
import { Observable, tap } from 'rxjs';

/** Запрос дольше этого порога пишем в обычный лог, а не только в отладочный. */
const SLOW_MS = 1000;

/**
 * Идентификатор запроса и лог запросов.
 *
 * Идентификатор нужен, чтобы связать ответ клиента, строку в логе приложения и запись в
 * журнале nginx: он уходит в заголовке `x-request-id`, а фильтр исключений печатает его же
 * рядом со стеком. Пришедший извне id принимаем как есть (nginx может его проставлять сам),
 * но с ограничением длины — заголовок приходит от клиента, и в лог его пускать без проверки
 * нельзя.
 *
 * Успешные запросы пишутся на уровне verbose, а не log, намеренно: чанки релея — это тысячи
 * запросов на один большой файл, и полный лог запросов утопил бы в себе всё остальное
 * (LOG_LEVEL=verbose включает его целиком). Медленные запросы видны и на обычном уровне:
 * они и есть признак проблемы. Упавшие запросы логирует фильтр исключений — здесь мы их не
 * дублируем, тем более что на этом шаге статус ответа ещё не выставлен.
 */
@Injectable()
export class RequestLogInterceptor implements NestInterceptor {
  private readonly logger = new Logger('http');

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const http = context.switchToHttp();
    const req = http.getRequest<Request>();
    const res = http.getResponse<Response>();

    const incoming = req.headers['x-request-id'];
    const requestId =
      typeof incoming === 'string' && incoming.length > 0 && incoming.length <= 200
        ? incoming
        : randomUUID();
    res.setHeader('x-request-id', requestId);

    const startedAt = Date.now();
    return next.handle().pipe(
      tap(() => {
        const ms = Date.now() - startedAt;
        const line = `${req.method} ${req.originalUrl} → ${res.statusCode} ${ms}ms [${requestId}]`;
        if (ms >= SLOW_MS) this.logger.log(line);
        else this.logger.verbose(line);
      }),
    );
  }
}
