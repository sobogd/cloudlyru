/**
 * Подготовка тела письма к показу в нашем интерфейсе.
 *
 * Две линии защиты, и это важно понимать по порядку:
 *
 * 1. Браузерная — тело показывается в iframe с `sandbox` БЕЗ `allow-scripts`. Даже если
 *    разметка протащит что-то исполняемое, исполнить это негде: скриптов в песочнице нет.
 * 2. Эта — серверная чистка. Она убирает из письма то, что в песочнице всё равно не сработает,
 *    но ломает вид (формы, вложенные фреймы, подгрузку чужих ресурсов) и то, что может
 *    сработать, если песочницу однажды ослабят.
 *
 * Внешние картинки по умолчанию не грузим: это трекинг-пиксели — по запросу за картинкой
 * отправитель узнаёт, что письмо открыли, когда и с какого адреса. Показываем их только
 * после явного «показать картинки».
 *
 * Вложения по cid сюда не попадают: разборщик уже заменил их на data:-ссылки, поэтому тело
 * письма самодостаточно.
 */

/** Теги, которых в письме быть не должно: исполняемое, внешние встраивания, формы. */
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
];

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
 * Внешние картинки, спрятанные в CSS (`background:url(...)`) — такой же трекер, как <img>.
 * Заменяем на пустой url: правило остаётся, запрос наружу не уходит.
 */
function stripRemoteCssUrls(css: string): { css: string; blocked: number } {
  let blocked = 0;
  const out = css.replace(/url\(\s*(['"]?)((?:https?:)?\/\/[^)'"]*)\1\s*\)/gi, () => {
    blocked += 1;
    return 'url(about:blank)';
  });
  return { css: out, blocked };
}

/** Значение атрибута ведёт на исполняемую схему или на data: с разметкой. */
function isDangerousUrl(url: string): boolean {
  const clean = url.replace(/[\u0000-\u0020]/g, '').toLowerCase();
  return (
    clean.startsWith('javascript:') ||
    clean.startsWith('vbscript:') ||
    clean.startsWith('file:') ||
    clean.startsWith('data:text/html') ||
    clean.startsWith('data:image/svg') ||
    clean.startsWith('data:application/')
  );
}

/**
 * Почистить тело письма.
 *
 * `allowRemote` — пользователь нажал «показать картинки»: тогда внешние src оставляем как есть.
 */
export function sanitizeMailHtml(rawHtml: string, allowRemote: boolean): SanitizeResult {
  let html = rawHtml;
  for (const tag of DROP_TAGS) html = dropTag(html, tag);

  // @import в <style> тянет чужой CSS (и работает как трекер) — вырезаем всегда.
  html = html.replace(/@import[^;]*;?/gi, '');

  let blockedRemote = 0;

  // Картинки, спрятанные в CSS: url(...) на чужой хост. В <style> — всегда, в inline style —
  // по общему правилу про внешние ресурсы.
  html = html.replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>)/gi, (_m, open: string, css: string, close: string) => {
    const res = stripRemoteCssUrls(css);
    blockedRemote += res.blocked;
    return `${open}${res.css}${close}`;
  });

  // Ссылки: target=_blank нужен, чтобы переход по ссылке открывал новую вкладку, а не
  // уводил песочницу. rel — чтобы открытая страница не получила доступ к нашему окну.
  html = html.replace(/<a\b([^>]*)>/gi, (_m, attrs: string) => {
    let rest = attrs.replace(/\s+target\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    rest = rest.replace(/\s+rel\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    return `<a${rest} target="_blank" rel="noopener noreferrer nofollow">`;
  });

  // Обработчики событий и опасные схемы: on* убираем всегда, атрибут за атрибутом.
  html = html.replace(/<([a-z][a-z0-9-]*)\b([^>]*)>/gi, (_m, tag: string, attrs: string) => {
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
      if (isDangerousUrl(value)) continue;

      if (lower === 'style') {
        const res = stripRemoteCssUrls(value);
        if (!allowRemote) blockedRemote += res.blocked;
        out += `${name}="${escapeAttr(allowRemote ? value : res.css)}"`;
        continue;
      }

      // Внешние ресурсы: src/srcset/background. Оставляем только при явном разрешении.
      const isRemote = /^(https?:)?\/\//i.test(value.trim());
      const loadsResource = lower === 'src' || lower === 'srcset' || lower === 'background';
      if (isRemote && loadsResource && !allowRemote) {
        blockedRemote += 1;
        out += `data-blocked-${lower}="${escapeAttr(value)}"`;
        continue;
      }
      out += `${name}="${escapeAttr(value)}"`;
    }
    out += attrs.slice(last);
    return `<${tag}${out}>`;
  });

  // Пустая (но валидная) оболочка: тело письма без <html> тоже бывает, а стили браузера
  // для iframe дают белый фон и «табличный» вид, к которому письма и рассчитаны.
  return { html, blockedRemote };
}

/** Значение атрибута обратно в строку: кавычки и угловые скобки экранируем. */
function escapeAttr(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Текст письма в HTML: сохраняем переносы и экранируем разметку. */
export function textToHtml(text: string): string {
  return `<pre style="white-space:pre-wrap;word-wrap:break-word;font:inherit;margin:0">${escapeAttr(text)}</pre>`;
}

/** Не слишком ли большое тело для отдачи в браузер. */
export function htmlWithinLimit(html: string): boolean {
  return Buffer.byteLength(html, 'utf8') <= MAX_HTML_BYTES;
}
