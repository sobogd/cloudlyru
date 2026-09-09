import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import cookieParser from 'cookie-parser';
import { existsSync } from 'fs';
import { join } from 'path';
import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import { AppModule } from './app.module';
import { env } from './config/env';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.setGlobalPrefix('api/v1');
  app.enableShutdownHooks();

  // JSON-парсер ТОЛЬКО для application/json: бинарные чанки загрузок
  // приходят как stream (raw body) и не должны быть съедены парсером.
  app.use(express.json({ type: 'application/json', limit: '1mb' }));
  app.use(cookieParser());

  // SPA (web/dist), если собран рядом с рантаймом — статика + fallback на index.html
  const webDist = join(process.cwd(), 'web', 'dist');
  if (existsSync(webDist)) {
    app.use(express.static(webDist));
    app.use((req: Request, res: Response, next: NextFunction) => {
      if (req.method === 'GET' && !req.path.startsWith('/api/')) {
        return res.sendFile(join(webDist, 'index.html'), (err?: Error) => {
          if (err) next(err);
        });
      }
      return next();
    });
  }

  // nginx проксирует с 127.0.0.1; наружу порт не публикуем.
  await app.listen(env.PORT, '127.0.0.1');
  // eslint-disable-next-line no-console
  console.log(`[cloudlyru] listening on http://127.0.0.1:${env.PORT} (${env.NODE_ENV})`);
}
bootstrap();
