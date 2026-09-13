import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { ArrowDownToLine, Film, Image as ImageIcon, Info, MapPin, Trash, X } from 'lucide-react';
import * as api from './api';
import { patchUi, readUi } from './storage';

/**
 * Раздел «Медиа» — изолированная от «Фото»/«Видео» поверхность просмотра.
 *
 * Таймлайн: виртуализированная сетка 50×50 (ровно превью сервера). С бэка берём только
 * общее число элементов (`/media/count`), считаем полную высоту скролла, а сами элементы
 * запрашиваем по диапазону индексов (`/media/range?offset&limit`) после остановки скролла
 * (дебаунс) — поэтому скроллбар полной высоты сразу, а сеть ходит только за видимой частью.
 * В липкой шапке-острове — месяц и год того снимка, что сейчас под верхом прокрутки.
 *
 * Модалка: 3 блока (шапка/фото/футер), плавное появление-затухание, зум щипком и дабл-тапом,
 * листание свайпом пальцем и на трекпаде. «Вперёд/назад» — чисто клиентское (индекс ± 1),
 * сеть нужна только за 1080-превью текущего кадра.
 */

type MediaItem = api.MediaItem;

/** Размер клетки и зазоры сетки: превью сервер отдаёт ровно 50×50, поэтому клетка = 50. */
const CELL = 50;
const GAP = 3;
const ROW = CELL + GAP;
/** Сколько строк вне экрана держим смонтированными (запас на быстрый скролл). */
const OVERSCAN = 3;
/** Дебаунс запроса видимой части после остановки скролла. */
const FETCH_DEBOUNCE_MS = 500;
/** Сколько элементов просим одним запросом range. */
const FETCH_CHUNK = 500;
/** Как часто переспрашиваем статусы неготовых превью. */
const STATUS_POLL_MS = 4000;
/** Сколько держать палец на ползунке, прежде чем он станет таскабельным. */
const ARM_MS = 1000;
/** Сдвиг до активации, после которого удержание отменяется (случайный свайп). */
const ARM_MOVE_SLOP = 8;

const MONTHS = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];

function monthLabel(key: string): string {
  const [y, m] = key.split('-');
  return `${MONTHS[Number(m) - 1] ?? key} ${y}`;
}

/** Дата снимка «красивым» текстом, по wall-clock из файла (без пересчёта в пояс браузера). */
function fmtMediaDate(iso?: string | null): string {
  if (!iso) return '';
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
  if (!m) return iso;
  const [, y, mo, d, h, mi] = m;
  return `${d}.${mo}.${y.slice(2)} ${h}:${mi}`;
}

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

function fitGeom(cw: number, ch: number, nw: number, nh: number) {
  const fit = Math.min(cw / nw, ch / nh);
  const bw = nw * fit;
  const bh = nh * fit;
  return { cw, ch, ox: (cw - bw) / 2, oy: (ch - bh) / 2, bw, bh };
}

/** Бинарный поиск месяца по абсолютному индексу элемента в ленте (кумулятивные отрезки). */
function findBucket(
  cum: Array<{ month: string | null; start: number; end: number }> | null,
  index: number,
): { month: string | null } | undefined {
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

// =============================== Таймлайн ===============================

export default function MediaSection({ onOverlayChange }: {
  /** Модалка открыта/закрыта — Shell прячет общий футер, чтобы он не наезжал на футер модалки. */
  onOverlayChange?: (open: boolean) => void;
}) {
  const [total, setTotal] = useState<number | null>(null);
  const [months, setMonths] = useState<Array<{ month: string | null; count: number }> | null>(null);
  const [items, setItems] = useState<Map<number, MediaItem>>(() => new Map());
  const [error, setError] = useState('');
  const [openIdx, setOpenIdx] = useState<number | null>(null);
  const [scrub, setScrub] = useState<{ top: number; h: number; monthKey: string | null | undefined }>({ top: 0, h: 24, monthKey: undefined });
  const [scrubVisible, setScrubVisible] = useState(false);
  /** Ползунок: idle — обычный, arming — палец удерживается (идёт отсчёт), armed — можно таскать. */
  const [scrubState, setScrubState] = useState<'idle' | 'arming' | 'armed'>('idle');
  /** Позиция ленты из localStorage, сохранённая в прошлый раз (читаем один раз при входе). */
  const [savedMedia] = useState(() => readUi().media);

  useEffect(() => {
    onOverlayChange?.(openIdx != null);
  }, [openIdx, onOverlayChange]);

  const scrollRef = useRef<HTMLDivElement>(null);
  const totalRef = useRef<number | null>(null);
  totalRef.current = total;
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const seqRef = useRef(0);
  const debounceRef = useRef<number | null>(null);
  const rafRef = useRef(0);
  const hideTimer = useRef<number | null>(null);
  /** Ползунок активирован удержанием: true — сейчас можно тянуть (скраб следует за пальцем). */
  const armedRef = useRef(false);
  const holdStartRef = useRef(0);
  const holdTimerRef = useRef<number | null>(null);
  const railRef = useRef<HTMLDivElement>(null);
  /** Восстановление позиции уже отработало (или сохранять было нечего). */
  const restoredRef = useRef(false);
  const persistTimer = useRef<number | null>(null);
  const openIdxRef = useRef<number | null>(null);
  openIdxRef.current = openIdx;

  const [cols, setCols] = useState(1);
  const colsRef = useRef(1);
  colsRef.current = cols;
  const [viewport, setViewport] = useState({ w: 0, h: 0 });
  const [range, setRange] = useState<[number, number]>([0, OVERSCAN]);
  const [month, setMonth] = useState('');

  // Общее число элементов — один раз при входе в раздел.
  useEffect(() => {
    let stopped = false;
    api.mediaCount()
      .then((n) => {
        if (stopped) return;
        setTotal(n);
        totalRef.current = n;
      })
      .catch((e) => {
        if (!stopped) setError((e as Error).message);
      });
    return () => {
      stopped = true;
    };
  }, []);

  // Индекс по месяцам — для точной подписи у ползунка (грузится параллельно с count).
  useEffect(() => {
    let stopped = false;
    api.mediaMonths()
      .then((m) => {
        if (!stopped) setMonths(m);
      })
      .catch(() => undefined);
    return () => {
      stopped = true;
    };
  }, []);

  // Измеряем скролл-контейнер: от ширины зависит число колонок.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      setViewport({ w, h: el.clientHeight });
      setCols(Math.max(1, Math.floor((w + GAP) / ROW)));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const rowCount = total == null ? 0 : Math.ceil(total / cols);
  const totalH = Math.max(0, rowCount * ROW - GAP);

  const getItem = useCallback((i: number) => itemsRef.current.get(i), []);

  /** Догрузить диапазон индексов [start, end] включительно (только отсутствующие куски). */
  const fetchRange = useCallback(async (start: number, end: number) => {
    const t = totalRef.current;
    if (t == null) return;
    start = Math.max(0, start);
    end = Math.min(t - 1, end);
    if (start > end) return;
    const map = itemsRef.current;
    // собираем непрерывные куски ещё не загруженных индексов
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
          const page = await api.mediaRange(off, len);
          if (seq !== seqRef.current) return; // индекс сдвинули (удаление) — данные устарели
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
  }, []);

  // Статусы неготовых снимков: переспрашиваем, чтобы «в обработке» со временем становилось фото.
  useEffect(() => {
    const map = itemsRef.current;
    const notReady: Array<{ idx: number; id: string }> = [];
    for (const [idx, it] of map) {
      if (it.previewState !== 'done') notReady.push({ idx, id: it.entryId });
    }
    if (!notReady.length) return;
    let stopped = false;
    const tick = async () => {
      try {
        const rows = await api.mediaStatus(notReady.map((n) => n.id));
        if (stopped || !rows.length) return;
        const byId = new Map(rows.map((r) => [r.entryId, r]));
        setItems((prev) => {
          let changed = false;
          const next = new Map(prev);
          for (const { idx, id } of notReady) {
            const row = byId.get(id);
            if (!row) continue;
            const cur = next.get(idx);
            if (cur && (cur.previewState !== row.previewState || cur.jobState !== row.jobState)) {
              next.set(idx, { ...cur, previewState: row.previewState, jobState: row.jobState });
              changed = true;
            }
          }
          return changed ? next : prev;
        });
      } catch {
        /* следующий тик попробует снова */
      }
    };
    void tick();
    const t = window.setInterval(() => void tick(), STATUS_POLL_MS);
    return () => {
      stopped = true;
      window.clearInterval(t);
    };
  }, [items]);

  const updateRange = useCallback(
    (top: number) => {
      const vh = viewport.h || 600;
      const start = Math.max(0, Math.floor(top / ROW) - OVERSCAN);
      const end = Math.min(rowCount - 1, Math.ceil((top + vh) / ROW) + OVERSCAN);
      setRange((prev) => (prev[0] === start && prev[1] === end ? prev : [start, end]));
    },
    [viewport.h, rowCount],
  );

  /** Запрос видимой части — только после остановки скролла (дебаунс). */
  const scheduleFetch = useCallback(() => {
    if (debounceRef.current != null) window.clearTimeout(debounceRef.current);
    debounceRef.current = window.setTimeout(() => {
      debounceRef.current = null;
      const el = scrollRef.current;
      const t = totalRef.current;
      if (!el || t == null) return;
      const c = colsRef.current;
      const top = el.scrollTop;
      const vh = el.clientHeight || 600;
      const firstRow = Math.max(0, Math.floor(top / ROW) - OVERSCAN);
      const lastRow = Math.min(Math.ceil(t / c) - 1, Math.ceil((top + vh) / ROW) + OVERSCAN);
      if (lastRow < 0) return;
      const iStart = firstRow * c;
      const iEnd = Math.min(t - 1, (lastRow + 1) * c - 1);
      if (iStart <= iEnd) void fetchRange(iStart, iEnd);
    }, FETCH_DEBOUNCE_MS);
  }, [fetchRange]);

  // Кумулятивные отрезки месяцев в порядке ленты: по индексу элемента — его месяц.
  const monthCum = useMemo(() => {
    if (!months) return null;
    const arr: Array<{ month: string | null; start: number; end: number }> = [];
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

  /** Геометрия ползунка и месяц в текущей позиции скролла. */
  const updateScrub = useCallback((top: number) => {
    const el = scrollRef.current;
    if (!el) return;
    const sh = el.scrollHeight;
    const ch = el.clientHeight;
    const h = Math.max(24, (ch / Math.max(sh, 1)) * ch);
    const maxScroll = sh - ch;
    const t = maxScroll > 0 ? (top / maxScroll) * (ch - h) : 0;
    const firstRow = Math.max(0, Math.floor(top / ROW));
    const b = findBucket(monthCumRef.current, firstRow * colsRef.current);
    const monthKey = b ? b.month : undefined;
    setScrub((s) => (s.top === t && s.h === h && s.monthKey === monthKey ? s : { top: t, h, monthKey }));
  }, []);

  /** Записать позицию ленты (top) и открытый кадр в localStorage с дебаунсом.
      Значения захватываются в момент вызова — таймер не читает DOM после размонтирования. */
  const persistMedia = useCallback((top: number) => {
    if (persistTimer.current != null) window.clearTimeout(persistTimer.current);
    const index = Math.max(0, Math.floor(top / ROW)) * colsRef.current;
    const open = openIdxRef.current;
    persistTimer.current = window.setTimeout(() => {
      persistTimer.current = null;
      patchUi({ media: { index, scrollTop: top, openIdx: open } });
    }, 400);
  }, []);

  const onScroll = useCallback(() => {
    if (rafRef.current) return;
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = 0;
      const el = scrollRef.current;
      if (!el) return;
      const top = el.scrollTop;
      updateRange(top);
      scheduleFetch();
      updateScrub(top);
      setScrubVisible(true);
      if (hideTimer.current != null) window.clearTimeout(hideTimer.current);
      hideTimer.current = window.setTimeout(() => setScrubVisible(false), 1000);
      persistMedia(top);
    });
  }, [updateRange, scheduleFetch, updateScrub, persistMedia]);

  // Первый экран — сразу после того, как узнали общее число и ширину. Если позиция была
  // сохранена в прошлый раз, возвращаемся к ней (и к открытому кадру модалки).
  useLayoutEffect(() => {
    if (total == null || total === 0) return;
    const el = scrollRef.current;
    if (!el) return;
    const c = cols;
    let top = 0;
    let open: number | null = null;
    if (!restoredRef.current) {
      restoredRef.current = true;
      if (savedMedia) {
        const oi = typeof savedMedia.openIdx === 'number' ? clamp(savedMedia.openIdx, 0, total - 1) : null;
        const base = oi ?? (savedMedia.index ?? 0);
        const row = Math.max(0, Math.floor(base / c));
        top = Math.min(row * ROW, Math.max(0, el.scrollHeight - el.clientHeight));
        if (oi != null) open = oi;
      }
    }
    if (top > 0) el.scrollTop = top;
    if (open != null) setOpenIdx(open);
    const vh = el.clientHeight || 600;
    const firstRow = Math.max(0, Math.floor(top / ROW) - OVERSCAN);
    const lastRow = Math.min(Math.ceil(total / c) - 1, Math.ceil((top + vh) / ROW) + OVERSCAN);
    const iStart = firstRow * c;
    const iEnd = Math.min(total - 1, (lastRow + 1) * c - 1);
    if (iStart <= iEnd) void fetchRange(iStart, iEnd);
    updateRange(top);
  }, [total, cols, fetchRange, updateRange, savedMedia]);

  // Открыли/закрыли модалку — сохраняем кадр сразу (скролл при этом не обязательно двигался).
  useEffect(() => {
    if (!restoredRef.current) return;
    persistMedia(scrollRef.current?.scrollTop ?? 0);
  }, [openIdx, persistMedia]);

  // Месяц в шапке — от первого видимого снимка; обновляется, когда пришёл новый кусок.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const firstRow = Math.max(0, Math.floor(el.scrollTop / ROW));
    const item = itemsRef.current.get(firstRow * colsRef.current);
    const key = item?.capturedAt?.slice(0, 7) ?? '';
    setMonth((m) => (m === key ? m : key));
  }, [items, cols]);

  // Подпись у ползунка готова, когда пришёл индекс по месяцам.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el) updateScrub(el.scrollTop);
  }, [months, updateScrub]);

  const rows = useMemo(() => {
    const out: Array<{ y: number; start: number; cells: Array<MediaItem | undefined> }> = [];
    if (total == null) return out;
    for (let r = range[0]; r <= range[1] && r >= 0; r++) {
      const start = r * cols;
      if (start >= total) break;
      const count = Math.min(cols, total - start);
      const cells: Array<MediaItem | undefined> = [];
      for (let ci = 0; ci < count; ci++) cells.push(items.get(start + ci));
      out.push({ y: r * ROW, start, cells });
    }
    return out;
  }, [range, items, cols, total]);

  const handleDelete = useCallback((index: number) => {
    seqRef.current++; // отменяем летящие загрузки — индексы сдвинулись
    setItems((prev) => {
      const next = new Map<number, MediaItem>();
      for (const [k, v] of prev) {
        if (k === index) continue;
        next.set(k > index ? k - 1 : k, v);
      }
      return next;
    });
    const nt = (totalRef.current ?? 1) - 1;
    totalRef.current = nt;
    setTotal(nt);
    setOpenIdx(nt <= 0 ? null : Math.min(index, nt - 1));
  }, []);

  // Ползунок: перетаскивание только после удержания. Быстрый тап ничего не двигает —
  // он не должен случайно перелистывать ленту. Палец держится ARM_MS, ползунок
  // подсвечивается (arming), затем активируется (armed) и следует за пальцем.
  const scrubTo = (clientY: number) => {
    const el = scrollRef.current;
    const rail = railRef.current;
    if (!el || !rail) return;
    const rect = rail.getBoundingClientRect();
    const y = clientY - rect.top;
    const sh = el.scrollHeight;
    const ch = el.clientHeight;
    const h = Math.max(24, (ch / Math.max(sh, 1)) * ch);
    const maxTop = ch - h;
    const maxScroll = sh - ch;
    const frac = maxTop > 0 ? clamp(y - h / 2, 0, maxTop) / maxTop : 0;
    el.scrollTop = frac * maxScroll;
  };
  const cancelHold = () => {
    if (holdTimerRef.current != null) {
      window.clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
  };
  const onRailPointerDown = (e: React.PointerEvent) => {
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    setScrubVisible(true);
    cancelHold();
    armedRef.current = false;
    holdStartRef.current = e.clientY;
    setScrubState('arming');
    holdTimerRef.current = window.setTimeout(() => {
      holdTimerRef.current = null;
      armedRef.current = true;
      setScrubState('armed');
      scrubTo(e.clientY);
    }, ARM_MS);
  };
  const onRailPointerMove = (e: React.PointerEvent) => {
    if (armedRef.current) {
      scrubTo(e.clientY);
      return;
    }
    // до активации заметный сдвиг отменяет удержание — случайный свайп не срабатывает
    if (holdTimerRef.current != null && Math.abs(e.clientY - holdStartRef.current) > ARM_MOVE_SLOP) {
      cancelHold();
      setScrubState('idle');
    }
  };
  const onRailPointerUp = () => {
    cancelHold();
    armedRef.current = false;
    setScrubState('idle');
  };

  const scrubLabel = scrub.monthKey === undefined ? '' : scrub.monthKey === null ? 'Без даты' : monthLabel(scrub.monthKey);
  const labelTop = clamp(scrub.top + scrub.h / 2, 12, Math.max(12, viewport.h - 12));

  return (
    <div className={'media' + (openIdx != null ? ' has-viewer' : '')}>
      <div className="mhead">
        <span className="mmonth">{month ? monthLabel(month) : 'Медиа'}</span>
      </div>
      <div className="mscroll-wrap">
        <div className="mscroll" ref={scrollRef} onScroll={onScroll}>
          {error && <div className="err" style={{ padding: '8px 4px' }}>{error}</div>}
          {total == null && !error && (
            <div className="mskel">
              {Array.from({ length: cols * Math.max(2, Math.ceil((viewport.h || 600) / ROW) + OVERSCAN) }).map((_, i) => (
                <div className="mcell" key={i}><span className="mcell-skel" /></div>
              ))}
            </div>
          )}
          {total === 0 && !error && (
            <div className="mempty">
              <span className="copy">Здесь появятся фото и видео из раздела «Фото»</span>
            </div>
          )}
          {total != null && total > 0 && (
            <div className="mvirt" style={{ height: totalH }}>
              {rows.map((row) => (
                <div className="mrow" key={row.start} style={{ transform: `translateY(${row.y}px)` }}>
                  {row.cells.map((it, ci) => (
                    <Cell key={row.start + ci} item={it} onClick={() => it && setOpenIdx(row.start + ci)} />
                  ))}
                </div>
              ))}
            </div>
          )}
        </div>
        {openIdx == null && total != null && total > 0 && (
          <div
            className={
              'mrail' +
              (scrubVisible ? ' visible' : '') +
              (scrubState === 'arming' ? ' arming' : scrubState === 'armed' ? ' armed' : '')
            }
            ref={railRef}
            onPointerDown={onRailPointerDown}
            onPointerMove={onRailPointerMove}
            onPointerUp={onRailPointerUp}
            onPointerCancel={onRailPointerUp}
            onPointerEnter={() => {
              setScrubVisible(true);
              if (hideTimer.current != null) window.clearTimeout(hideTimer.current);
            }}
            onPointerLeave={() => {
              if (armedRef.current || holdTimerRef.current != null) return;
              if (hideTimer.current != null) window.clearTimeout(hideTimer.current);
              hideTimer.current = window.setTimeout(() => setScrubVisible(false), 600);
            }}
          >
            <div className="mthumb" style={{ top: scrub.top, height: scrub.h }} />
            {scrubVisible && scrubLabel && (
              <div className="mthumb-label" style={{ top: labelTop }} aria-hidden>
                {scrubLabel}
              </div>
            )}
          </div>
        )}
      </div>

      {openIdx != null && total != null && total > 0 && (
        <MediaViewer
          total={total}
          idx={openIdx}
          getItem={getItem}
          ensure={fetchRange}
          onNavigate={setOpenIdx}
          onClose={() => setOpenIdx(null)}
          onDelete={handleDelete}
        />
      )}
    </div>
  );
}

function Cell({ item, onClick }: { item: MediaItem | undefined; onClick: () => void }) {
  const [failed, setFailed] = useState(false);
  if (!item) {
    // ещё не загруженный элемент — просто мерцающий скелетон
    return (
      <div className="mcell">
        <span className="mcell-skel" />
      </div>
    );
  }
  const ready = item.previewState === 'done' && !!item.sha256;
  const video = /^video\//.test(item.mime);
  const Icon = video ? Film : ImageIcon;

  if (!ready) {
    return (
      <button
        type="button"
        className="mcell off"
        disabled
        onClick={onClick}
        title="Превью не собрано"
        aria-label="Превью не собрано"
      >
        <span className="mcell-ico"><Icon size={22} /></span>
      </button>
    );
  }

  return (
    <button
      type="button"
      className={'mcell' + (video ? ' video' : '')}
      onClick={onClick}
      title={item.name}
      aria-label={item.name}
    >
      {!failed && <span className="mcell-skel" />}
      {failed ? (
        <span className="mcell-ico"><Icon size={22} /></span>
      ) : (
        <img src={api.previewUrl(item.sha256!)} alt="" loading="lazy" decoding="async" draggable={false} onError={() => setFailed(true)} />
      )}
    </button>
  );
}

// =============================== Модалка ===============================

type ZoomState = { scale: number; tx: number; ty: number };

function MediaViewer({
  total,
  idx,
  getItem,
  ensure,
  onNavigate,
  onClose,
  onDelete,
}: {
  total: number;
  idx: number;
  getItem: (i: number) => MediaItem | undefined;
  ensure: (start: number, end: number) => void;
  onNavigate: (idx: number) => void;
  onClose: () => void;
  onDelete: (index: number) => void;
}) {
  const [pos, setPos] = useState(idx);
  const [dragging, setDragging] = useState(false);
  const [zoom, setZoom] = useState<ZoomState>({ scale: 1, tx: 0, ty: 0 });
  /** Натуральные размеры по индексу кадра: сосед, загруженный заранее, не теряет размер. */
  const [natMap, setNatMap] = useState<Map<number, { w: number; h: number }>>(() => new Map());
  const [stage, setStage] = useState({ w: 0, h: 0 });
  const [closing, setClosing] = useState(false);
  const [detail, setDetail] = useState(false);

  const stageRef = useRef<HTMLDivElement>(null);

  const posRef = useRef(pos);
  posRef.current = pos;
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const fitRef = useRef<ReturnType<typeof fitGeom> | null>(null);

  const g = useRef({
    mode: 'idle' as 'idle' | 'nav' | 'pan' | 'pinch',
    pointers: new Map<number, { x: number; y: number }>(),
    startX: 0,
    startY: 0,
    startPos: 0,
    startZoom: { scale: 1, tx: 0, ty: 0 } as ZoomState,
    pinch: { d0: 1, z0: 1, ix: 0, iy: 0 },
    lastX: 0,
    lastT: 0,
    velX: 0,
  });
  const lastTap = useRef({ t: 0, x: 0, y: 0 });
  const wheelTimer = useRef<number | null>(null);

  const k = clamp(Math.round(pos), 0, total - 1);
  const curItem = getItem(k);
  const curNat = natMap.get(k);
  fitRef.current = curNat && stage.w > 0 ? fitGeom(stage.w, stage.h, curNat.w, curNat.h) : null;

  // Позиция догоняет индекс после снапа/навигации кнопками/удаления.
  useEffect(() => {
    setPos(idx);
  }, [idx]);

  // Новый кадр — сбрасываем зум (натуральный размер соседа уже лежит в natMap).
  useEffect(() => {
    setZoom({ scale: 1, tx: 0, ty: 0 });
    setDetail(false);
  }, [k]);

  // Догружаем текущий кадр и соседей, чтобы свайп не упирался в пустоту.
  useEffect(() => {
    ensure(Math.max(0, k - 1), Math.min(total - 1, k + 1));
  }, [k, total, ensure]);

  const recordNat = useCallback((i: number, s: { w: number; h: number }) => {
    setNatMap((prev) => {
      const cur = prev.get(i);
      if (cur && cur.w === s.w && cur.h === s.h) return prev;
      const next = new Map(prev);
      next.set(i, s);
      return next;
    });
  }, []);

  const commitZoom = useCallback((z: number, tx: number, ty: number) => {
    const fit = fitRef.current;
    if (!fit) return;
    z = clamp(z, 1, 8);
    const w = fit.bw * z;
    const h = fit.bh * z;
    if (w >= fit.cw) tx = clamp(tx, fit.cw - w - fit.ox, -fit.ox);
    else tx = (fit.cw - w) / 2 - fit.ox;
    if (h >= fit.ch) ty = clamp(ty, fit.ch - h - fit.oy, -fit.oy);
    else ty = (fit.ch - h) / 2 - fit.oy;
    if (z <= 1.001) {
      z = 1;
      tx = 0;
      ty = 0;
    }
    setZoom({ scale: z, tx, ty });
  }, []);

  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const closingRef = useRef(false);
  const close = useCallback(() => {
    if (closingRef.current) return;
    closingRef.current = true;
    setClosing(true);
    // страховка: если transitionend не пришёл (reduced motion / скрытая вкладка) — всё равно закроем
    window.setTimeout(() => onCloseRef.current(), 260);
  }, []);
  const onRootTransitionEnd = (e: React.TransitionEvent) => {
    if (closingRef.current && e.target === e.currentTarget && e.propertyName === 'opacity') onCloseRef.current();
  };

  const go = useCallback(
    (delta: number) => {
      const t = clamp(Math.round(posRef.current) + delta, 0, total - 1);
      setDragging(false);
      setPos(t);
      onNavigate(t);
    },
    [total, onNavigate],
  );

  // Клавиатура: Esc — закрыть, ←/→ — листание (на десктопе вместо свайпа).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (detail) setDetail(false);
        else close();
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        go(1);
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        go(-1);
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [detail, go, close]);

  const onPointerDown = (e: React.PointerEvent) => {
    if (closing || detail) return;
    const el = stageRef.current;
    if (!el) return;
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    const gp = g.current;
    gp.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const n = gp.pointers.size;
    if (n === 1) {
      const now = performance.now();
      const lt = lastTap.current;
      const near = lt.t > 0 && now - lt.t < 320 && Math.hypot(e.clientX - lt.x, e.clientY - lt.y) < 24;
      if (near) {
        lastTap.current = { t: 0, x: 0, y: 0 };
        const z = zoomRef.current;
        const fit = fitRef.current;
        if (z.scale > 1) commitZoom(1, 0, 0);
        else if (fit) commitZoom(2.5, (fit.bw * (1 - 2.5)) / 2, (fit.bh * (1 - 2.5)) / 2);
        gp.mode = 'idle';
        return;
      }
      lastTap.current = { t: now, x: e.clientX, y: e.clientY };
      const z = zoomRef.current;
      gp.mode = z.scale > 1.001 ? 'pan' : 'nav';
      gp.startX = e.clientX;
      gp.startY = e.clientY;
      gp.startPos = posRef.current;
      gp.startZoom = z;
      gp.lastX = e.clientX;
      gp.lastT = now;
      gp.velX = 0;
      setDragging(true);
    } else if (n === 2) {
      const [a, b] = [...gp.pointers.values()];
      const rect = el.getBoundingClientRect();
      const fit = fitRef.current;
      const z = zoomRef.current;
      const cx = (a.x + b.x) / 2 - rect.left;
      const cy = (a.y + b.y) / 2 - rect.top;
      gp.mode = 'pinch';
      gp.pinch = {
        d0: Math.hypot(a.x - b.x, a.y - b.y) || 1,
        z0: z.scale,
        ix: fit ? (cx - (fit.ox + z.tx)) / z.scale : 0,
        iy: fit ? (cy - (fit.oy + z.ty)) / z.scale : 0,
      };
      setDragging(true);
    }
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const gp = g.current;
    if (!gp.pointers.has(e.pointerId)) return;
    gp.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const n = gp.pointers.size;
    const el = stageRef.current;
    if (gp.mode === 'nav' && n === 1) {
      if (!el) return;
      const w = el.clientWidth || 1;
      const np = clamp(gp.startPos - (e.clientX - gp.startX) / w, 0, total - 1);
      setPos(np);
      const now = performance.now();
      const dt = now - gp.lastT;
      if (dt > 0) {
        gp.velX = (e.clientX - gp.lastX) / dt;
        gp.lastX = e.clientX;
        gp.lastT = now;
      }
    } else if (gp.mode === 'pan' && n === 1) {
      const z = zoomRef.current;
      commitZoom(z.scale, gp.startZoom.tx + (e.clientX - gp.startX), gp.startZoom.ty + (e.clientY - gp.startY));
    } else if (gp.mode === 'pinch' && n === 2) {
      const [a, b] = [...gp.pointers.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y) || 1;
      const z = clamp(gp.pinch.z0 * (d / gp.pinch.d0), 1, 8);
      const fit = fitRef.current;
      if (!el || !fit) return;
      const rect = el.getBoundingClientRect();
      const cx = (a.x + b.x) / 2 - rect.left;
      const cy = (a.y + b.y) / 2 - rect.top;
      commitZoom(z, cx - fit.ox - gp.pinch.ix * z, cy - fit.oy - gp.pinch.iy * z);
    }
  };

  const endPointer = (e: React.PointerEvent) => {
    const gp = g.current;
    if (!gp.pointers.has(e.pointerId)) return;
    gp.pointers.delete(e.pointerId);
    const n = gp.pointers.size;
    if (gp.mode === 'nav' && n === 0) {
      const p = posRef.current;
      let target = Math.round(p);
      // флик: быстрое движение — на один кадр дальше по направлению
      if (Math.abs(gp.velX) > 0.6) target = gp.velX < 0 ? Math.ceil(p) : Math.floor(p);
      target = clamp(target, 0, total - 1);
      setDragging(false);
      setPos(target);
      onNavigate(target);
      gp.mode = 'idle';
    } else if (n === 0) {
      gp.mode = 'idle';
      setDragging(false);
    }
    // pinch, где остался один палец — не листаем и не панорамируем до нового касания
    if (n < 2 && gp.mode === 'pinch') gp.mode = 'idle';
  };

  // Трекпад: свайп по горизонтали — листание, ctrl+колесо — зум, при зуме колесо — пан.
  // Нативный слушатель (passive:false), иначе preventDefault не сработает.
  const wheelHandlerRef = useRef<(e: WheelEvent) => void>(() => {});
  wheelHandlerRef.current = (e: WheelEvent) => {
    if (closing || detail) return;
    e.preventDefault();
    const gp = g.current;
    const el = stageRef.current;
    if (!el) return;
    if (e.ctrlKey) {
      const fit = fitRef.current;
      if (!fit) return;
      const rect = el.getBoundingClientRect();
      const z = zoomRef.current;
      const nz = clamp(z.scale * Math.exp(-e.deltaY * 0.01), 1, 8);
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      const ix = (cx - (fit.ox + z.tx)) / z.scale;
      const iy = (cy - (fit.oy + z.ty)) / z.scale;
      commitZoom(nz, cx - fit.ox - ix * nz, cy - fit.oy - iy * nz);
    } else if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      const w = el.clientWidth || 1;
      setDragging(true);
      setPos((p) => clamp(p + e.deltaX / w, 0, total - 1));
      if (wheelTimer.current) window.clearTimeout(wheelTimer.current);
      wheelTimer.current = window.setTimeout(() => {
        if (closingRef.current) return;
        setDragging(false);
        const p = posRef.current;
        const t = clamp(Math.round(p), 0, total - 1);
        setPos(t);
        onNavigate(t);
      }, 110);
    } else if (zoomRef.current.scale > 1.001) {
      commitZoom(zoomRef.current.scale, zoomRef.current.tx - e.deltaX, zoomRef.current.ty - e.deltaY);
    }
  };
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const fn = (e: WheelEvent) => wheelHandlerRef.current(e);
    el.addEventListener('wheel', fn, { passive: false });
    return () => {
      el.removeEventListener('wheel', fn);
      if (wheelTimer.current) window.clearTimeout(wheelTimer.current);
    };
  }, []);

  // Слайды: текущий + соседи по ленте. Трансформ — (индекс − pos) в процентах ширины:
  // непрерывен и при свайпе, и при смене «текущего» на середине.
  const slides: Array<{ i: number; item: MediaItem | undefined }> = [];
  for (let i = k - 1; i <= k + 1; i++) {
    if (i < 0 || i >= total) continue;
    slides.push({ i, item: getItem(i) });
  }

  const del = async () => {
    if (!curItem) return;
    if (!confirm(`Удалить «${curItem.name}» в корзину?`)) return;
    try {
      await api.deleteFile(curItem.entryId);
      setDetail(false);
      onDelete(k);
    } catch (e) {
      alert((e as Error).message);
    }
  };

  return (
    <div
      className={'mviewer' + (closing ? ' closing' : '')}
      style={closing ? { opacity: 0, transition: 'opacity .2s ease' } : undefined}
      onTransitionEnd={onRootTransitionEnd}
    >
      <div className="mv-head">
        <span className="mv-date">{fmtMediaDate(curItem?.capturedAt) || curItem?.name || ''}</span>
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Инфо" disabled={!curItem} onClick={() => setDetail((d) => !d)}>
          <Info />
        </button>
        {curItem && (
          <a className="iconbtn" title="Скачать оригинал" href={api.fileUrl(curItem.entryId)} download>
            <ArrowDownToLine />
          </a>
        )}
        <button className="iconbtn" title="Удалить (в корзину)" disabled={!curItem} onClick={() => void del()}>
          <Trash />
        </button>
        <button className="iconbtn" title="Закрыть" onClick={close}>
          <X />
        </button>
      </div>

      <div
        className="mv-stage"
        ref={stageRef}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endPointer}
        onPointerCancel={endPointer}
      >
        <StageMeasure onSize={setStage} />
        {slides.map(({ i, item }) => (
          <div
            className="mslide"
            key={i}
            style={{
              transform: `translateX(${(i - pos) * 100}%)`,
              transition: dragging ? 'none' : 'transform .28s cubic-bezier(.2,.7,.2,1)',
            }}
          >
            <Slide
              item={item}
              stage={stage}
              zoom={i === k ? zoom : { scale: 1, tx: 0, ty: 0 }}
              onNat={(s) => recordNat(i, s)}
            />
          </div>
        ))}
      </div>

      {detail && curItem && (
        <MediaInfoPanel entryId={curItem.entryId} onClose={() => setDetail(false)} />
      )}
    </div>
  );
}

/** Держит актуальный размер stage в состоянии родителя (ResizeObserver). */
function StageMeasure({ onSize }: { onSize: (s: { w: number; h: number }) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const report = () => onSize({ w: el.clientWidth, h: el.clientHeight });
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
  }, [onSize]);
  return <div className="mv-sizer" ref={ref} />;
}

/** Один кадр модалки: фото — с зумом, видео — плеер. Натуральный размер отдаёт родителю. */
function Slide({
  item,
  stage,
  zoom,
  onNat,
}: {
  item: MediaItem | undefined;
  stage: { w: number; h: number };
  zoom: ZoomState;
  onNat?: (s: { w: number; h: number }) => void;
}) {
  const [nat, setNat] = useState<{ w: number; h: number } | null>(null);
  const [failed, setFailed] = useState(false);

  if (!item) {
    return (
      <div className="mv-load">
        <span className="spin" />
      </div>
    );
  }

  const isVideo = /^video\//.test(item.mime);

  if (isVideo) {
    return (
      <video
        className="mv-video"
        src={api.videoPreviewUrl(item.sha256!)}
        controls
        playsInline
        preload="metadata"
        poster={item.sha256 ? api.previewUrl(item.sha256) : undefined}
      />
    );
  }

  if (failed || !item.sha256) {
    return (
      <div className="mv-err">
        <span className="copy">Превью не открылось — файл мог быть удалён</span>
      </div>
    );
  }

  const src = api.previewUrl(item.sha256, 1080);
  const fit = nat ? fitGeom(stage.w, stage.h, nat.w, nat.h) : null;

  return (
    <>
      {!fit && (
        <div className="mv-load">
          <span className="spin" />
        </div>
      )}
      {/* невидимая предзагрузка — по ней узнаём натуральный размер до показа */}
      {!fit && (
        <img
          src={src}
          alt=""
          style={{ display: 'none' }}
          onLoad={(e) => {
            const s = { w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight };
            setNat(s);
            onNat?.(s);
          }}
          onError={() => setFailed(true)}
        />
      )}
      {fit && (
        <img
          src={src}
          alt=""
          draggable={false}
          onError={() => setFailed(true)}
          style={{
            position: 'absolute',
            left: fit.ox + zoom.tx,
            top: fit.oy + zoom.ty,
            width: fit.bw * zoom.scale,
            height: fit.bh * zoom.scale,
            maxWidth: 'none',
            maxHeight: 'none',
            userSelect: 'none',
            WebkitUserSelect: 'none',
            touchAction: 'none',
          }}
        />
      )}
    </>
  );
}

// =============================== Инфо кадра ===============================

function fmtSize(bytes: number): string {
  if (!bytes || !Number.isFinite(bytes)) return '—';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  const kb = 1024;
  if (bytes >= gb) return `${(bytes / gb).toFixed(1)} ГБ`;
  if (bytes >= mb) return `${(bytes / mb).toFixed(1)} МБ`;
  if (bytes >= kb) return `${Math.round(bytes / kb)} КБ`;
  return `${bytes} Б`;
}

function InfoRow({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <div className="minfo-row">
      <span className="minfo-k">{k}</span>
      <span className={'minfo-v' + (mono ? ' mono' : '')}>{v}</span>
    </div>
  );
}

/** Панель «Инфо» в модалке: свой UI и своя ручка /media/:entryId, не из «Файлов». */
function MediaInfoPanel({ entryId, onClose }: { entryId: string; onClose: () => void }) {
  const [info, setInfo] = useState<api.MediaInfo | null>(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    api.mediaInfo(entryId).then(setInfo).catch((e) => setErr((e as Error).message));
  }, [entryId]);
  return (
    <div className="mvinfo">
      <div className="minfo-head">
        <span className="minfo-title">Инфо</span>
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Закрыть" onClick={onClose}>
          <X />
        </button>
      </div>
      {err && <div className="err" style={{ padding: '10px 14px' }}>{err}</div>}
      {!info && !err && (
        <div className="minfo-load">
          <span className="spin" />
        </div>
      )}
      {info && (
        <div className="minfo-body">
          <InfoRow k="Имя" v={info.name} />
          <InfoRow k="Дата съёмки" v={info.capturedAt ? fmtMediaDate(info.capturedAt) : '—'} />
          <InfoRow k="Тип" v={info.mime} />
          <InfoRow k="Размер" v={fmtSize(info.size)} />
          {info.width != null && info.height != null && <InfoRow k="Кадр" v={`${info.width} × ${info.height}`} />}
          {info.make || info.model ? <InfoRow k="Камера" v={[info.make, info.model].filter(Boolean).join(' ')} /> : null}
          {info.latitude != null && info.longitude != null ? (
            <div className="minfo-row">
              <span className="minfo-k">Место</span>
              <span className="minfo-v">
                <a
                  className="minfo-loc"
                  href={`https://www.openstreetmap.org/?mlat=${info.latitude}&mlon=${info.longitude}#map=16/${info.latitude}/${info.longitude}`}
                  target="_blank"
                  rel="noreferrer"
                  title="Открыть на карте"
                >
                  <MapPin size={14} /> {info.latitude.toFixed(6)}, {info.longitude.toFixed(6)}
                </a>
              </span>
            </div>
          ) : null}
          <InfoRow k="SHA-256" v={info.sha256} mono />
        </div>
      )}
    </div>
  );
}
