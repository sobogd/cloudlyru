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
/** Типы, которые браузер отрисует как картинку и в которых нечего исполнять. */
const RASTER_MIME = /^image\/(png|jpe?g|gif|webp|bmp|x-icon|vnd\.microsoft\.icon|avif)$/;
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
   * Скачать URL с проверкой хоста. Редиректы идём вручную: автоматический follow в fetch
   * прошёл бы на внутренний адрес без повторной проверки, а это ровно тот SSRF, который
   * мы тут закрываем.
   *
   * Тело читается потоком с подсчётом байт: Content-Length у чужого ответа может отсутствовать
   * (chunked), и тогда «потолок» из заголовка не ограничивал бы ничего — в память процесса API
   * уехали бы сотни мегабайт. При превышении лимита чтение обрывается.
   */
  private async fetchUrl(urlStr: string, redirects = 0): Promise<Favicon | null> {
    if (redirects > MAX_REDIRECTS) return null;
    let url: URL;
    try {
      url = new URL(urlStr);
    } catch {
      return null;
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    if (!(await isPublicHost(url.hostname))) return null;

    // Таймер живёт до конца чтения тела, а не до получения заголовков: без этого зависший
    // ответ держал бы слот семафора сколько угодно.
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
    try {
      const res = await fetch(url.toString(), {
        signal: ctrl.signal,
        redirect: 'manual',
        headers: { 'user-agent': UA, accept: 'image/*,*/*;q=0.8' },
      });

      if (res.status >= 300 && res.status < 400) {
        await discard(res);
        const loc = res.headers.get('location');
        if (!loc) return null;
        // относительный Location решается от текущего URL
        return await this.fetchUrl(new URL(loc, url).toString(), redirects + 1);
      }
      if (!res.ok) {
        await discard(res);
        return null;
      }

      const declared = Number(res.headers.get('content-length') ?? '0');
      if (declared > MAX_FAVICON_BYTES) {
        await discard(res);
        return null;
      }

      const mime = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      // Пустой/octet-stream на .ico — обычное дело; всё остальное, кроме растровых типов,
      // отбрасываем сразу (в том числе image/svg+xml: SVG — это документ со скриптами).
      if (mime && mime !== 'application/octet-stream' && !RASTER_MIME.test(mime)) {
        await discard(res);
        return null;
      }

      const buf = await this.readCapped(res, MAX_FAVICON_BYTES);
      if (!buf?.length) return null;
      const sniffed = sniffRasterMime(buf);
      if (!sniffed) {
        this.logger.warn(`favicon ${url.hostname}: ответ не похож на растровую картинку — не сохраняю`);
        return null;
      }
      return { bytes: buf, mime: sniffed };
    } catch (e) {
      // Обрыв/таймаут/резолв — для favicon это норма, тихо возвращаем «нет».
      if (e instanceof Error && e.name !== 'AbortError') {
        this.logger.warn(`favicon ${url.hostname}: ${e.message.slice(0, 120)}`);
      }
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Прочитать тело не длиннее `cap` байт. Превышение — это отказ (null), а не обрезанная
   * картинка: половинка иконки никому не нужна, а память дороже.
   */
  private async readCapped(res: Response, cap: number): Promise<Buffer | null> {
    const body = res.body;
    if (!body) return null;
    const reader = body.getReader();
    const chunks: Buffer[] = [];
    let total = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!value) continue;
        const chunk = Buffer.from(value);
        total += chunk.length;
        if (total > cap) {
          await reader.cancel().catch(() => undefined);
          return null;
        }
        chunks.push(chunk);
      }
    } finally {
      reader.releaseLock();
    }
    return Buffer.concat(chunks);
  }

  /** <link rel="icon|shortcut icon"> из HTML главной страницы. */
  private async findIconLink(domain: string): Promise<string | null> {
    if (!(await isPublicHost(domain))) return null;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), FETCH_HTML_TIMEOUT_MS);
    try {
      const res = await fetch(`https://${domain}/`, { signal: ctrl.signal, redirect: 'manual', headers: { 'user-agent': UA } });
      if (!res.ok || !/text\/html/i.test(res.headers.get('content-type') ?? '')) {
        await discard(res);
        return null;
      }
      const declared = Number(res.headers.get('content-length') ?? '0');
      if (declared > MAX_HTML_BYTES) {
        await discard(res);
        return null;
      }
      const body = await this.readCapped(res, MAX_HTML_BYTES);
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

/** Отбросить тело ответа, который нам больше не нужен: соединение не должно висеть. */
async function discard(res: Response): Promise<void> {
  await res.body?.cancel().catch(() => undefined);
}

/** Текст ошибки для лога, когда брошено не Error. */
function errorText(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, 120);
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

/**
 * Публичный ли IP (IPv4 и IPv6): приватные, link-local, metadata и служебные — нет.
 *
 * Для IPv6 разбираем адрес в восемь групп и пропускаем только глобальный unicast 2000::/3,
 * из которого выкинуты служебные диапазоны. Перечислять «плохие» префиксы по строке нельзя:
 * 64:ff9b::/96 (NAT64), 2002::/16 (6to4) и 2001::/32 (Teredo) заворачивают внутрь себя
 * localhost и 169.254.169.254, а 2001:db8::/32 — это документация.
 */
function isPublicIp(ip: string): boolean {
  const v4 = parseIpv4(ip);
  if (v4) return isPublicIpv4(v4);

  const words = parseIpv6Words(ip);
  if (!words) return false;
  // IPv4-mapped (::ffff:1.2.3.4): проверяем вложенный адрес по IPv4-правилам.
  if (words[0] === 0 && words[1] === 0 && words[2] === 0 && words[3] === 0 && words[4] === 0 && words[5] === 0xffff) {
    return isPublicIpv4([words[6] >> 8, words[6] & 0xff, words[7] >> 8, words[7] & 0xff]);
  }
  // Глобальный unicast: первые три бита адреса — 001.
  if ((words[0] & 0xe000) !== 0x2000) return false;
  if (words[0] === 0x2001 && words[1] === 0x0db8) return false; // 2001:db8::/32 — документация
  if (words[0] === 0x2001 && words[1] === 0x0000) return false; // 2001::/32 — Teredo
  if (words[0] === 0x2001 && words[1] === 0x0002) return false; // 2001:2::/48 — бенчмарки
  if (words[0] === 0x2001 && (words[1] & 0xfff0) === 0x0010) return false; // 2001:10::/28 — ORCHID
  if (words[0] === 0x2001 && (words[1] & 0xfff0) === 0x0020) return false; // 2001:20::/28 — ORCHIDv2
  if (words[0] === 0x2002) return false; // 2002::/16 — 6to4
  if (words[0] === 0x3fff && (words[1] & 0xf000) === 0) return false; // 3fff::/20 — документация
  return true;
}

function parseIpv4(raw: string): [number, number, number, number] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(raw ?? '').trim());
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  if (parts.some((n) => n > 255)) return null;
  return [parts[0], parts[1], parts[2], parts[3]];
}

/** IPv4-диапазоны, которые наружу выпускать нельзя. */
function isPublicIpv4(v4: [number, number, number, number]): boolean {
  const [a, b] = v4;
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

/** Развернуть IPv6 в восемь 16-битных групп; null — это не IPv6. */
function parseIpv6Words(raw: string): number[] | null {
  let ip = String(raw ?? '').trim().toLowerCase();
  const zone = ip.indexOf('%'); // зона интерфейса (fe80::1%eth0) к адресу не относится
  if (zone !== -1) ip = ip.slice(0, zone);
  if (!ip.includes(':')) return null;

  // Хвост вида «1.2.3.4» (IPv4-совместимая запись) превращаем в две группы.
  const lastColon = ip.lastIndexOf(':');
  const tail = ip.slice(lastColon + 1);
  if (tail.includes('.')) {
    const v4 = parseIpv4(tail);
    if (!v4) return null;
    const hi = ((v4[0] << 8) | v4[1]).toString(16);
    const lo = ((v4[2] << 8) | v4[3]).toString(16);
    ip = `${ip.slice(0, lastColon + 1)}${hi}:${lo}`;
  }

  const halves = ip.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const groups = [...head, ...rest];
  if (groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  if (halves.length === 1) return groups.length === 8 ? groups.map((g) => parseInt(g, 16)) : null;
  const missing = 8 - groups.length;
  if (missing < 1) return null; // «::» обязан что-то сокращать
  return [
    ...head.map((g) => parseInt(g, 16)),
    ...new Array<number>(missing).fill(0),
    ...rest.map((g) => parseInt(g, 16)),
  ];
}

/**
 * Растровая ли это картинка — по первым байтам, а не по заголовку от чужого сервера.
 *
 * Нужно потому, что favicon отдаётся с нашего origin: если по этому адресу окажется SVG или
 * HTML, браузер отрисует его как документ и исполнит скрипт с нашей сессионной кукой. Биты
 * известного растрового формата такой возможности не дают. SVG здесь сознательно не поддержан
 * (это документ со скриптами) — домен просто останется без логотипа.
 */
function sniffRasterMime(bytes: Buffer): string | null {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 6) {
    const head = bytes.subarray(0, 6).toString('latin1');
    if (head === 'GIF87a' || head === 'GIF89a') return 'image/gif';
  }
  if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) return 'image/bmp';
  if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0x01 && bytes[3] === 0x00) {
    return 'image/x-icon';
  }
  if (bytes.length >= 12) {
    if (bytes.subarray(0, 4).toString('latin1') === 'RIFF' && bytes.subarray(8, 12).toString('latin1') === 'WEBP') {
      return 'image/webp';
    }
    const brand = bytes.subarray(8, 12).toString('latin1');
    if (bytes.subarray(4, 8).toString('latin1') === 'ftyp' && (brand === 'avif' || brand === 'avis')) return 'image/avif';
  }
  return null;
}
