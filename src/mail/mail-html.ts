/**
 * Подготовка тела письма к показу в нашем интерфейсе.
 *
 * Это ЕДИНСТВЕННАЯ защита от разметки письма, и держать это в голове обязательно: веб-клиента
 * с телом письма в iframe с `sandbox` больше нет, а единственный рендерер — Flutter-WebView,
 * в котором JavaScript включён (им меряется высота письма). Всё, что проскочит эту чистку,
 * исполняется в WebView приложения. Поэтому правила тут такие:
 *
 * 1. Белые списки, а не «вырезать известное плохое»: теги и атрибуты перечислены явно, всё
 *    остальное (в том числе `<svg>`, `<video poster>`, экзотические загрузчики вроде
 *    `lowsrc`/`dynsrc`/`formaction`) не попадает в результат.
 * 2. Адреса разбираются нормализованными (`new URL(...)`), а не по префиксу строки: `http:evil/x`
 *    и `https:/evil/x` — это те же абсолютные адреса, что и `https://evil/x`.
 * 3. CSS чистится после раскодирования HTML-сущностей и CSS-экранирования: иначе
 *    `url(&quot;https://…&quot;)` в `style` и `\75 rl(https://…)` проходят мимо проверок.
 * 4. Внешние картинки по умолчанию не грузим: это трекинг-пиксели — по запросу за картинкой
 *    отправитель узнаёт, что письмо открыли, когда и с какого адреса. Показываем их только
 *    после «показать картинки» (`allowRemote`).
 *
 * Вложения по cid сюда не попадают: разборщик уже заменил их на data:-ссылки, поэтому тело
 * письма самодостаточно. Растровые data:-картинки при этом остаются — они никуда не ходят.
 */

/** Теги, которых в письме быть не должно: исполняемое, внешние встраивания, формы, вектор. */
const DROP_TAGS = [
  'script',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'form',
  'input',
  'textarea',
  'select',
  'option',
  'button',
  'base',
  'meta',
  'link',
  'noscript',
  'title',
  // Векторная графика и медиа: SVG умеет ссылаться на чужие ресурсы (`<image href>`,
  // `<use href>`, SMIL-анимации), а <video poster>/<audio>/<source> — это ещё один способ
  // сходить наружу, которого в письме быть не должно.
  'svg',
  'math',
  'video',
  'audio',
  'source',
  'track',
  'canvas',
  'template',
  'dialog',
  'marquee',
  'blink',
];

/** Оболочка документа: сами теги не нужны (документ собирает клиент), содержимое — нужное. */
const UNWRAP_TAGS = new Set(['html', 'head', 'body']);

/** Теги, которые в письме оставляем. Всё остальное — мусор неизвестного происхождения. */
const ALLOWED_TAGS = new Set([
  'a', 'abbr', 'address', 'article', 'aside', 'b', 'bdi', 'bdo', 'big', 'blockquote', 'br',
  'caption', 'center', 'cite', 'code', 'col', 'colgroup', 'dd', 'del', 'dfn', 'div', 'dl', 'dt',
  'em', 'figcaption', 'figure', 'font', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header',
  'hr', 'i', 'img', 'ins', 'kbd', 'li', 'main', 'mark', 'nav', 'ol', 'p', 'picture', 'pre', 'q',
  's', 'samp', 'section', 'small', 'span', 'strike', 'strong', 'style', 'sub', 'sup', 'table',
  'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'tt', 'u', 'ul', 'var', 'wbr',
]);

/**
 * Белый список атрибутов. Всё, чего в нём нет, отбрасывается — и это главная защита от
 * загрузчиков, о которых мы не знаем: `poster`, `lowsrc`, `dynsrc`, `formaction`, `xlink:href`.
 * `on*` отсекается отдельно, до этой проверки.
 */
const ALLOWED_ATTRS = new Set([
  'align', 'alt', 'background', 'bgcolor', 'border', 'cellpadding', 'cellspacing', 'class',
  'color', 'colspan', 'dir', 'face', 'height', 'href', 'hspace', 'id', 'lang', 'name', 'nowrap',
  'rel', 'role', 'rowspan', 'size', 'sizes', 'span', 'src', 'srcset', 'start', 'style', 'summary',
  'target', 'title', 'type', 'valign', 'vspace', 'width',
]);

/** Атрибуты, за значением которых уходит запрос наружу. */
const LOADER_ATTRS = new Set(['src', 'srcset', 'background']);

/** Потолок размера тела: письмо на 10 МБ с картинками в data: превратилось бы в 13 МБ JSON. */
const MAX_HTML_BYTES = 3 * 1024 * 1024;

export interface SanitizeResult {
  html: string;
  /** Сколько внешних картинок заблокировано — клиент по этому числу показывает кнопку. */
  blockedRemote: number;
}

/** Блок удаляем целиком, вместе с содержимым (у этих тегов оно не текст письма). */
function dropTag(html: string, tag: string): string {
  const re = new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?<\\/${tag}\\s*>`, 'gi');
  let out = html.replace(re, '');
  // Незакрытый открывающий тег (частая картинка в письмах от рассыльщиков): убираем его самого.
  const lone = new RegExp(`<\\/?${tag}\\b[^>]*>`, 'gi');
  out = out.replace(lone, '');
  return out;
}

/**
 * HTML-сущности в значении атрибута. Браузер их декодирует (в том числе внутри `style="…"`),
 * значит и проверять надо декодированное: иначе `url(&quot;https://…&quot;)` выглядит как текст.
 * Раскодируем за один проход: `&amp;#106;avascript:` браузер тоже читает однократно.
 */
function decodeEntities(value: string): string {
  return value.replace(/&(?:#x([0-9a-f]{1,6})|#(\d{1,7})|([a-z][a-z0-9]{1,31}));?/gi, (match, hex, dec, name) => {
    if (hex !== undefined || dec !== undefined) {
      const code = Number.parseInt(hex ?? dec, hex !== undefined ? 16 : 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : match;
    }
    // Именованные сущности, которыми можно собрать схему или разделитель адреса по частям
    // (`javascript&colon;…`). Полный список HTML5 тут не нужен: escapeAttr на выходе всё
    // равно превратит `&` в `&amp;`, но проверять значение мы обязаны в том виде, в каком
    // его увидит браузер.
    const named: Record<string, string> = {
      quot: '"', apos: "'", amp: '&', lt: '<', gt: '>', nbsp: '\u00a0', tab: '\t', newline: '\n',
      colon: ':', sol: '/', quest: '?', num: '#', perc: '%', semi: ';', comm: ',', period: '.',
      equals: '=', plus: '+', ast: '*', dollar: '$', excl: '!', commat: '@', grave: '`',
      vert: '|', bsol: '\\', lpar: '(', rpar: ')', lsqb: '[', rsqb: ']', lcub: '{', rcub: '}',
      hyphen: '-', dash: '\u2010', middot: '\u00b7',
    };
    return named[String(name).toLowerCase()] ?? match;
  });
}

/**
 * CSS-экранирование: `\75 rl(https://…)` — это записанный по буквам `url(https://…)`,
 * браузер такой текст читает как обычный url(). Снимаем экранирование до всех проверок.
 */
function unescapeCss(css: string): string {
  return css.replace(/\\(?:([0-9a-f]{1,6})[ \t\r\n\f]?|([\s\S]))/gi, (_m, hex: string | undefined, ch: string | undefined) => {
    if (hex !== undefined) {
      const code = Number.parseInt(hex, 16);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
    }
    return ch === '\n' ? '' : (ch ?? '');
  });
}

/** Что за ссылка: внешняя, data:, опасная схема или безобидная. */
interface UrlInfo {
  /** Абсолютный адрес с чужим хостом: за ним уходит запрос наружу (трекинг). */
  remote: boolean;
  /** data:-ссылка (в письмах так выглядят вставленные вместо cid картинки). */
  data: boolean;
  /** Растровая data:-картинка — единственный безопасный вид data:. */
  dataImage: boolean;
  /** Схема, которой в документе не место: javascript:, vbscript:, file:, blob: и прочее. */
  unsafe: boolean;
}

const SAFE: UrlInfo = { remote: false, data: false, dataImage: false, unsafe: false };
/** Растровые картинки, которые можно держать прямо в письме. SVG сюда не входит: он исполняемый. */
const DATA_IMAGE_RE = /^data:image\/(png|jpe?g|gif|webp|bmp|x-icon|vnd\.microsoft\.icon)[;,]/i;

function urlInfo(raw: string): UrlInfo {
  // Управляющие символы и пробелы внутри схемы браузер игнорирует (`java\tscript:`), поэтому и мы.
  const value = decodeEntities(raw).replace(/[\u0000-\u0020\u007f]+/g, '');
  if (!value) return SAFE;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(value)?.[1]?.toLowerCase() ?? null;
  if (scheme === 'data') {
    const dataImage = DATA_IMAGE_RE.test(value);
    return { remote: false, data: true, dataImage, unsafe: !dataImage };
  }
  // Абсолютный http(s)-адрес — независимо от записи: `http:evil/x`, `https:/evil/x`,
  // `https://evil/x` и `//evil/x` браузер приведёт к одному и тому же запросу наружу.
  // Проверять «начинается ли с https://» поэтому нельзя — только схему и признак «//».
  if (scheme === 'http' || scheme === 'https' || scheme === null) {
    if (scheme === null && !/^(\/\/|\\\\)/.test(value)) {
      // Относительный адрес: документ письма загружается без адреса (about:blank), наружу
      // такой запрос не уходит — и это единственный вид ссылки, который тут безопасен.
      return SAFE;
    }
    return { remote: true, data: false, dataImage: false, unsafe: false };
  }
  if (scheme === 'mailto' || scheme === 'tel' || scheme === 'cid') return SAFE;
  return { remote: false, data: false, dataImage: false, unsafe: true };
}

/**
 * Внешние адреса в CSS (`url()`, `image-set()`, `@font-face`, `cursor`) — такой же трекер,
 * как `<img>`. Ловим их одним проходом по тексту, а не перечислением функций загрузки:
 * список функций заведомо неполон, а любой абсолютный адрес в CSS — уже обращение наружу.
 */
const CSS_URL_RE = new RegExp(
  [
    String.raw`\bdata:image\/(?:png|jpe?g|gif|webp|bmp|x-icon|vnd\.microsoft\.icon)[;,][^\s;'"()>]*`,
    String.raw`(?:[a-z][a-z0-9+.-]*:)?\/\/[^\s;'"()>]+`,
    String.raw`\b(?:https?|ftp|ftps|file|blob|filesystem):[^\s;'"()>]*`,
    String.raw`\bdata:[^\s;'"()>]*`,
  ].join('|'),
  'gi',
);

interface CssResult {
  css: string;
  blocked: number;
}

/**
 * `inStyleBlock` — CSS внутри `<style>`. Там браузер сущности НЕ раскодирует (это raw text),
 * зато CSS-экранирование снимает; в `style="…"` наоборот — сущности раскодирует парсер HTML.
 * Раскодировать в блоке тоже можно, но тогда из CSS придётся вычистить `<`: `\3c /style\3e`
 * в противном случае превратился бы в настоящий закрывающий тег.
 */
function sanitizeCss(css: string, allowRemote: boolean, inStyleBlock: boolean): CssResult {
  let blocked = 0;
  let out = inStyleBlock ? unescapeCss(css) : unescapeCss(decodeEntities(css));
  // @import тянет чужой CSS (и работает как трекер) — вырезаем всегда, даже с картинками.
  out = out.replace(/@import[^;]*;?/gi, () => {
    blocked += 1;
    return '';
  });
  if (!allowRemote) {
    out = out.replace(CSS_URL_RE, (match) => {
      // Растровая картинка внутри письма — не трекер: её оставляем как есть.
      if (DATA_IMAGE_RE.test(match)) return match;
      blocked += 1;
      return 'about:blank';
    });
  } else {
    // Внешние картинки разрешены, а исполняемые data:-ссылки — нет.
    out = out.replace(CSS_URL_RE, (match) => {
      if (/^\s*data:/i.test(match) && !DATA_IMAGE_RE.test(match)) {
        blocked += 1;
        return 'about:blank';
      }
      return match;
    });
  }
  if (inStyleBlock) out = out.replace(/</g, '');
  return { css: out, blocked };
}

/** Значение атрибута обратно в строку: кавычки и угловые скобки экранируем. */
function escapeAttr(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Ссылка из `srcset`: это список «адрес + дескриптор», поэтому проверяем каждый кандидат —
 * одного внешнего адреса в списке достаточно, чтобы атрибут считался внешним.
 */
function srcsetInfo(value: string): UrlInfo {
  let out: UrlInfo = SAFE;
  for (const candidate of decodeEntities(value).split(',')) {
    const url = candidate.trim().split(/\s+/)[0] ?? '';
    if (!url) continue;
    const info = urlInfo(url);
    out = {
      remote: out.remote || info.remote,
      data: out.data || info.data,
      dataImage: out.dataImage && info.dataImage,
      unsafe: out.unsafe || info.unsafe,
    };
  }
  return out;
}

/**
 * Почистить тело письма.
 *
 * `allowRemote` — пользователь нажал «показать картинки»: тогда внешние src оставляем как есть.
 */
export function sanitizeMailHtml(rawHtml: string, allowRemote: boolean): SanitizeResult {
  let html = rawHtml;
  // Комментарии вырезаем первыми: в них прячут и разметку, и «условные» блоки для старых
  // движков, которых в WebView нет.
  html = html.replace(/<!--[\s\S]*?-->/g, '');
  for (const tag of DROP_TAGS) html = dropTag(html, tag);

  let blockedRemote = 0;

  // <style>…</style>: CSS под нашим контролем. Незакрытый блок тоже разбираем (`|$`),
  // иначе его содержимое уехало бы в документ как есть.
  html = html.replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>|$)/gi, (_m, open: string, css: string, close: string) => {
    const res = sanitizeCss(css, allowRemote, true);
    blockedRemote += res.blocked;
    return `${open}${res.css}${close}`;
  });

  // Ссылки: target=_blank нужен, чтобы переход по ссылке открывал новую вкладку. rel — чтобы
  // открытая страница не получила доступ к нашему документу.
  html = html.replace(/<a\b([^>]*)>/gi, (_m, attrs: string) => {
    let rest = attrs.replace(/\s+target\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    rest = rest.replace(/\s+rel\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    return `<a${rest} target="_blank" rel="noopener noreferrer nofollow">`;
  });

  // Теги и атрибуты: оставляем только известное доброе, обработчики событий и опасные
  // схемы убираем всегда, атрибут за атрибутом.
  html = html.replace(/<([a-z][a-z0-9-]*)\b([^>]*)>/gi, (_m, rawTag: string, attrs: string) => {
    const tag = rawTag.toLowerCase();
    if (UNWRAP_TAGS.has(tag)) return '';
    if (!ALLOWED_TAGS.has(tag)) return '';

    let out = '';
    const attrRe = /([a-z_:][-a-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/gi;
    let last = 0;
    let match: RegExpExecArray | null;
    while ((match = attrRe.exec(attrs)) !== null) {
      const name = match[1];
      const value = match[3] ?? match[4] ?? match[5] ?? '';
      out += attrs.slice(last, match.index);
      last = match.index + match[0].length;

      const lower = name.toLowerCase();
      if (lower.startsWith('on')) continue;
      if (!ALLOWED_ATTRS.has(lower)) continue;

      if (lower === 'style') {
        const res = sanitizeCss(value, allowRemote, false);
        blockedRemote += res.blocked;
        out += `${name}="${escapeAttr(res.css)}"`;
        continue;
      }

      if (lower === 'href') {
        const info = urlInfo(value);
        // data: в ссылке не нужен вовсе, а опасные схемы — тем более.
        if (info.unsafe || info.data) continue;
        out += `${name}="${escapeAttr(value)}"`;
        continue;
      }

      if (LOADER_ATTRS.has(lower)) {
        const info = lower === 'srcset' ? srcsetInfo(value) : urlInfo(value);
        // Небезопасная схема (javascript:, data:text/html, data:image/svg+xml) — атрибут убираем.
        if (info.unsafe || (info.data && !info.dataImage)) continue;
        if (info.remote && !allowRemote) {
          blockedRemote += 1;
          out += `data-blocked-${lower}="${escapeAttr(value)}"`;
          continue;
        }
        out += `${name}="${escapeAttr(value)}"`;
        continue;
      }

      out += `${name}="${escapeAttr(value)}"`;
    }
    out += attrs.slice(last);
    return `<${tag}${out}>`;
  });

  // Закрывающие теги оболочки (они не проходят проверку выше: она смотрит только открывающие)
  // убираем сами — содержимое при этом не трогаем.
  for (const tag of UNWRAP_TAGS) html = html.replace(new RegExp(`<\\/?${tag}\\b[^>]*>`, 'gi'), '');

  return { html, blockedRemote };
}

/** Текст письма в HTML: сохраняем переносы и экранируем разметку. */
export function textToHtml(text: string): string {
  return `<pre style="white-space:pre-wrap;word-wrap:break-word;font:inherit;margin:0">${escapeAttr(text)}</pre>`;
}

/** Не слишком ли большое тело для отдачи в браузер. */
export function htmlWithinLimit(html: string): boolean {
  return Buffer.byteLength(html, 'utf8') <= MAX_HTML_BYTES;
}
