import { Module, ValidationPipe } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import { PrismaModule } from './prisma/prisma.module';
import { AuthModule } from './auth/auth.module';
import { AuthGuard } from './common/guards/auth.guard';
import { OriginGuard } from './common/guards/origin.guard';
import { RateLimitGuard } from './common/guards/rate-limit.guard';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { RequestLogInterceptor } from './common/interceptors/request-log.interceptor';
import { S3Module } from './s3/s3.module';
import { FoldersModule } from './folders/folders.module';
import { FilesModule } from './files/files.module';
import { UploadsModule } from './uploads/uploads.module';
import { TrashModule } from './trash/trash.module';
import { DavModule } from './dav/dav.module';
import { MediaModule } from './media/media.module';
import { MediaFeedModule } from './media-feed/media-feed.module';
import { QueueModule } from './queue/queue.module';
import { HealthModule } from './health/health.module';
import { UnzipModule } from './unzip/unzip.module';
import { SyncModule } from './sync/sync.module';
import { ReleaseModule } from './release/release.module';
import { ClipboardModule } from './clipboard/clipboard.module';
import { MailModule } from './mail/mail.module';

/**
 * Корневой модуль: собирает функциональные модули и вешает на каждый запрос три глобальные
 * проверки. Порядок APP_GUARD — это порядок исполнения: сначала OriginGuard отсекает
 * межсайтовые небезопасные запросы (Origin/Referer + Sec-Fetch-Site), потом RateLimitGuard
 * считает частоту (дешевле, чем поход в БД), и только затем AuthGuard идёт в БД за сессией или
 * device-токеном. Порядок важен: он решает, какая ошибка уйдёт клиенту первой (429/403 вместо
 * 401) и не будет ли лишнего запроса к БД на чужой Origin или на флуд. `@Public()` снимает
 * только AuthGuard — Origin и частота работают и на публичных ручках.
 *
 * Здесь же висят общесервисные вещи, без которых у остальных модулей нет единого поведения:
 *  - AllExceptionsFilter — единственное место, где любое исключение превращается в формат
 *    `{statusCode, message, code}` (его разбирает клиент) и логируется с id запроса;
 *  - ValidationPipe — зарегистрирован заранее: тел с DTO пока нет (контроллеры разбирают тело
 *    руками, чтобы лишние поля не проходили молча), но как только DTO появятся, валидация
 *    включится сама, а не станет отдельной задачей «не забыть добавить пайп»;
 *  - RequestLogInterceptor — id запроса в заголовке ответа и лог запросов (подробности — в нём).
 */
@Module({
  imports: [
    PrismaModule,
    S3Module,
    AuthModule,
    FoldersModule,
    FilesModule,
    UploadsModule,
    TrashModule,
    DavModule,
    MediaModule,
    MediaFeedModule,
    QueueModule,
    HealthModule,
    UnzipModule,
    SyncModule,
    ReleaseModule,
    ClipboardModule,
    MailModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: OriginGuard },
    { provide: APP_GUARD, useClass: RateLimitGuard },
    { provide: APP_GUARD, useClass: AuthGuard },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
    // transform+whitelist — на будущее для DTO; тела без класса-метатипа пайп не трогает,
    // поэтому сейчас поведение ручек не меняется
    { provide: APP_PIPE, useValue: new ValidationPipe({ transform: true, whitelist: true }) },
    { provide: APP_INTERCEPTOR, useClass: RequestLogInterceptor },
  ],
})
export class AppModule {}
