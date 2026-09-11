import { Injectable, Logger } from '@nestjs/common';
import { S3Service } from '../s3/s3.service';
import { env } from '../config/env';

/**
 * Релизный артефакт Android-клиента. Лежит отдельно от личных файлов владельца
 * (не в дереве папок облака): это не файл библиотеки, а сборка приложения, и ссылка
 * на неё должна быть постоянной — /apk.
 */
export const APK_KEY = 'release/android/cloudlyru-sync.apk';
export const APK_META_KEY = 'release/android/latest.json';
export const APK_NAME = 'cloudlyru-sync.apk';
export const APK_MIME = 'application/vnd.android.package-archive';

/** Сведения о сборке читаются из S3 на каждый запрос, но не чаще раза в минуту. */
const META_TTL_MS = 60_000;

export interface AndroidRelease {
  applicationId: string;
  /** versionCode из сборки: по нему приложение понимает, что вышла новая версия. */
  versionCode: number;
  versionName: string;
  size: number;
  sha256: string;
  minSdk: number;
  builtAt: string;
  /** Постоянная публичная ссылка на APK (её открывает и браузер, и само приложение). */
  url: string;
}

/**
 * Последняя опубликованная сборка APK: байты в S3, описание — рядом в latest.json
 * (его пишет `scripts/publish-apk.mjs`). Сборки нет — методов отвечает null,
 * ручки превращают это в честный 404, а не в пустой файл.
 */
@Injectable()
export class ReleaseService {
  private readonly logger = new Logger(ReleaseService.name);
  private cache: { at: number; value: AndroidRelease | null } | null = null;

  constructor(private readonly s3: S3Service) {}

  /** Постоянная публичная ссылка на последнюю сборку. */
  get publicUrl(): string {
    return `${env.BASE_URL.replace(/\/+$/, '')}/apk`;
  }

  async latest(): Promise<AndroidRelease | null> {
    const now = Date.now();
    if (this.cache && now - this.cache.at < META_TTL_MS) return this.cache.value;

    let value: AndroidRelease | null = null;
    try {
      value = await this.readMeta();
      // APK без описания (публикация скриптом старой версии) — файл отдать можно,
      // но версии в нём нет: приложение такую сборку обновлением не считает.
      if (!value && (await this.s3.headObject(APK_KEY))) {
        value = {
          applicationId: '',
          versionCode: 0,
          versionName: '',
          size: 0,
          sha256: '',
          minSdk: 0,
          builtAt: '',
          url: this.publicUrl,
        };
      }
    } catch (e) {
      // S3 недоступен — не кэшируем пустоту на минуту, пусть следующая попытка будет сразу
      this.logger.warn(`не удалось прочитать сведения о сборке: ${(e as Error).message}`);
      return null;
    }
    this.cache = { at: now, value };
    return value;
  }

  private async readMeta(): Promise<AndroidRelease | null> {
    if (!(await this.s3.headObject(APK_META_KEY))) return null;
    const raw = (await this.s3.getObjectBytes(APK_META_KEY, 64 * 1024)).toString('utf8');
    const parsed = JSON.parse(raw) as Partial<AndroidRelease>;
    if (typeof parsed.versionCode !== 'number' || !parsed.sha256) {
      this.logger.warn('latest.json без versionCode/sha256 — считаю сборку неопознанной');
      return null;
    }
    return {
      applicationId: String(parsed.applicationId ?? ''),
      versionCode: parsed.versionCode,
      versionName: String(parsed.versionName ?? ''),
      size: Number(parsed.size ?? 0),
      sha256: String(parsed.sha256),
      minSdk: Number(parsed.minSdk ?? 0),
      builtAt: String(parsed.builtAt ?? ''),
      url: this.publicUrl,
    };
  }
}
