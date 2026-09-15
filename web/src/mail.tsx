import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import {
  Download,
  Eraser,
  FileSearch,
  Forward,
  Inbox,
  LoaderCircle,
  Paperclip,
  PenSquare,
  RefreshCw,
  Reply,
  ReplyAll,
  RotateCcw,
  Send,
  Trash2,
  X,
} from 'lucide-react';
import { createPortal } from 'react-dom';
import * as api from './api';
import { patchUi, readUi } from './storage';

/**
 * Раздел «Почта»: две папки, бесконечная лента и просмотр письма.
 *
 * Лента устроена так же, как «Медиа» (`media.tsx`), и это осознанное повторение, а не
 * копипаста ради красоты: у сервера спрашиваем только общее число писем, считаем полную
 * высоту скролла и держим ползунок «как в галерее», а сами письма догружаем куском видимой
 * области после остановки прокрутки. Пагинации нет вовсе — только даты в шапке и на ползунке.
 *
 * Отличие от галереи одно: там сетка из равных клеток, тут одна колонка, поэтому высота
 * строки фиксирована (ROW_H), а тема и превью обрезаются: при «резиновой» высоте виртуальный
 * скролл поехал бы.
 */

type Box = api.MailBoxId;
type Item = api.MailListItem;

/** Высота строки письма. Должна совпадать с .mailrow в styles.css. */
const ROW_H = 76;
/** Сколько строк вне экрана держим смонтированными. */
const OVERSCAN = 6;
/** Дебаунс запроса видимой части после остановки скролла. */
const FETCH_DEBOUNCE_MS = 400;
/** Сколько писем просим одним запросом. */
const FETCH_CHUNK = 200;
/** Как часто переспрашивать ленту, когда открыт раздел: новые письма приходят сами. */
const POLL_MS = 20000;

const MONTHS = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];

function monthLabel(key: string): string {
  const [y, m] = key.split('-');
  return `${MONTHS[Number(m) - 1] ?? key} ${y}`;
}

/** Дата письма в списке: сегодня — время, в этом году — число и месяц, иначе с годом. */
function listDate(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  if (sameDay) return d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  const opts: Intl.DateTimeFormatOptions =
    d.getFullYear() === now.getFullYear() ? { day: '2-digit', month: 'short' } : { day: '2-digit', month: '2-digit', year: '2-digit' };
  return d.toLocaleDateString('ru-RU', opts);
}

/** Полная дата письма для шапки просмотра: ДД.ММ.ГГ ЧЧ:ММ. */
function fullDate(iso: string): string {
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${p(d.getDate())}.${p(d.getMonth() + 1)}.${p(d.getFullYear() % 100)} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function fmtSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} КБ`;
  return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
}

/** Бинарный поиск месяца по абсолютному индексу письма (кумулятивные отрезки). */
function findBucket(
  cum: Array<{ month: string; start: number; end: number }> | null,
  index: number,
): { month: string } | undefined {
  if (!cum || !cum.length) return undefined;
  let lo = 0;
  let hi = cum.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const b = cum[mid];
    if (index < b.start) hi = mid - 1;
    else if (index >= b.end) lo = mid + 1;
    else return b;
  }
  return undefined;
}

/**
 * Короткая подпись ящика для тега: домен («gmail.com»), а если на домене несколько ящиков —
 * полный адрес, иначе теги было бы не различить.
 */
function accountTag(email: string, all: api.MailAccountRow[]): string {
  const domain = email.split('@')[1] ?? email;
  const sameDomain = all.filter((a) => (a.email.split('@')[1] ?? '') === domain).length > 1;
  return sameDomain ? email : domain;
}

/**
 * Цвет тега — по самому ящику, а не по его месту в списке: ящики добавляются и удаляются,
 * а письма не должны менять цвет от того, что рядом появился ещё один.
 */
function accountTone(accountId: string): string {
  let hash = 0;
  for (let i = 0; i < accountId.length; i++) hash = (hash * 31 + accountId.charCodeAt(i)) % 997;
  return `tone-${hash % 6}`;
}

/** Кто отправитель: имя, иначе адрес. */
function senderOf(item: Item): string {
  return item.fromName || item.fromAddr || 'без отправителя';
}

/** Домен отправителя для логотипа: `support@kino.watch` → `kino.watch`. */
function domainOf(fromAddr: string | null): string | null {
  if (!fromAddr) return null;
  const i = fromAddr.lastIndexOf('@');
  if (i <= 0 || i === fromAddr.length - 1) return null;
  return fromAddr.slice(i + 1).toLowerCase();
}

/**
 * Аватар отправителя: favicon домена, при отсутствии/ошибке — кружок с буквой.
 * favicon грузит сервер (см. /mail/favicon), поэтому сюда приходит уже готовый URL.
 */
function SenderAvatar({ name, addr }: { name: string | null; addr: string | null }) {
  const domain = domainOf(addr);
  const [failed, setFailed] = useState(false);
  const initial = (name || addr || 'без отправителя').trim();
  const letter = initial ? initial[0].toUpperCase() : '?';
  if (!domain || failed) {
    return <span className="mailava" aria-hidden>{letter}</span>;
  }
  return <img className="mailava mailfav" src={api.faviconUrl(domain)} alt="" onError={() => setFailed(true)} />;
}

export default function MailSection({
  onOverlayChange,
  renderFileDetail,
}: {
  onOverlayChange?: (open: boolean) => void;
  /**
   * Деталка файла — её рисует приложение (в `mail.tsx` она жить не может: это тот же файловый
   * экран, и тянуть его сюда значило бы получить круговой импорт). Здесь она нужна, чтобы
   * проваливаться во вложение прямо из письма: в «Файлах» папка «Почта» скрыта, и другого
   * пути к деталке вложения нет.
   */
  renderFileDetail?: (entryId: string, onClose: () => void) => ReactNode;
}) {
  const [saved] = useState(() => readUi().mail);
  const [box, setBox] = useState<Box>(
    saved?.box === 'sent' || saved?.box === 'trash' ? saved.box : 'inbox',
  );
  const [total, setTotal] = useState<number | null>(null);
  const [months, setMonths] = useState<Array<{ month: string; count: number }> | null>(null);
  const [items, setItems] = useState<Map<number, Item>>(() => new Map());
  const [error, setError] = useState('');
  const [openId, setOpenId] = useState<string | null>(saved?.openId ?? null);
  const [range, setRange] = useState<[number, number]>([0, Math.ceil(1200 / ROW_H) + OVERSCAN]);
  const [viewport, setViewport] = useState(0);
  const [scrub, setScrub] = useState<{ top: number; h: number; monthKey: string | undefined }>({ top: 0, h: 24, monthKey: undefined });
  const [scrubVisible, setScrubVisible] = useState(false);
  const [busy, setBusy] = useState(false);
  /** Аккаунты — для подписи «откуда письмо» и ответа/пересылки. */
  const [accounts, setAccounts] = useState<api.MailAccountRow[]>([]);
  /** Открытая форма письма: null — закрыта, {} — новое, {...} — заготовка ответа или пересылки. */
  const [composer, setComposer] = useState<{ initial: Partial<MailDraft> | null } | null>(null);

  const scrollRef = useRef<HTMLDivElement>(null);
  const railRef = useRef<HTMLDivElement>(null);
  const totalRef = useRef<number | null>(null);
  totalRef.current = total;
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const seqRef = useRef(0);
  const debounceRef = useRef<number | null>(null);
  const rafRef = useRef(0);
  const hideTimer = useRef<number | null>(null);
  const dragRef = useRef(false);
  const persistTimer = useRef<number | null>(null);
  const restoredRef = useRef(false);
  const openIdRef = useRef<string | null>(null);
  openIdRef.current = openId;

  useEffect(() => {
    onOverlayChange?.(openId != null);
  }, [openId, onOverlayChange]);

  const rowCount = total == null ? 0 : total;
  const totalH = Math.max(0, rowCount * ROW_H);

  /** Список писем выбранной папки: число и индекс по месяцам — одним заходом. */
  const loadCounters = useCallback(async () => {
    try {
      const [n, m] = await Promise.all([api.mailCount(box), api.mailMonths(box)]);
      setTotal(n);
      totalRef.current = n;
      setMonths(m);
      setError('');
      return n;
    } catch (e) {
      // Фоновый сбой (полл, возврат на вкладку) при уже показанном списке не пугает баннером:
      // данные остаются, следующий проход перечитает. Баннер — только когда списка нет вовсе.
      if (totalRef.current == null) setError((e as Error).message);
      return null;
    }
  }, [box]);

  useEffect(() => {
    api.mailAccounts().then(setAccounts).catch(() => undefined);
  }, []);

  // Выбранную папку запоминаем сразу, не дожидаясь прокрутки: позицию внутри
  // списка при этом не трогаем — её пишет persist при скролле.
  useEffect(() => {
    const cur = readUi().mail ?? {};
    patchUi({ mail: { ...cur, box } });
  }, [box]);

  useEffect(() => {
    // Смена папки — другой список: старые строки не подходят по индексам.
    setItems(new Map());
    setTotal(null);
    totalRef.current = null;
    restoredRef.current = false;
    void loadCounters();
  }, [box, loadCounters]);

  // Измеряем высоту окна прокрутки: от неё зависит, сколько строк просить.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => setViewport(el.clientHeight || 600);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  /** Догрузить диапазон индексов [start, end] (только отсутствующие куски). */
  const fetchRange = useCallback(
    async (start: number, end: number) => {
      const t = totalRef.current;
      if (t == null) return;
      start = Math.max(0, start);
      end = Math.min(t - 1, end);
      if (start > end) return;
      const map = itemsRef.current;
      const spans: Array<[number, number]> = [];
      let a = -1;
      for (let i = start; i <= end; i++) {
        if (!map.has(i)) {
          if (a === -1) a = i;
        } else if (a !== -1) {
          spans.push([a, i - 1]);
          a = -1;
        }
      }
      if (a !== -1) spans.push([a, end]);
      for (const [s, e] of spans) {
        for (let off = s; off <= e; off += FETCH_CHUNK) {
          const len = Math.min(FETCH_CHUNK, e - off + 1);
          const seq = ++seqRef.current;
          try {
            const page = await api.mailRange(box, off, len);
            if (seq !== seqRef.current) return; // список успели перечитать — данные устарели
            setItems((prev) => {
              const next = new Map(prev);
              for (let j = 0; j < page.length; j++) next.set(off + j, page[j]);
              return next;
            });
          } catch (err) {
            if (seq === seqRef.current) setError((err as Error).message);
          }
        }
      }
    },
    [box],
  );
  const fetchRangeRef = useRef(fetchRange);
  fetchRangeRef.current = fetchRange;

  const updateRange = useCallback(
    (top: number) => {
      const vh = viewport || 600;
      const start = Math.max(0, Math.floor(top / ROW_H) - OVERSCAN);
      const end = Math.min(rowCount - 1, Math.ceil((top + vh) / ROW_H) + OVERSCAN);
      setRange((prev) => (prev[0] === start && prev[1] === end ? prev : [start, end]));
    },
    [viewport, rowCount],
  );

  /** Запрос видимой части — только после остановки скролла. */
  const scheduleFetch = useCallback(() => {
    if (debounceRef.current != null) window.clearTimeout(debounceRef.current);
    debounceRef.current = window.setTimeout(() => {
      debounceRef.current = null;
      const el = scrollRef.current;
      const t = totalRef.current;
      if (!el || t == null) return;
      const top = el.scrollTop;
      const vh = el.clientHeight || 600;
      const first = Math.max(0, Math.floor(top / ROW_H) - OVERSCAN);
      const last = Math.min(t - 1, Math.ceil((top + vh) / ROW_H) + OVERSCAN);
      if (last >= 0) void fetchRangeRef.current(first, last);
    }, FETCH_DEBOUNCE_MS);
  }, []);

  // Кумулятивные отрезки месяцев: по индексу письма — его месяц.
  const monthCum = useMemo(() => {
    if (!months) return null;
    const arr: Array<{ month: string; start: number; end: number }> = [];
    let start = 0;
    for (const b of months) {
      if (b.count <= 0) continue;
      arr.push({ month: b.month, start, end: start + b.count });
      start += b.count;
    }
    return arr;
  }, [months]);
  const monthCumRef = useRef(monthCum);
  monthCumRef.current = monthCum;

  /** Геометрия ползунка и месяц в текущей позиции. */
  const updateScrub = useCallback((top: number) => {
    const el = scrollRef.current;
    if (!el) return;
    const sh = el.scrollHeight;
    const ch = el.clientHeight;
    const h = Math.max(24, (ch / Math.max(sh, 1)) * ch);
    const maxScroll = sh - ch;
    const t = maxScroll > 0 ? (top / maxScroll) * (ch - h) : 0;
    const b = findBucket(monthCumRef.current, Math.max(0, Math.floor(top / ROW_H)));
    setScrub((s) => (s.top === t && s.h === h && s.monthKey === b?.month ? s : { top: t, h, monthKey: b?.month }));
  }, []);

  /** Запомнить позицию и открытое письмо (переживает закрытие приложения). */
  const persist = useCallback((top: number) => {
    if (persistTimer.current != null) window.clearTimeout(persistTimer.current);
    const index = Math.max(0, Math.floor(top / ROW_H));
    const open = openIdRef.current;
    persistTimer.current = window.setTimeout(() => {
      persistTimer.current = null;
      patchUi({ mail: { box, index, scrollTop: top, openId: open } });
    }, 400);
  }, [box]);

  const showScrub = useCallback(() => {
    setScrubVisible(true);
    if (hideTimer.current != null) window.clearTimeout(hideTimer.current);
    hideTimer.current = window.setTimeout(() => setScrubVisible(false), 1200);
  }, []);

  const onScroll = useCallback(() => {
    if (rafRef.current) return;
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = 0;
      const el = scrollRef.current;
      if (!el) return;
      const top = el.scrollTop;
      updateRange(top);
      updateScrub(top);
      persist(top);
      showScrub();
      scheduleFetch();
    });
  }, [persist, scheduleFetch, showScrub, updateRange, updateScrub]);

  // Восстановление позиции из прошлого визита — один раз, когда известна высота.
  useEffect(() => {
    if (restoredRef.current || total == null || !viewport) return;
    restoredRef.current = true;
    const el = scrollRef.current;
    if (!el) return;
    if (openId) {
      // Письмо было открыто при уходе из раздела: показываем его, а ленту ставим на его место.
      const idx = saved?.index ?? 0;
      const top = Math.min(idx * ROW_H, Math.max(0, total * ROW_H - viewport));
      el.scrollTop = top;
      updateRange(top);
      updateScrub(top);
      scheduleFetch();
      return;
    }
    const top = Math.min(saved?.scrollTop ?? 0, Math.max(0, total * ROW_H - viewport));
    if (top > 0) el.scrollTop = top;
    updateRange(top);
    updateScrub(top);
    scheduleFetch();
  }, [openId, saved, scheduleFetch, total, updateRange, updateScrub, viewport]);

  /** Плавный переход к доле ленты (перетаскивание ползунка). */
  const scrubTo = useCallback(
    (clientY: number) => {
      const el = scrollRef.current;
      const rail = railRef.current;
      if (!el || !rail) return;
      const rect = rail.getBoundingClientRect();
      const frac = Math.max(0, Math.min(1, (clientY - rect.top) / Math.max(rect.height, 1)));
      const maxScroll = el.scrollHeight - el.clientHeight;
      const top = frac * maxScroll;
      el.scrollTop = top;
      updateRange(top);
      updateScrub(top);
      persist(top);
      scheduleFetch();
      showScrub();
    },
    [persist, scheduleFetch, showScrub, updateRange, updateScrub],
  );

  useEffect(() => {
    const move = (e: PointerEvent) => {
      if (dragRef.current) scrubTo(e.clientY);
    };
    const up = () => {
      dragRef.current = false;
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    return () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
    };
  }, [scrubTo]);

  // Новые письма приходят сами: пока раздел открыт, тихо перечитываем число и первые строки.
  useEffect(() => {
    const t = window.setInterval(async () => {
      const prev = totalRef.current;
      const n = await loadCounters();
      if (n != null && n !== prev) {
        const el = scrollRef.current;
        // Новые письма встают сверху и сдвигают все индексы. Сдвигаем позицию скролла на
        // число новых строк, чтобы под курсором остались те же письма, а не «прыгнули».
        if (el && prev != null && n > prev) el.scrollTop += (n - prev) * ROW_H;
        setItems(new Map());
        itemsRef.current = new Map();
        if (el) void fetchRangeRef.current(Math.max(0, Math.floor(el.scrollTop / ROW_H) - OVERSCAN), Math.floor(el.scrollTop / ROW_H) + OVERSCAN + 20);
      }
    }, POLL_MS);
    return () => window.clearInterval(t);
  }, [loadCounters]);

  /** Ждём конца серверного прохода синхронизации (или выходим по таймауту). */
  const waitForSync = async () => {
    for (let i = 0; i < 10; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      try {
        const s = await api.mailStatus();
        if (!s.accounts.some((a) => a.status === 'syncing')) return;
      } catch {
        return;
      }
    }
  };

  const refresh = async () => {
    setBusy(true);
    try {
      await api.mailSync();
      // Проход асинхронный: сразу читать счётчики бессмысленно (они ещё старые). Ждём его
      // конца, чтобы кнопка «Проверить» действительно показывала свежую почту.
      await waitForSync();
      setItems(new Map());
      itemsRef.current = new Map();
      await loadCounters();
      const el = scrollRef.current;
      if (el) void fetchRangeRef.current(0, OVERSCAN + 20);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  /** Очистить корзину почты: письма удаляются безвозвратно. */
  const emptyTrash = async () => {
    if (!confirm('Очистить корзину почты? Письма будут удалены безвозвратно.')) return;
    setBusy(true);
    try {
      await api.mailPurgeTrash();
      setOpenId(null);
      setItems(new Map());
      itemsRef.current = new Map();
      await loadCounters();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  /** Письмо изменило своё место (удалено/восстановлено/стёрто): перечитать текущую папку. */
  const reloadList = useCallback(() => {
    setOpenId(null);
    setItems(new Map());
    itemsRef.current = new Map();
    void loadCounters().then(() => {
      const el = scrollRef.current;
      if (el) void fetchRangeRef.current(0, OVERSCAN + 20);
    });
  }, [loadCounters]);

  /** Кусок видимых строк: строка на письмо, высота фиксирована. */
  const rows = useMemo(() => {
    const out: Array<{ y: number; index: number; item?: Item }> = [];
    for (let r = range[0]; r <= range[1] && r >= 0; r++) {
      const item = items.get(r);
      out.push({ y: r * ROW_H, index: r, item });
    }
    return out;
  }, [range, items]);

  const openIndex = useMemo(() => {
    if (!openId) return null;
    for (const [i, it] of items) if (it.id === openId) return i;
    return null;
  }, [items, openId]);

  /** Листание писем в просмотре: сосед по ленте (его id берём из уже загруженного куска). */
  const neighbour = useCallback(
    (delta: number): string | null => {
      if (openIndex == null || total == null) return null;
      const next = openIndex + delta;
      if (next < 0 || next >= total) return null;
      const it = itemsRef.current.get(next);
      return it ? it.id : null;
    },
    [openIndex, total],
  );

  /** Ответ или пересылка: получателей, тему и цитату считает сервер (правила неочевидные). */
  const openReply = useCallback(
    async (mode: 'reply' | 'replyAll' | 'forward', messageId: string) => {
      try {
        const ctx = await api.mailReplyContext(messageId, mode);
        setComposer({
          initial: {
            accountId: ctx.accountId,
            to: ctx.to,
            cc: ctx.cc,
            subject: ctx.subject,
            text: ctx.body,
            inReplyToId: ctx.inReplyToId,
            attachments: ctx.attachments,
          },
        });
      } catch (e) {
        setError((e as Error).message);
      }
    },
    [],
  );

  const patchItem = useCallback((id: string, patch: Partial<Item>) => {
    setItems((prev) => {
      const next = new Map(prev);
      for (const [i, it] of next) if (it.id === id) next.set(i, { ...it, ...patch });
      return next;
    });
  }, []);

  return (
    <div className="media mail">
      <div className="mhead mailhead">
        <div className="mailtabs">
          <button className={box === 'inbox' ? 'mailtab active' : 'mailtab'} title="Входящие" onClick={() => setBox('inbox')}>
            <Inbox size={18} />
          </button>
          <button className={box === 'sent' ? 'mailtab active' : 'mailtab'} title="Исходящие" onClick={() => setBox('sent')}>
            <Send size={18} />
          </button>
          <button className={box === 'trash' ? 'mailtab active' : 'mailtab'} title="Корзина" onClick={() => setBox('trash')}>
            <Trash2 size={18} />
          </button>
        </div>
        <div className="mailactions">
          {box === 'trash' && total != null && total > 0 && (
            <button className="iconbtn" title="Очистить корзину" onClick={() => void emptyTrash()}>
              <Eraser size={18} />
            </button>
          )}
          <button className="iconbtn" title="Проверить почту" onClick={() => void refresh()} disabled={busy}>
            {busy ? <LoaderCircle className="spin" size={18} /> : <RefreshCw size={18} />}
          </button>
          <button
            className="iconbtn"
            title={accounts.length ? 'Написать письмо' : 'Сначала добавьте аккаунт в «Настройках»'}
            disabled={!accounts.some((a) => a.enabled)}
            onClick={() => setComposer({ initial: null })}
          >
            <PenSquare size={18} />
          </button>
        </div>
      </div>

      <div className="mscroll-wrap">
        <div className="mscroll" ref={scrollRef} onScroll={onScroll}>
          {error && <div className="err" style={{ padding: '8px 4px' }}>{error}</div>}
          {total == null && !error && (
            <div className="mailskel">
              {Array.from({ length: Math.max(2, Math.ceil((viewport || 600) / ROW_H)) }).map((_, i) => (
                <div className="mailrow" key={i}><span className="mailrow-skel" /></div>
              ))}
            </div>
          )}
          {total === 0 && (
            <div className="mempty">
              <span className="copy">
                {box === 'inbox'
                  ? 'Входящих пока нет — письма появятся здесь сами'
                  : box === 'sent'
                    ? 'Исходящих пока нет'
                    : 'Корзина пуста'}
              </span>
            </div>
          )}
          {total != null && total > 0 && (
            <div className="mailvirt" style={{ height: totalH }}>
              {rows.map((row) => (
                <div className="mailrow" key={row.index} style={{ transform: `translateY(${row.y}px)` }}>
                  {row.item ? (
                    <button className={'mailitem' + (row.item.seen ? '' : ' unread')} onClick={() => setOpenId(row.item!.id)}>
                      <SenderAvatar name={row.item.fromName} addr={row.item.fromAddr} />
                      <span className="mailmain">
                        <span className="mailtop">
                          <span className="mailwho">{senderOf(row.item)}</span>
                          {row.item.threadCount > 1 && (
                            <span className="mailthread" title={`${row.item.threadCount} писем в цепочке`}>
                              {row.item.threadCount}
                            </span>
                          )}
                          <span className={'mailacc ' + accountTone(row.item.accountId)}>
                            {accountTag(row.item.accountEmail, accounts)}
                          </span>
                          <span className="maildate">{listDate(row.item.sortAt)}</span>
                        </span>
                        <span className="mailsubj">{row.item.subject || '(без темы)'}</span>
                        <span className="mailprev">{row.item.preview || ' '}</span>
                      </span>
                      <span className="mailmark">
                        {row.item.hasAttachments && <Paperclip size={13} />}
                      </span>
                    </button>
                  ) : (
                    <span className="mailrow-skel" />
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {total != null && total > 0 && (
          <div
            className={'mrail' + (scrubVisible ? ' visible' : '')}
            ref={railRef}
            onPointerDown={(e) => {
              dragRef.current = true;
              scrubTo(e.clientY);
            }}
          >
            <div className="mthumb" style={{ top: scrub.top, height: scrub.h }} />
            {scrub.monthKey && (
              <div className="mthumb-label" style={{ top: scrub.top + scrub.h / 2 }} aria-hidden>
                {monthLabel(scrub.monthKey)}
              </div>
            )}
          </div>
        )}
      </div>

      {composer && (
        <MailComposer
          accounts={accounts}
          initial={composer.initial}
          onClose={() => setComposer(null)}
          onSent={() => {
            setComposer(null);
            // Отправленное письмо уже лежит в «Исходящих» — показываем его там же
            setBox('sent');
            setItems(new Map());
            itemsRef.current = new Map();
            void loadCounters();
          }}
        />
      )}

      {openId && (
        <MailViewer
          id={openId}
          inTrash={box === 'trash'}
          onReply={(mode, messageId) => void openReply(mode, messageId)}
          renderFileDetail={renderFileDetail}
          onClose={() => {
            setOpenId(null);
            const el = scrollRef.current;
            if (el) persist(el.scrollTop);
          }}
          onChanged={(patch) => patchItem(openId, patch)}
          onDeleted={reloadList}
          onRestored={reloadList}
          prev={() => neighbour(-1)}
          next={() => neighbour(1)}
          onNav={(id) => setOpenId(id)}
          keyboardActive={!composer}
        />
      )}
    </div>
  );
}

// =============================== Просмотр письма ===============================

/**
 * Письмо целиком: шапка, тело и части.
 *
 * Тело показываем в iframe с sandbox без `allow-scripts`: разметку письма прислал кто угодно,
 * и единственный надёжный способ её показать — не дать ей исполниться. Разметку при этом
 * чистит сервер (см. mail-html.ts), песочница — вторая линия.
 *
 * Внешние картинки не грузим, пока пользователь не нажмёт «показать картинки»: по запросу
 * за картинкой отправитель узнаёт, что письмо открыли.
 */
export function MailViewer({
  id,
  inTrash = false,
  onClose,
  onChanged,
  onDeleted,
  onRestored,
  prev,
  next,
  onNav,
  onReply,
  renderFileDetail,
  keyboardActive = true,
}: {
  id: string;
  /** Письмо открыто из корзины: вместо ответа/удаления — восстановить и стереть навсегда. */
  inTrash?: boolean;
  onClose: () => void;
  onReply?: (mode: 'reply' | 'replyAll' | 'forward', messageId: string) => void;
  onChanged?: (patch: { seen?: boolean }) => void;
  onDeleted?: () => void;
  onRestored?: () => void;
  prev: () => string | null;
  next: () => string | null;
  onNav: (id: string) => void;
  renderFileDetail?: (entryId: string, onClose: () => void) => ReactNode;
  /** Клавиши вьювера (стрелки, Escape) работают только когда он верхняя модалка. */
  keyboardActive?: boolean;
}) {
  /** Открытая деталка вложения: показывается вместо письма, «назад» возвращает к письму. */
  const [openEntry, setOpenEntry] = useState<string | null>(null);
  const [msg, setMsg] = useState<api.MailMessageView | null>(null);
  const [body, setBody] = useState<{ html: string; blockedRemote: number; kind: 'html' | 'text' } | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  // Открытие письма = прочитано. Отметку ставим на сервере и сразу показываем в списке.
  useEffect(() => {
    let stopped = false;
    setMsg(null);
    setBody(null);
    setError('');
    api
      .mailMessage(id)
      .then((m) => {
        if (stopped) return;
        setMsg(m);
        if (!m.seen) {
          void api.mailSetSeen(id, true).catch(() => undefined);
          onChanged?.({ seen: true });
        }
      })
      .catch((e) => !stopped && setError((e as Error).message));
    return () => {
      stopped = true;
    };
    // onChanged намеренно не в зависимостях: это колбэк-обновление списка, а не данные письма
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  useEffect(() => {
    let stopped = false;
    // Картинки показываем сразу: отдельной кнопки «показать изображения» больше нет.
    api
      .mailBody(id, true)
      .then((b) => !stopped && setBody(b))
      .catch((e) => !stopped && setError((e as Error).message));
    return () => {
      stopped = true;
    };
  }, [id]);

  // Листание вверх/вниз по ленте: стрелки и клавиши, как в просмотрщике «Медиа».
  useEffect(() => {
    // Пока поверх письма открыта форма ответа, клавиши вьювера не работают: иначе стрелки
    // в textarea одновременно листали бы письмо внизу, а Escape закрывал бы не то окно.
    if (!keyboardActive) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      if (e.key === 'ArrowDown' || e.key === 'j') {
        const n = next();
        if (n) onNav(n);
      }
      if (e.key === 'ArrowUp' || e.key === 'k') {
        const p = prev();
        if (p) onNav(p);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [keyboardActive, next, prev, onClose, onNav]);

  const remove = async () => {
    if (!msg) return;
    if (!confirm('Удалить письмо? Оно уйдёт в корзину.')) return;
    setBusy(true);
    try {
      await api.mailDelete(msg.id);
      onDeleted?.();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const restore = async () => {
    if (!msg) return;
    setBusy(true);
    try {
      await api.mailRestore(msg.id);
      onRestored?.();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const purgeForever = async () => {
    if (!msg) return;
    if (!confirm('Удалить письмо навсегда? Вернуть его будет нельзя.')) return;
    setBusy(true);
    try {
      await api.mailPurgeMessage(msg.id);
      onDeleted?.();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const files = msg ? msg.attachments.filter((a) => !a.inline) : [];

  // Вложение открыто своей деталкой: письмо остаётся «под» ней, возврат — кнопкой «назад».
  if (openEntry && renderFileDetail) {
    return createPortal(
      <div className="mviewer mailinfile">{renderFileDetail(openEntry, () => setOpenEntry(null))}</div>,
      document.body,
    );
  }

  // Портал в body по той же причине, что в «Медиа»: модалка перекрывает всё и не должна
  // наследовать вёрстку раздела (иначе её обрежут overflow'ы родителя).
  return createPortal(
    <div className="mviewer mailviewer">
      <div className="mv-head">
        <span className="mv-item mv-date" title="Дата письма">
          {msg ? fullDate(msg.sortAt) : ''}
        </span>
        {!inTrash && onReply && msg && (
          <>
            <button className="iconbtn" title="Ответить" onClick={() => onReply('reply', msg.id)}>
              <Reply size={18} />
            </button>
            <button className="iconbtn" title="Ответить всем" onClick={() => onReply('replyAll', msg.id)}>
              <ReplyAll size={18} />
            </button>
            <button className="iconbtn" title="Переслать" onClick={() => onReply('forward', msg.id)}>
              <Forward size={18} />
            </button>
          </>
        )}
        {msg && (
          <a className="iconbtn" title="Скачать письмо файлом (.eml)" href={`/api/v1/mail/messages/${msg.id}/raw`} download>
            <Download size={18} />
          </a>
        )}
        {msg && inTrash ? (
          <>
            <button className="iconbtn" title="Восстановить" disabled={busy} onClick={() => void restore()}>
              <RotateCcw size={18} />
            </button>
            <button className="iconbtn" title="Удалить навсегда" disabled={busy} onClick={() => void purgeForever()}>
              <Trash2 size={18} />
            </button>
          </>
        ) : (
          <button className="iconbtn" title="Удалить (в корзину)" disabled={busy || !msg} onClick={() => void remove()}>
            <Trash2 size={18} />
          </button>
        )}
        <button className="iconbtn" title="Закрыть" onClick={onClose}>
          <X size={18} />
        </button>
      </div>

      <div className="mailread">
        {error && <div className="err" style={{ margin: '8px 0' }}>{error}</div>}
        {!msg && !error && (
          <div className="mv-load"><span className="spin" /></div>
        )}
        {msg && (
          <>
            <div className="mailhead-block">
              <div className="mailsubject">{msg.subject || '(без темы)'}</div>
              <div className="mailaddr mailfromrow">
                <SenderAvatar name={msg.fromName} addr={msg.fromAddr} />
                <span className="mailfrom">{msg.fromName || msg.fromAddr || 'без отправителя'}</span>
                {msg.fromName && msg.fromAddr && <span className="mailaddr-v">&lt;{msg.fromAddr}&gt;</span>}
              </div>
              <div className="mailaddr">
                <span className="mailaddr-k">кому</span>
                <span className="mailaddr-v">{[...msg.toAddrs, ...msg.ccAddrs].join(', ') || '—'}</span>
              </div>
              <div className="mailaddr">
                <span className="mailaddr-k">аккаунт</span>
                <span className="mailaddr-v">{msg.accountEmail}</span>
              </div>
            </div>

            <div className="mailbody">
              {!body && <div className="mv-load"><span className="spin" /></div>}
              {body && (
                <iframe
                  className="mailframe"
                  title="Письмо"
                  // allow-same-origin нет намеренно: без него iframe получает непрозрачный origin
                  // и не может тронуть cookie/локальное хранилище нашего домена, даже если сюда
                  // когда-нибудь добавят allow-scripts. Вложения в теле — data:-URI (self-contained),
                  // а внешние ссылки абсолютные, поэтому same-origin телу не нужен.
                  // allow-popups — чтобы переход по ссылке из письма открывал новую вкладку.
                  sandbox="allow-popups"
                  referrerPolicy="no-referrer"
                  srcDoc={body.html}
                />
              )}
            </div>

            {files.length > 0 && (
              <div className="mailfiles">
                <div className="mailfiles-title"><Paperclip size={14} /> вложения ({files.length})</div>
                {files.map((a) => (
                  <div className="item" key={a.id}>
                    <span className="icon"><Paperclip /></span>
                    <span className="fname">{a.name}</span>
                    <span className="meta">{fmtSize(a.size)} · {a.mime}</span>
                    {renderFileDetail && (
                      <button className="btn ghost" title="Открыть файл" onClick={() => setOpenEntry(a.entryId)}>
                        <FileSearch size={16} />
                      </button>
                    )}
                    <a className="btn ghost" title="Скачать" href={api.fileUrl(a.entryId)} download>
                      <Download size={16} />
                    </a>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </div>,
    document.body,
  );
}

// =============================== Форма письма ===============================

/** Черновик лежит в localStorage: наполовину написанное письмо должно пережить перезагрузку. */
const DRAFT_KEY = 'cloudlyru:mail:draft';

export interface MailDraft {
  accountId: string;
  to: string;
  cc: string;
  subject: string;
  text: string;
  inReplyToId: string | null;
  attachments: Array<{ entryId: string; filename: string; size: number }>;
  updatedAt: string;
}

function readDraft(): MailDraft | null {
  try {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return null;
    const d = JSON.parse(raw) as MailDraft;
    return d && typeof d.text === 'string' ? d : null;
  } catch {
    return null;
  }
}

function writeDraft(draft: MailDraft | null): void {
  try {
    if (!draft) localStorage.removeItem(DRAFT_KEY);
    else localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
  } catch {
    /* приватный режим — черновик просто не сохранится */
  }
}

/**
 * Письмо, которое пишут: новое, ответ или пересылка.
 *
 * Отправляет сервер (SMTP аккаунта), а копию сохраняет у нас же — поэтому в «Исходящих»
 * письмо появляется сразу после отправки, не дожидаясь синхронизации с сервером.
 */
export function MailComposer({
  accounts,
  initial,
  onClose,
  onSent,
}: {
  accounts: api.MailAccountRow[];
  /** Заготовка: ответ, пересылка или продолжение черновика. */
  initial: Partial<MailDraft> | null;
  onClose: () => void;
  onSent: (id: string) => void;
}) {
  const draft = useMemo(() => {
    const saved = readDraft();
    // Заготовка важнее черновика: если человек нажал «ответить», он ждёт ответ;
    // черновик подставляем, только когда контекста нет вовсе.
    if (initial) return initial;
    return saved ?? null;
  }, [initial]);

  const [accountId, setAccountId] = useState(
    draft?.accountId || accounts.find((a) => a.enabled)?.id || accounts[0]?.id || '',
  );
  const [to, setTo] = useState(draft?.to ?? '');
  const [cc, setCc] = useState(draft?.cc ?? '');
  const [subject, setSubject] = useState(draft?.subject ?? '');
  const [text, setText] = useState(draft?.text ?? '');
  const [attachments, setAttachments] = useState(draft?.attachments ?? []);
  const [ccOpen, setCcOpen] = useState(Boolean(draft?.cc));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  // Черновик пишем с задержкой: на каждый символ в localStorage — лишняя работа.
  // А при закрытии формы — немедленно: иначе написанное и сразу закрытое письмо терялось бы
  // (дебаунс не успевал сработать, а таймер снимался вместе с компонентом).
  const currentDraft = (): MailDraft | null => {
    const empty = !to.trim() && !subject.trim() && !text.trim() && !attachments.length;
    return empty
      ? null
      : {
          accountId,
          to,
          cc,
          subject,
          text,
          inReplyToId: draft?.inReplyToId ?? null,
          attachments,
          updatedAt: new Date().toISOString(),
        };
  };
  const draftRef = useRef<() => MailDraft | null>(currentDraft);
  draftRef.current = currentDraft;

  useEffect(() => {
    const t = window.setTimeout(() => writeDraft(draftRef.current()), 600);
    return () => window.clearTimeout(t);
  }, [accountId, to, cc, subject, text, attachments, draft?.inReplyToId]);

  useEffect(() => () => writeDraft(draftRef.current()), []);

  // Escape закрывает форму (черновик сохраняется при размонтировании).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const send = async () => {
    setBusy(true);
    setError('');
    try {
      const res = await api.mailSend({
        accountId,
        to,
        cc,
        subject,
        text,
        inReplyToId: draft?.inReplyToId ?? null,
        attachEntryIds: attachments.map((a) => a.entryId),
      });
      writeDraft(null);
      if (res.rejected.length) {
        setNotice(`не приняты адреса: ${res.rejected.join(', ')}`);
        setBusy(false);
        return;
      }
      onSent(res.id);
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  };

  return createPortal(
    <div className="mviewer mailcompose">
      <div className="mv-head">
        <span className="mv-item mv-date">Письмо</span>
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Закрыть (черновик останется)" onClick={onClose}>
          <X size={18} />
        </button>
      </div>
      <div className="mailread">
        <div className="mailform">
          {accounts.length > 1 && (
            <label className="mailfield">
              <span className="mailfield-k">откуда</span>
              <select value={accountId} onChange={(e) => setAccountId(e.target.value)}>
                {accounts.filter((a) => a.enabled).map((a) => (
                  <option key={a.id} value={a.id}>{a.email}</option>
                ))}
              </select>
            </label>
          )}
          <label className="mailfield">
            <span className="mailfield-k">кому</span>
            <input value={to} onChange={(e) => setTo(e.target.value)} placeholder="адрес@пример.ру" autoComplete="off" />
          </label>
          {ccOpen ? (
            <label className="mailfield">
              <span className="mailfield-k">копия</span>
              <input value={cc} onChange={(e) => setCc(e.target.value)} placeholder="необязательно" autoComplete="off" />
            </label>
          ) : (
            <button className="btn ghost mailaddcc" onClick={() => setCcOpen(true)}>+ копия</button>
          )}
          <label className="mailfield">
            <span className="mailfield-k">тема</span>
            <input value={subject} onChange={(e) => setSubject(e.target.value)} placeholder="тема письма" />
          </label>
          <textarea
            className="mailtext"
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="текст письма"
            rows={12}
          />
          {attachments.length > 0 && (
            <div className="mailfiles">
              <div className="mailfiles-title"><Paperclip size={14} /> вложения ({attachments.length})</div>
              {attachments.map((a) => (
                <div className="item" key={a.entryId}>
                  <span className="icon"><Paperclip /></span>
                  <span className="fname">{a.filename}</span>
                  <span className="meta">{fmtSize(a.size)}</span>
                  <button
                    className="btn ghost"
                    title="Убрать из письма"
                    onClick={() => setAttachments((prev) => prev.filter((x) => x.entryId !== a.entryId))}
                  >
                    <X size={16} />
                  </button>
                </div>
              ))}
            </div>
          )}
          {error && <div className="err">{error}</div>}
          {notice && <div className="notice">{notice}</div>}
          <div className="row">
            <button className="btn" onClick={() => void send()} disabled={busy || !to.trim() || !accountId}>
              {busy ? 'Отправляем…' : 'Отправить'}
            </button>
            <span className="copy">Черновик сохраняется сам</span>
          </div>
        </div>
      </div>
    </div>,
    document.body,
  );
}
