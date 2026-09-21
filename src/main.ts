import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import cookieParser from 'cookie-parser';
import { Logger, LogLevel, RequestMethod, ValidationPipe } from '@nestjs/common';
import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { env } from './config/env';
import { runWithRequestContext } from './common/request-context';

const logger = new Logger('bootstrap');

/**
 * Уровень логирования процесса. По умолчанию 'log' (ошибки, предупреждения, события) —
 * отладочные уровни включаются на время разбора: на 'verbose' пишется ещё и лог запросов,
 * которого в обычном режиме нет намеренно (см. RequestLogInterceptor).
 */
const LOG_LEVELS: Record<string, LogLevel[]> = {
  error: ['error', 'fatal'],
  warn: ['error', 'fatal', 'warn'],
  log: ['error', 'fatal', 'warn', 'log'],
  debug: ['error', 'fatal', 'warn', 'log', 'debug'],
  verbose: ['error', 'fatal', 'warn', 'log', 'debug', 'verbose'],
};

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    logger: LOG_LEVELS[env.LOG_LEVEL],
  });
  // /apk, /macos и /ios — постоянные ссылки на последние сборки приложения, их открывают
  // в браузере и вбивают в телефон: префикс api/v1 тут только мешал бы. У iOS это ещё и
  // требование установки: адрес манифеста и архива попадает в систему, и лишний сегмент
  // пути в нём — лишняя причина, по которой установка не начнётся.
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'apk', method: RequestMethod.GET },
      { path: 'apk/version', method: RequestMethod.GET },
      { path: 'macos', method: RequestMethod.GET },
      { path: 'macos/version', method: RequestMethod.GET },
      { path: 'ios', method: RequestMethod.GET },
      { path: 'ios/manifest.plist', method: RequestMethod.GET },
      { path: 'ios/install', method: RequestMethod.GET },
    ],
  });
  app.enableShutdownHooks();

  // nginx проксирует с 127.0.0.1 и подставляет X-Forwarded-For. Без trust proxy
  // req.ip у всех запросов был 127.0.0.1: rate-limit логина превращался в один общий
  // счётчик (любой мог заблокировать вход владельцу), а в аудите не было реальных IP.
  app.set('trust proxy', 'loopback');
  // меньше информации о стеке наружу
  app.disable('x-powered-by');

  // Контекст запроса заводим до роутера Nest: гард кладёт в него deviceId, а журнал изменений
  // читает его из любой глубины сервисов (см. common/request-context.ts). Без ALS пришлось бы
  // тащить deviceId аргументом через все вызовы changes.record.
  app.use((_req: Request, _res: Response, next: NextFunction) => {
    runWithRequestContext({}, () => next());
  });

  // JSON-парсер ТОЛЬКО для application/json: бинарные чанки загрузок
  // приходят как stream (raw body) и не должны быть съедены парсером.
  // Поэтому лимит 1 МБ безопасен для всех ручек: мимо парсера идут все крупные тела — чанки
  // загрузки (application/octet-stream) и письма Postfix читаются самими ручками стримом и
  // со своим лимитом, а через json проходят только небольшие служебные тела.
  app.use(express.json({ type: 'application/json', limit: '1mb' }));
  app.use(cookieParser());

  // Валидация тел запросов — ровно как в исходном сервисе фактур: DTO описаны классами с
  // декораторами class-validator, и без пайпа эти декораторы не делают ничего (невалидное тело
  // доходило бы до Prisma и превращалось в 500 вместо 400).
  //
  // `whitelist: true` вырезает поля без декораторов — так в БД не попадает ничего лишнего.
  // `transform: true` включает `@Type(() => Number)`: суммы и ставки приходят из JSON строками
  // чаще, чем кажется, и без преобразования Prisma получила бы строку вместо числа.
  //
  // На собственные ручки облака это не влияет: пайп пропускает параметры без метатипа-класса
  // (`Record<string, unknown>`, интерфейсы, примитивы), а контроллеры облака разбирают тела
  // руками — DTO-классов у них нет вовсе. См. комментарий в `src/app.module.ts`.
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      transform: true,
      forbidNonWhitelisted: false,
    }),
  );

  // nginx проксирует с 127.0.0.1; наружу порт не публикуем.
  await app.listen(env.PORT, '127.0.0.1');
  logger.log(`слушаем http://127.0.0.1:${env.PORT} (${env.NODE_ENV}, логи: ${env.LOG_LEVEL})`);
}

// Раньше bootstrap() вызывался без обработчика: EADDRINUSE (порт занят после неудачного
// рестарта pm2) превращался в unhandled rejection с невнятным стеком, и в логе не было
// видно, что именно не поднялось.
void bootstrap().catch((err: unknown) => {
  const error = err as Error;
  logger.error(`не удалось запуститься: ${error?.message ?? String(err)}`, error?.stack);
  process.exit(1);
});

// У процессов под pm2 не было ни одного глобального обработчика, поэтому любое отклонение
// промиса, оставшееся без catch, роняло сервис по правилу Node по умолчанию
// (--unhandled-rejections=throw) — например, отклонение префетч-промисов Range-запросов в
// s3.hashObject, то есть штатный путь каждой прямой загрузки. Пишем и продолжаем работу:
// один сбойный запрос к S3 не должен обрывать все идущие загрузки.
process.on('unhandledRejection', (reason: unknown) => {
  const error = reason as Error;
  logger.error(
    `необработанное отклонение промиса: ${error?.message ?? String(reason)}`,
    error?.stack,
  );
});

// А после uncaughtException состояние процесса уже неизвестно: пишем и выходим, чтобы pm2
// поднял чистый (молча продолжать работу с непонятным состоянием хуже рестарта).
process.on('uncaughtException', (err: Error) => {
  logger.error(`необработанное исключение: ${err.message}`, err.stack);
  process.exit(1);
});
