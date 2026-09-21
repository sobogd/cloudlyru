import { Injectable, Logger } from '@nestjs/common';
import { S3Service } from '../s3/s3.service';
import { env } from '../config/env';

/**
 * Куда кладётся сборка платформы и по какому адресу её отдаёт сервер.
 *
 * Релизные артефакты лежат отдельно от личных файлов владельца (не в дереве папок облака):
 * это не файлы библиотеки, а сборки приложения, и ссылки на них должны быть постоянными —
 * `/apk` для Android и `/macos` для настольной сборки.
 */
export interface ReleaseArtifact {
  /** Ключ файла сборки в бакете. */
  key: string;
  /** Ключ описания сборки рядом с файлом — его пишет скрипт публикации. */
  metaKey: string;
  /** Имя, под которым файл отдаётся на скачивание. */
  name: string;
  mime: string;
  /** Постоянный публичный путь без префикса api/v1. */
  path: string;
}

export const RELEASE_ARTIFACTS = {
  android: {
    key: 'release/android/cloudlyru-sync.apk',
    metaKey: 'release/android/latest.json',
    name: 'cloudlyru-sync.apk',
    mime: 'application/vnd.android.package-archive',
    path: 'apk',
  },
  macos: {
    key: 'release/macos/cloudlyru-sync-macos.zip',
    metaKey: 'release/macos/latest.json',
    name: 'Cloudly.zip',
    mime: 'application/zip',
    path: 'macos',
  },
  /**
   * Сборка для iPad и iPhone: Ad Hoc архив `.ipa` (подписан distribution-профилем со списком
   * устройств). Тип отдачи — `application/octet-stream`, а не что-то «айошное»: браузер по нему
   * только скачивает файл, а установку ведёт Safari по манифесту (`/ios/manifest.plist`).
   */
  ios: {
    key: 'release/ios/cloudlyru-sync.ipa',
    metaKey: 'release/ios/latest.json',
    name: 'Cloudly.ipa',
    mime: 'application/octet-stream',
    path: 'ios',
  },
} as const satisfies Record<string, ReleaseArtifact>;

export type ReleasePlatform = keyof typeof RELEASE_ARTIFACTS;

/** Сведения о сборке читаются из S3 на каждый запрос, но не чаще раза в минуту. */
const META_TTL_MS = 60_000;

export interface AppRelease {
  applicationId: string;
  /**
   * Номер сборки: у Android это versionCode, у настольной сборки — CFBundleVersion.
   * По нему приложение понимает, что вышла новая версия.
   */
  versionCode: number;
  versionName: string;
  size: number;
  sha256: string;
  /** Минимальная версия системы, заявленная сборкой; у настольной сборки не заполняется. */
  minSdk: number;
  /** Пустая строка — «в описании сборки даты нет»; null тут не бывает, поэтому проверять `!= null` бессмысленно. */
  builtAt: string;
  /** Постоянная публичная ссылка на сборку (её открывает и браузер, и само приложение). */
  url: string;
  /**
   * false — сборка найдена в бакете без описания latest.json (её выложил кто-то руками или
   * старый скрипт): файл скачать можно, но versionCode/sha256/versionName неизвестны —
   * записывать их нулями и пустой строкой означало бы отдать приложению заведомо неверную
   * сумму. Ручки обязаны трактовать такое как «сборка не опубликована» (`no_release`),
   * а не как сборку с versionCode 0.
   */
  metaKnown: boolean;
}

/**
 * Последняя опубликованная сборка платформы: байты в S3, описание — рядом в latest.json
 * (его пишут `scripts/publish-apk.mjs` и `scripts/publish-macos.mjs`). Сборки нет — метод
 * отвечает null, ручки превращают это в честный 404, а не в пустой файл.
 */
@Injectable()
export class ReleaseService {
  private readonly logger = new Logger(ReleaseService.name);

  /** Кэш на платформу: у каждой свой срок и своё значение. */
  private readonly cache = new Map<ReleasePlatform, { at: number; value: AppRelease | null }>();

  constructor(private readonly s3: S3Service) {}

  /** Постоянная публичная ссылка на последнюю сборку платформы. */
  publicUrl(platform: ReleasePlatform = 'android'): string {
    const base = env.BASE_URL.replace(/\/+$/, '');
    return `${base}/${RELEASE_ARTIFACTS[platform].path}`;
  }

  async latest(platform: ReleasePlatform = 'android'): Promise<AppRelease | null> {
    const artifact = RELEASE_ARTIFACTS[platform];
    const now = Date.now();
    const cached = this.cache.get(platform);
    if (cached && now - cached.at < META_TTL_MS) return cached.value;

    let value: AppRelease | null = null;
    try {
      value = await this.readMeta(platform);
      // Сборка без описания (публикация скриптом старой версии или руками) — файл отдать можно,
      // но версии в нём нет: приложение такую сборку обновлением не считает.
      // «Сборка есть, latest.json нет» — это осознанная деградация: url ведёт на настоящий
      // файл (скачать руками можно), а versionCode 0 не больше текущего у приложения, поэтому
      // обновление по ней не предложится. Клиент должен читать это как «версия неизвестна»,
      // а не как «вышла новая сборка» — поэтому metaKnown=false вместо правдоподобных нулей.
      if (!value && (await this.s3.headObject(artifact.key))) {
        value = {
          applicationId: '',
          versionCode: 0,
          versionName: '',
          size: 0,
          sha256: '',
          minSdk: 0,
          builtAt: '',
          url: this.publicUrl(platform),
          metaKnown: false,
        };
      }
    } catch (e) {
      // S3 недоступен — не кэшируем пустоту на минуту, пусть следующая попытка будет сразу
      this.logger.warn(`не удалось прочитать сведения о сборке: ${(e as Error).message}`);
      return null;
    }
    this.cache.set(platform, { at: now, value });
    return value;
  }

  private async readMeta(platform: ReleasePlatform): Promise<AppRelease | null> {
    const artifact = RELEASE_ARTIFACTS[platform];
    if (!(await this.s3.headObject(artifact.metaKey))) return null;
    const raw = (await this.s3.getObjectBytes(artifact.metaKey, 64 * 1024)).toString('utf8');
    const parsed = JSON.parse(raw) as Partial<AppRelease>;
    if (typeof parsed.versionCode !== 'number' || !parsed.sha256) {
      this.logger.warn(
        `${artifact.metaKey} без versionCode/sha256 — считаю сборку неопознанной`,
      );
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
      url: this.publicUrl(platform),
      metaKnown: true,
    };
  }
}
