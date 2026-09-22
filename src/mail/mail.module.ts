import { Module } from '@nestjs/common';
import { PrismaModule } from '../prisma/prisma.module';
import { AuthModule } from '../auth/auth.module';
import { FilesModule } from '../files/files.module';
import { S3Module } from '../s3/s3.module';
import { MailController } from './mail.controller';
import { MailAccountsService } from './mail-accounts.service';
import { MailFeedService } from './mail-feed.service';
import { MailFaviconService } from './mail-favicon.service';
import { MailImageService } from './mail-image.service';
import { MailIngestService } from './mail-ingest.service';
import { MailIndexService } from './mail-index.service';
import { MailPurgeService } from './mail-purge.service';
import { MailSearchService } from './mail-search.service';
import { MailSendService } from './mail-send.service';
import { MailTranslateService } from './mail-translate.service';
import { LlmModule } from '../llm/llm.module';
import { MailSyncService } from './mail-sync.service';

/**
 * Раздел «Почта»: аккаунты, синхронизация по IMAP и чтение ленты.
 *
 * FilesModule нужен, чтобы вложения становились обычными записями дерева (с дедупом по
 * sha256): тогда превью, скачивание и деталка файла работают для них без отдельного кода.
 *
 * LlmModule — ради перевода писем: модель на маке живёт отдельным модулем, потому что она
 * общий ресурс, а не часть почты (см. `src/llm`).
 */
@Module({
  imports: [PrismaModule, S3Module, AuthModule, FilesModule, LlmModule],
  controllers: [MailController],
  providers: [
    MailAccountsService,
    MailFeedService,
    MailIngestService,
    MailSyncService,
    MailSendService,
    MailPurgeService,
    MailFaviconService,
    MailImageService,
    MailSearchService,
    MailIndexService,
    MailTranslateService,
  ],
  exports: [MailAccountsService, MailFeedService, MailSyncService, MailSendService, MailPurgeService, MailSearchService],
})
export class MailModule {}
