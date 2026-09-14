import { Injectable, Logger } from '@nestjs/common';
import { lookup } from 'dns/promises';
import { PrismaService } from '../prisma/prisma.service';

/**
 * Логотип отправителя: favicon домена из адреса письма.
 *
 * Тянет его СЕРВЕР, а не браузер: клиент наружу не ходит, поэтому логотипы не становятся
 * трекингом (в отличие от прямого `<img src="google.com/s2/favicons">`). Результат кэшируется
 * в БД по домену; домен без favicon не переспрашивается сутки.
 *
 * Домен берётся из fromAddr письма, а это данные отправителя — то есть недоверенные. Поэтому
 * фетч обёрнут SSRF-защитой: только http/https, только публичный IP после резолва (без
 * localhost/приватных/link-local/metadata), ручные редиректы с повторной проверкой хоста,
 * таймаут и потолок размера. DNS-rebinding (резолв меняется между проверкой и фетчем) здесь
 * не закрыт: для одного владельца на своём сервере это приемлемый остаточный риск.
 */

const MAX_FAVICON_BYTES = 256 * 1024;
const FETCH_TIMEOUT_MS = 4000;
/** Сколько не переспрашивать домен, у которого favicon не нашёлся. */
const RETRY_AFTER_MS = 24 * 60 * 60 * 1000;
const MAX_REDIRECTS = 3;
const IMAGE_MIME = /^image\//i;
const UA = 'CloudlyRu/0.1 (+favicon)';

@Injectable()
export class MailFaviconService {
  private readonly logger = new Logger(MailFaviconService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** Favicon домена: байты и mime, либо null, если его нет (или не картинка). */
  async get(domainRaw: string): Promise<{ bytes: Buffer; mime: string } | null> {
    const domain = normalizeDomain(domainRaw);
    if (!domain) return null;

    const cached = await this.prisma.senderFavicon.findUnique({ where: { domain } });
    if (cached) {
      if (cached.bytes) return { bytes: cached.bytes, mime: cached.mime ?? 'image/x-icon' };
      if (Date.now() - cached.triedAt.getTime() < RETRY_AFTER_MS) return null;
    }

    const fetched = await this.fetch(domain);
    await this.prisma.senderFavicon.upsert({
      where: { domain },
      create: { domain, bytes: fetched?.bytes ?? null, mime: fetched?.mime ?? null },
      update: { bytes: fetched?.bytes ?? null, mime: fetched?.mime ?? null, triedAt: new Date() },
    });
    return fetched;
  }

  private async fetch(domain: string): Promise<{ bytes: Buffer; mime: string } | null> {
    // Классическое /favicon.ico, потом — <link rel="icon"> из главной страницы.
    const direct = await this.fetchUrl(`https://${domain}/favicon.ico`);
    if (direct) return direct;
    const iconHref = await this.findIconLink(domain);
    return iconHref ? this.fetchUrl(iconHref) : null;
  }

  /**
   * Скачать URL с проверкой хоста. Редиректы идём вручную: автоматический follow в fetch
   * прошёл бы на внутренний адрес без повторной проверки, а это ровно тот SSRF, который
   * мы тут закрываем.
   */
  private async fetchUrl(urlStr: string, redirects = 0): Promise<{ bytes: Buffer; mime: string } | null> {
    if (redirects > MAX_REDIRECTS) return null;
    let url: URL;
    try {
      url = new URL(urlStr);
    } catch {
      return null;
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    if (!(await isPublicHost(url.hostname))) return null;

    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
      const res = await fetch(url.toString(), {
        signal: ctrl.signal,
        redirect: 'manual',
        headers: { 'user-agent': UA, accept: 'image/*,*/*;q=0.8' },
      });
      clearTimeout(timer);

      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get('location');
        if (!loc) return null;
        // относительный Location решается от текущего URL
        return this.fetchUrl(new URL(loc, url).toString(), redirects + 1);
      }
      if (!res.ok) return null;

      const declared = Number(res.headers.get('content-length') ?? '0');
      if (declared > MAX_FAVICON_BYTES) return null;

      const mime = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      // Пустой/octet-stream на .ico — обычное дело; явно не-картинку отбрасываем.
      if (mime && !IMAGE_MIME.test(mime) && mime !== 'application/octet-stream') return null;

      const buf = Buffer.from(await res.arrayBuffer());
      if (!buf.length || buf.length > MAX_FAVICON_BYTES) return null;
      return { bytes: buf, mime: mime && IMAGE_MIME.test(mime) ? mime : 'image/x-icon' };
    } catch (e) {
      // Обрыв/таймаут/резолв — для favicon это норма, тихо возвращаем «нет».
      if (e instanceof Error && e.name !== 'AbortError') {
        this.logger.warn(`favicon ${url.hostname}: ${e.message.slice(0, 120)}`);
      }
      return null;
    }
  }

  /** <link rel="icon|shortcut icon"> из HTML главной страницы. */
  private async findIconLink(domain: string): Promise<string | null> {
    if (!(await isPublicHost(domain))) return null;
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
      const res = await fetch(`https://${domain}/`, { signal: ctrl.signal, redirect: 'manual', headers: { 'user-agent': UA } });
      clearTimeout(timer);
      if (!res.ok || !/text\/html/i.test(res.headers.get('content-type') ?? '')) return null;
      const html = await res.text();
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
    }
  }
}

/** Домен из адреса: только валидное имя хоста, без IP-литералов и localhost. */
function normalizeDomain(raw: string): string | null {
  const s = String(raw ?? '').trim().toLowerCase();
  if (!s) return null;
  // Отсекаем IP-литералы (в т.ч. IPv6 в скобках) и любые пути/порты.
  if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/.test(s)) return null;
  if (s === 'localhost' || s.endsWith('.localhost') || s.endsWith('.local') || s.endsWith('.internal')) return null;
  return s;
}

/** Резолвим домен и требуем, чтобы ВСЕ адреса были публичными. */
async function isPublicHost(host: string): Promise<boolean> {
  try {
    const addrs = await lookup(host, { all: true, verbatim: true });
    if (!addrs.length) return false;
    return addrs.every((a) => isPublicIp(a.address));
  } catch {
    return false;
  }
}

/** Публичный ли IP (IPv4 и IPv6): приватные, link-local, metadata и служебные — нет. */
function isPublicIp(ip: string): boolean {
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a > 255 || b > 255) return false;
    if (a === 0 || a === 10 || a === 127) return false;
    if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT 100.64/10
    if (a === 169 && b === 254) return false; // link-local + 169.254.169.254
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 192 && (b === 0 || b === 2)) return false; // 192.0.0/24, TEST-NET 192.0.2/24
    if (a === 198 && (b === 18 || b === 19 || b === 51)) return false; // 198.18/15, 198.51.100/24
    if (a === 203 && b === 0) return false; // 203.0.113/24
    return a < 224; // multicast 224/4 и reserved 240/4 — нет
  }
  const lower = ip.toLowerCase();
  if (lower === '::' || lower === '::1') return false;
  if (lower.startsWith('ff')) return false; // multicast
  if (lower.startsWith('fc') || lower.startsWith('fd')) return false; // ULA fc00::/7
  if (lower.startsWith('fe8') || lower.startsWith('fe9') || lower.startsWith('fea') || lower.startsWith('feb')) return false; // link-local fe80::/10
  if (lower.startsWith('::ffff:')) return isPublicIp(ip.slice(7)); // IPv4-mapped
  return true;
}
