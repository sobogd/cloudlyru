import { lookup } from 'dns/promises';

/**
 * Скачивание чужого ресурса по адресу из письма — с защитой от SSRF.
 *
 * Один модуль на всех, кому нужно сходить наружу по данным отправителя: логотип домена
 * (`mail-favicon.service.ts`) и картинки писем (`mail-image.service.ts`). Логика тут охранная,
 * и вторая её копия неизбежно разошлась бы с первой — ровно там, где расхождение означает дыру.
 *
 * Правила, из которых состоит защита:
 *   * только http/https (никаких `file:`, `gopher:`, `data:`);
 *   * хост резолвится, и ВСЕ полученные адреса обязаны быть публичными: ни localhost, ни
 *     приватных сетей, ни link-local и метаданных облака (169.254.169.254), ни служебных IPv6
 *     (6to4/NAT64/Teredo заворачивают внутрь себя localhost);
 *   * редиректы идём вручную: автоматический follow прошёл бы на внутренний адрес без повторной
 *     проверки — это ровно тот SSRF, который тут закрыт;
 *   * таймаут живёт до конца чтения тела, а не до получения заголовков: иначе зависший ответ
 *     держал бы соединение и память сколько угодно;
 *   * тело читается потоком с подсчётом байт: `Content-Length` у чужого ответа может
 *     отсутствовать (chunked), и потолок из заголовка тогда не ограничивал бы ничего;
 *   * отдаём только растровые картинки, определённые ПО ПЕРВЫМ БАЙТАМ, а не по чужому
 *     `Content-Type`: ответ уходит браузеру с нашего origin, и документ (SVG, HTML) по этому
 *     адресу исполнил бы свои скрипты в контексте нашего домена.
 *
 * Остаточный риск, принятый осознанно: DNS-rebinding (резолв меняется между проверкой
 * и фетчем) не закрыт — пиннинг адреса в сокет требует своего HTTP-агента с подменённым
 * `lookup`, а это уже отдельная задача.
 */

/** Сколько редиректов проходим, прежде чем считать адрес недобросовестным. */
const DEFAULT_MAX_REDIRECTS = 3;

/** Типы, которые браузер отрисует как картинку и в которых нечего исполнять. */
export const RASTER_MIME = /^image\/(png|jpe?g|gif|webp|bmp|x-icon|vnd\.microsoft\.icon|avif)$/;

export interface PublicBytes {
  bytes: Buffer;
  /** Тип по первым байтам (см. `sniffRasterMime`), а не по заголовку чужого сервера. */
  mime: string;
  /** Адрес, с которого реально пришли байты: после редиректов он другой. */
  finalUrl: string;
}

export interface PublicFetchOptions {
  /** Потолок тела: превышение — отказ, а не обрезанная картинка. */
  maxBytes: number;
  /** Таймаут на попытку (каждый редирект — своя попытка). */
  timeoutMs: number;
  /** Кем представляемся: у части CDN без внятного UA ответа нет. */
  userAgent: string;
  accept?: string;
  maxRedirects?: number;
  /**
   * Короткая причина отказа — для лога вызывающего. Модуль сам не логирует: у логотипов
   * и картинок письма свои формулировки, а «тихо вернуть null» нужно обоим.
   */
  onProblem?: (reason: string) => void;
}

/**
 * Скачать адрес с проверкой хоста. Возвращает байты и определённый тип либо `null` —
 * наружу исключения не уходят: у вызывающих «не получилось» это нормальный ход событий.
 */
export async function fetchPublicBytes(rawUrl: string, opts: PublicFetchOptions): Promise<PublicBytes | null> {
  const maxRedirects = opts.maxRedirects ?? DEFAULT_MAX_REDIRECTS;
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    opts.onProblem?.('адрес не разобран');
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    opts.onProblem?.(`схема ${url.protocol}`);
    return null;
  }
  if (!(await isPublicHost(url.hostname))) {
    opts.onProblem?.('хост не публичный');
    return null;
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs);
  try {
    const res = await fetch(url.toString(), {
      signal: ctrl.signal,
      redirect: 'manual',
      headers: { 'user-agent': opts.userAgent, accept: opts.accept ?? 'image/*,*/*;q=0.8' },
    });

    if (res.status >= 300 && res.status < 400) {
      await discardResponse(res);
      const loc = res.headers.get('location');
      if (!loc) {
        opts.onProblem?.('редирект без Location');
        return null;
      }
      if (maxRedirects <= 0) {
        opts.onProblem?.('слишком много редиректов');
        return null;
      }
      // Относительный Location решается от текущего адреса, и следующий хост проверяется заново.
      return fetchPublicBytes(new URL(loc, url).toString(), { ...opts, maxRedirects: maxRedirects - 1 });
    }
    if (!res.ok) {
      await discardResponse(res);
      opts.onProblem?.(`ответ ${res.status}`);
      return null;
    }

    const declared = Number(res.headers.get('content-length') ?? '0');
    if (declared > opts.maxBytes) {
      await discardResponse(res);
      opts.onProblem?.('больше потолка по Content-Length');
      return null;
    }

    const mime = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    // Пустой/octet-stream на .ico — обычное дело; всё остальное, кроме растровых типов,
    // отбрасываем сразу (в том числе image/svg+xml: SVG — это документ со скриптами).
    if (mime && mime !== 'application/octet-stream' && !RASTER_MIME.test(mime)) {
      await discardResponse(res);
      opts.onProblem?.(`тип ${mime}`);
      return null;
    }

    const buf = await readCapped(res, opts.maxBytes);
    if (!buf?.length) {
      opts.onProblem?.('тело пустое или больше потолка');
      return null;
    }
    const sniffed = sniffRasterMime(buf);
    if (!sniffed) {
      opts.onProblem?.('ответ не похож на растровую картинку');
      return null;
    }
    return { bytes: buf, mime: sniffed, finalUrl: url.toString() };
  } catch (e) {
    // Обрыв, таймаут, ошибка резолва — для вызывающих это «нет ответа», а не сбой сервиса.
    opts.onProblem?.(e instanceof Error && e.name === 'AbortError' ? 'таймаут' : errorText(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Прочитать тело не длиннее `cap` байт. Превышение — это отказ (null), а не обрезанная
 * картинка: половинка иконки никому не нужна, а память дороже.
 */
export async function readCapped(res: Response, cap: number): Promise<Buffer | null> {
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

/** Отбросить тело ответа, который нам больше не нужен: соединение не должно висеть. */
export async function discardResponse(res: Response): Promise<void> {
  await res.body?.cancel().catch(() => undefined);
}

/** Текст ошибки для лога, когда брошено не Error. */
export function errorText(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, 120);
}

/** Резолвим домен и требуем, чтобы ВСЕ адреса были публичными. */
export async function isPublicHost(host: string): Promise<boolean> {
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
 * Нужно потому, что такая картинка отдаётся с нашего origin: если по этому адресу окажется SVG
 * или HTML, браузер отрисует его как документ и исполнит скрипт с нашей сессионной кукой. Биты
 * известного растрового формата такой возможности не дают. SVG здесь сознательно не поддержан
 * (это документ со скриптами) — домен останется без логотипа, письмо — без такой картинки.
 */
export function sniffRasterMime(bytes: Buffer): string | null {
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
