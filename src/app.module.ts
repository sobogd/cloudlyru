import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { PrismaModule } from './prisma/prisma.module';
import { AuthModule } from './auth/auth.module';
import { AuthGuard } from './common/guards/auth.guard';
import { OriginGuard } from './common/guards/origin.guard';
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
    { provide: APP_GUARD, useClass: AuthGuard },
  ],
})
export class AppModule {}
