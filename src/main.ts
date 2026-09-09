import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import cookieParser from 'cookie-parser';
import { AppModule } from './app.module';
import { env } from './config/env';
import { json } from 'express';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  app.enableShutdownHooks();

  // JSON-парсер ТОЛЬКО для application/json: бинарные чанки загрузок
  // приходят как stream (raw body) и не должны быть съедены парсером.
  app.use(json({ type: 'application/json', limit: '1mb' }));
  app.use(cookieParser());

  // nginx проксирует с 127.0.0.1; наружу порт не публикуем.
  await app.listen(env.PORT, '127.0.0.1');
  // eslint-disable-next-line no-console
  console.log(`[cloudlyru] listening on http://127.0.0.1:${env.PORT} (${env.NODE_ENV})`);
}
bootstrap();
