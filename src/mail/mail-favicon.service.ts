import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import {
  discardResponse,
  errorText,
  fetchPublicBytes,
  isPublicHost,
  RASTER_MIME,
  readCapped,
  sniffRasterMime,
} from './public-fetch';

/**
 * Логотип отправителя: favicon домена из адреса письма.
 *
 * Тянет его СЕРВЕР, а не браузер: клиент наружу не ходит, поэтому логотипы не становятся
 * трекингом (в отличие от прямого `<img src="google.com/s2/favicons">`). Результат кэшируется
 * в БД по домену; домен без favicon не переспрашивается сутки.
 *
 * Домен берётся из fromAddr письма, а это данные отправителя — то есть недоверенные. Поэтому
 * фетч обёрнут SSRF-защитой: только http/https, только публичный IP после резолва (без
 * localhost/приватных/link-local/metadata и без служебных IPv6, включая 6to4/NAT64/Teredo),
 * ручные редиректы с повторной проверкой хоста, таймаут на каждую попытку и настоящий потолок
 * размера: тело читается потоком, и при превышении лимита запрос обрывается, а не буферизуется
 * целиком. Отдаём только растровые картинки — по первым байтам, а не по чужому Content-Type:
 * ответ с нашим origin обязан быть картинкой при любом поведении браузера.
 *
 * Остаточные риски, принятые осознанно:
 *   * DNS-rebinding (резолв меняется между проверкой и фетчем) не закрыт — пиннинг адреса
 *     в сокет требует своего HTTP-агента с подменённым `lookup`;
 *   * ответ домена может ждать до нескольких секунд (4 с на попытку × 3 редиректа + отдельный
 *     запрос главной страницы), поэтому одновременных фетчей не больше MAX_CONCURRENT_FETCH —
 *     иначе один клиент займёт все воркеры медленными внешними запросами.
 */

const MAX_FAVICON_BYTES = 256 * 1024;
/** Потолок для HTML главной страницы: из него нужны только ссылки на иконку. */
const MAX_HTML_BYTES = 512 * 1024;
const FETCH_TIMEOUT_MS = 4000;
/** Вторая страница (главная) — не то, ради чего стоит ждать: свой, более короткий таймаут. */
const FETCH_HTML_TIMEOUT_MS = 2500;
/** Сколько не переспрашивать домен, у которого favicon не нашёлся. */
const RETRY_AFTER_MS = 24 * 60 * 60 * 1000;
const MAX_REDIRECTS = 3;
/** Сколько фетчей одновременно — глобально, на процесс. */
const MAX_CONCURRENT_FETCH = 4;
/** Через сколько вычищать записи кэша, к которым давно не обращались. */
const CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const CLEANUP_INTERVAL_MS = 60 * 60 * 1000;
const UA = 'CloudlyRu/0.1 (+favicon)';

interface Favicon {
  bytes: Buffer;
  mime: string;
}

@Injectable()
export class MailFaviconService {
  private readonly logger = new Logger(MailFaviconService.name);
  /** Сколько фетчей идёт прямо сейчас и кто ждёт слот (см. MAX_CONCURRENT_FETCH). */
  private active = 0;
  private readonly waiting: Array<() => void> = [];
  private lastCleanup = 0;

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Favicon домена: байты и mime, либо null, если его нет (или не картинка).
   *
   * `userId` — владелец запроса. Если он передан, домен обязан встречаться в письмах этого
   * пользователя: иначе аутентифицированный клиент мог бы наполнить БД произвольными доменами
   * и заставить сервер сходить наружу по своему списку. Контроллер пока передаёт только домен,
   * то есть проверка не работает, — её включение требует правки `mail.controller.ts`.
   */
  async get(domainRaw: string, userId?: string): Promise<Favicon | null> {
    const domain = normalizeDomain(domainRaw);
    if (!domain) return null;

    const cached = await this.prisma.senderFavicon.findUnique({ where: { domain } });
    if (cached) {
      if (cached.bytes) {
        // Тип берём по байтам, а не из записи: в кэше могла остаться запись от версии,
        // которая сохраняла чужой Content-Type (в том числе image/svg+xml).
        const sniffed = sniffRasterMime(cached.bytes);
        if (sniffed) return { bytes: cached.bytes, mime: sniffed };
        // Не картинка — не отдаём и идём спрашивать заново: запись ниже перезапишется
        // корректным результатом, а старый "svg-favicon" из кэша перестанет быть отравой.
        this.logger.warn(`favicon ${domain}: в кэше не картинка — перезапрашиваю`);
      } else if (Date.now() - cached.triedAt.getTime() < RETRY_AFTER_MS) {
        return null;
      }
    }

    if (userId && !(await this.occursInUserMail(userId, domain))) {
      this.logger.warn(`favicon ${domain}: домена нет в письмах пользователя — не тяну`);
      return null;
    }

    await this.acquire();
    let fetched: Favicon | null;
    try {
      fetched = await this.fetch(domain);
    } finally {
      this.release();
    }
    await this.prisma.senderFavicon.upsert({
      where: { domain },
      create: { domain, bytes: fetched?.bytes ?? null, mime: fetched?.mime ?? null },
      update: { bytes: fetched?.bytes ?? null, mime: fetched?.mime ?? null, triedAt: new Date() },
    });
    void this.cleanupCache();
    return fetched;
  }

  /** Домен встречается в письмах пользователя (проверка идёт только на кэш-промахе). */
  private async occursInUserMail(userId: string, domain: string): Promise<boolean> {
    try {
      const found = await this.prisma.mailMessage.findFirst({
        where: { userId, fromAddr: { endsWith: `@${domain}`, mode: 'insensitive' } },
        select: { id: true },
      });
      return Boolean(found);
    } catch (e) {
      // Не смогли проверить — считаем, что домена нет: наружу по непроверенному запросу не идём.
      this.logger.warn(`favicon ${domain}: проверка по письмам не удалась — ${errorText(e)}`);
      return false;
    }
  }

  /** Слот на фетч: не больше MAX_CONCURRENT_FETCH одновременно. Освобождать обязательно. */
  private async acquire(): Promise<void> {
    if (this.active < MAX_CONCURRENT_FETCH) {
      this.active += 1;
      return;
    }
    await new Promise<void>((resolve) => this.waiting.push(resolve));
  }

  private release(): void {
    const next = this.waiting.shift();
    // Слот переходит ожидающему: счётчик не трогаем, иначе между release и пробуждением
    // кто-то успел бы занять его дважды.
    if (next) next();
    else this.active = Math.max(0, this.active - 1);
  }

  /** Записи, к которым давно не обращались, копятся зря: чистим раз в час, без ожидания. */
  private async cleanupCache(): Promise<void> {
    if (Date.now() - this.lastCleanup < CLEANUP_INTERVAL_MS) return;
    this.lastCleanup = Date.now();
    try {
      await this.prisma.senderFavicon.deleteMany({
        where: { triedAt: { lt: new Date(Date.now() - CACHE_TTL_MS) } },
      });
    } catch (e) {
      this.logger.warn(`favicon: чистка кэша не удалась — ${errorText(e)}`);
    }
  }

  private async fetch(domain: string): Promise<Favicon | null> {
    // Классическое /favicon.ico, потом — <link rel="icon"> из главной страницы.
    const direct = await this.fetchUrl(`https://${domain}/favicon.ico`);
    if (direct) return direct;
    const iconHref = await this.findIconLink(domain);
    return iconHref ? this.fetchUrl(iconHref) : null;
  }

  /**
   * Скачать URL логотипа. Вся защита (схемы, публичность хоста, ручные редиректы, потолок
   * размера, определение типа по байтам) живёт в `fetchPublicBytes` — тут только свои
   * потолки и свои формулировки в логе.
   */
  private async fetchUrl(urlStr: string): Promise<Favicon | null> {
    const got = await fetchPublicBytes(urlStr, {
      maxBytes: MAX_FAVICON_BYTES,
      timeoutMs: FETCH_TIMEOUT_MS,
      maxRedirects: MAX_REDIRECTS,
      userAgent: UA,
      accept: 'image/*,*/*;q=0.8',
      onProblem: (reason) => this.logger.warn(`favicon ${hostOf(urlStr)}: ${reason}`),
    });
    return got ? { bytes: got.bytes, mime: got.mime } : null;
  }

  /** <link rel="icon|shortcut icon"> из HTML главной страницы. */
  private async findIconLink(domain: string): Promise<string | null> {
    if (!(await isPublicHost(domain))) return null;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), FETCH_HTML_TIMEOUT_MS);
    try {
      const res = await fetch(`https://${domain}/`, { signal: ctrl.signal, redirect: 'manual', headers: { 'user-agent': UA } });
      if (!res.ok || !/text\/html/i.test(res.headers.get('content-type') ?? '')) {
        await discardResponse(res);
        return null;
      }
      const declared = Number(res.headers.get('content-length') ?? '0');
      if (declared > MAX_HTML_BYTES) {
        await discardResponse(res);
        return null;
      }
      const body = await readCapped(res, MAX_HTML_BYTES);
      if (!body) return null;
      const html = body.toString('utf8');
      const tags = html.match(/<link\b[^>]*>/gi) ?? [];
      for (const tag of tags) {
        if (!/\brel\s*=\s*["'][^"']*icon/i.test(tag)) continue;
        const href = /href\s*=\s*["']([^"']+)["']/i.exec(tag)?.[1];
        if (!href) continue;
        try {
          return new URL(href, `https://${domain}/`).toString();
        } catch {
          return null;
        }
      }
      return null;
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }
}

/** Домен из адреса: только валидное имя хоста, без IP-литералов, localhost и поддоменов. */
function normalizeDomain(raw: string): string | null {
  const s = String(raw ?? '').trim().toLowerCase();
  if (!s) return null;
  // Отсекаем IP-литералы (в т.ч. IPv6 в скобках) и любые пути/порты.
  if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/.test(s)) return null;
  if (s === 'localhost' || s.endsWith('.localhost') || s.endsWith('.local') || s.endsWith('.internal')) return null;
  // Отсекаем поддомены, оставляя только основной домен (последние две части).
  const parts = s.split('.');
  if (parts.length >= 3) {
    return `${parts[parts.length - 2]}.${parts[parts.length - 1]}`;
  }
  return s;
}

/** Хост из адреса для лога: печатать сам адрес нельзя — в нём бывают токены и параметры. */
function hostOf(raw: string): string {
  try {
    return new URL(raw).hostname;
  } catch {
    return 'адрес не разобран';
  }
}
