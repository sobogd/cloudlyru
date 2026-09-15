import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import cookieParser from 'cookie-parser';
import { RequestMethod } from '@nestjs/common';
import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { env } from './config/env';
import { runWithRequestContext } from './common/request-context';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  // /apk — постоянная ссылка на последнюю сборку мобильного приложения, её открывают
  // в браузере и вбивают в телефон: префикс api/v1 тут только мешал бы.
  app.setGlobalPrefix('api/v1', {
    exclude: [
      { path: 'apk', method: RequestMethod.GET },
      { path: 'apk/version', method: RequestMethod.GET },
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
  app.use(express.json({ type: 'application/json', limit: '1mb' }));
  app.use(cookieParser());

  // nginx проксирует с 127.0.0.1; наружу порт не публикуем.
  await app.listen(env.PORT, '127.0.0.1');
  // eslint-disable-next-line no-console
  console.log(`[cloudlyru] listening on http://127.0.0.1:${env.PORT} (${env.NODE_ENV})`);
}
bootstrap();
