import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import cookieParser from 'cookie-parser';
import { existsSync } from 'fs';
import { join } from 'path';
import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { env } from './config/env';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  app.setGlobalPrefix('api/v1');
  app.enableShutdownHooks();

  // nginx проксирует с 127.0.0.1 и подставляет X-Forwarded-For. Без trust proxy
  // req.ip у всех запросов был 127.0.0.1: rate-limit логина превращался в один общий
  // счётчик (любой мог заблокировать вход владельцу), а в аудите не было реальных IP.
  app.set('trust proxy', 'loopback');
  // меньше информации о стеке наружу
  app.disable('x-powered-by');

  // JSON-парсер ТОЛЬКО для application/json: бинарные чанки загрузок
  // приходят как stream (raw body) и не должны быть съедены парсером.
  app.use(express.json({ type: 'application/json', limit: '1mb' }));
  app.use(cookieParser());

  // SPA (web/dist), если собран рядом с рантаймом — статика + fallback на index.html
  const webDist = join(process.cwd(), 'web', 'dist');
  if (existsSync(webDist)) {
    app.use(express.static(webDist));
    app.use((req: Request, res: Response, next: NextFunction) => {
      // Отдаём index.html только для «страничных» запросов. Иначе на любой мусорный путь
      // (/.env, /wp-login.php) отвечали 200 с HTML — в логах это выглядело как успешный
      // доступ сканера к файлу, а приложение зря рендерило страницу.
      const last = req.path.split('/').pop() ?? '';
      const looksLikeAsset = last.includes('.');
      if (req.method === 'GET' && !req.path.startsWith('/api/') && !looksLikeAsset && req.accepts('html')) {
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
