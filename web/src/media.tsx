import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { ArrowDownToLine, ArrowLeft, ArrowRight, Info, Trash, X } from 'lucide-react';
import * as api from './api';

/**
 * Раздел «Медиа» — изолированная от «Фото»/«Видео» поверхность просмотра.
 *
 * Таймлайн: бесконечная лента зоны «Фото» (фото + видео), виртуализированная сетка из
 * квадратов 50×50 (ровно то превью, что отдаёт сервер — без апскейла и лишнего трафика).
 * В липкой шапке-острове — месяц и год того снимка, что сейчас под верхом прокрутки.
 *
 * Модалка: 3 блока (шапка/фото/футер), плавное появление-затухание, зум щипком и дабл-тапом,
 * листание свайпом пальцем и на трекпаде — аналог гугла: свайп тащит кадр за пальцем, на
 * отпускании снап по расстоянию/скорости. При зуме свайп панорамирует снимок, а не листает.
 */

type MediaItem = api.MediaItem;

/** Компонент деталки файла — пробрасывается из App, чтобы не тянуть сюда внутренности. */
export interface DetailComponentProps {
  entryId: string;
  onBack: () => void;
  onDeleted?: (entryId: string) => void;
  inOverlay?: boolean;
}
type DetailComponent = (props: DetailComponentProps) => JSX.Element;

/** Размер клетки и зазоры сетки: превью сервер отдаёт ровно 50×50, поэтому клетка = 50. */
const CELL = 50;
const GAP = 3;
const ROW = CELL + GAP;
/** Сколько строк вне экрана держим смонтированными (запас на быстрый скролл). */
const OVERSCAN = 3;
/** Размер страницы ленты. */
const PAGE = 300;
/** Окно просмотра и порог добора ленты в модалке. */
const WIN_EDGE = 6;

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
  const dt = new Date(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi));
  const date = dt.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' });
  return `${date} · ${h}:${mi}`;
}

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

function fitGeom(cw: number, ch: number, nw: number, nh: number) {
  const fit = Math.min(cw / nw, ch / nh);
  const bw = nw * fit;
  const bh = nh * fit;
  return { cw, ch, ox: (cw - bw) / 2, oy: (ch - bh) / 2, bw, bh };
}

// =============================== Таймлайн ===============================

export default function MediaSection({ FileDetail }: { FileDetail: DetailComponent }) {
  const [items, setItems] = useState<MediaItem[]>([]);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [openIdx, setOpenIdx] = useState<number | null>(null);

  const scrollRef = useRef<HTMLDivElement>(null);
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const loadingRef = useRef(false);
  const hasMoreRef = useRef(true);
  const seqRef = useRef(0);

  const [cols, setCols] = useState(1);
  const [viewport, setViewport] = useState({ w: 0, h: 0 });
  const [range, setRange] = useState<[number, number]>([0, OVERSCAN]);
  const [month, setMonth] = useState('');

  const loadMore = useCallback(async () => {
    if (loadingRef.current || !hasMoreRef.current) return;
    loadingRef.current = true;
    setLoading(true);
    const seq = ++seqRef.current;
    const cursor = itemsRef.current[itemsRef.current.length - 1]?.entryId;
    try {
      const page = await api.mediaTimeline(PAGE, cursor);
      if (seq !== seqRef.current) return;
      hasMoreRef.current = page.length >= PAGE;
      setHasMore(hasMoreRef.current);
      setItems((prev) => {
        const seen = new Set(prev.map((i) => i.entryId));
        const add = page.filter((i) => !seen.has(i.entryId));
        return [...prev, ...add];
      });
      setError('');
    } catch (e) {
      if (seq !== seqRef.current) return;
      if ((e as { code?: string }).code === 'cursor_stale') {
        // Запись-курсор исчезла посреди прокрутки: не считаем это концом ленты, а просим
        // пользователя перечитать раздел (обычно после удаления/переноса на другом устройстве).
        hasMoreRef.current = false;
        setHasMore(false);
        setError('Лента изменилась на сервере — перезагрузите страницу');
      } else {
        setError((e as Error).message);
      }
    } finally {
      if (seq === seqRef.current) {
        loadingRef.current = false;
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    void loadMore();
  }, [loadMore]);

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

  const rowCount = Math.ceil(items.length / cols);
  const totalH = Math.max(0, rowCount * ROW - GAP);

  const updateRange = useCallback(
    (top: number) => {
      const vh = viewport.h || 600;
      const start = Math.max(0, Math.floor(top / ROW) - OVERSCAN);
      const end = Math.min(rowCount - 1, Math.ceil((top + vh) / ROW) + OVERSCAN);
      setRange((prev) => (prev[0] === start && prev[1] === end ? prev : [start, end]));
    },
    [viewport.h, rowCount],
  );

  const rafRef = useRef(0);
  const onScroll = useCallback(() => {
    if (rafRef.current) return;
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = 0;
      const el = scrollRef.current;
      if (!el) return;
      const top = el.scrollTop;
      updateRange(top);
      const firstRow = Math.max(0, Math.floor(top / ROW));
      const item = itemsRef.current[firstRow * cols];
      const key = item?.capturedAt?.slice(0, 7) ?? '';
      setMonth((m) => (m === key ? m : key));
      if (hasMoreRef.current && !loadingRef.current && top + el.clientHeight > el.scrollHeight - 900) {
        void loadMore();
      }
    });
  }, [updateRange, cols, loadMore]);

  // После догрузки/ресайза пересчитываем видимый диапазон и месяц.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const top = el.scrollTop;
    updateRange(top);
    const firstRow = Math.max(0, Math.floor(top / ROW));
    const item = itemsRef.current[firstRow * cols];
    setMonth((m) => {
      const key = item?.capturedAt?.slice(0, 7) ?? '';
      return m === key ? m : key;
    });
  }, [updateRange, cols, items.length]);

  const rows = useMemo(() => {
    const out: Array<{ y: number; start: number; cells: MediaItem[] }> = [];
    for (let r = range[0]; r <= range[1] && r >= 0; r++) {
      const start = r * cols;
      const cells = items.slice(start, start + cols);
      if (!cells.length) continue;
      out.push({ y: r * ROW, start, cells });
    }
    return out;
  }, [range, items, cols]);

  const handleDelete = useCallback((entryId: string) => {
    const cur = itemsRef.current;
    const i = cur.findIndex((x) => x.entryId === entryId);
    if (i < 0) return;
    const next = cur.filter((x) => x.entryId !== entryId);
    setItems(next);
    if (!next.length) {
      setOpenIdx(null);
      return;
    }
    setOpenIdx(Math.min(i, next.length - 1));
  }, []);

  const handleNeedMore = useCallback(() => {
    if (hasMoreRef.current) void loadMore();
  }, [loadMore]);

  return (
    <div className="media">
      <div className="mhead">
        <span className="mmonth">{month ? monthLabel(month) : 'Медиа'}</span>
      </div>
      <div className="mscroll" ref={scrollRef} onScroll={onScroll}>
        {error && <div className="err" style={{ padding: '8px 4px' }}>{error}</div>}
        {!items.length && !loading && !error && (
          <div className="mempty">
            <span className="copy">Здесь появятся фото и видео из раздела «Фото»</span>
          </div>
        )}
        <div className="mvirt" style={{ height: totalH }}>
          {rows.map((row) => (
            <div className="mrow" key={row.start} style={{ transform: `translateY(${row.y}px)` }}>
              {row.cells.map((it, ci) => (
                <Cell key={it.entryId} item={it} onClick={() => setOpenIdx(row.start + ci)} />
              ))}
            </div>
          ))}
        </div>
        {loading && (
          <div className="mloading">
            <span className="spin" />
          </div>
        )}
      </div>

      {openIdx != null && items[openIdx] && (
        <MediaViewer
          items={items}
          idx={openIdx}
          onNavigate={setOpenIdx}
          onClose={() => setOpenIdx(null)}
          onDelete={handleDelete}
          onNeedMore={handleNeedMore}
          FileDetail={FileDetail}
        />
      )}
    </div>
  );
}

function Cell({ item, onClick }: { item: MediaItem; onClick: () => void }) {
  const ready = item.previewState === 'done' && !!item.sha256;
  const video = /^video\//.test(item.mime);
  return (
    <button
      type="button"
      className={'mcell' + (ready ? (video ? ' video' : '') : ' off')}
      disabled={!ready}
      onClick={onClick}
      title={item.name}
      aria-label={item.name}
    >
      {ready && <img src={api.previewUrl(item.sha256!)} alt="" loading="lazy" decoding="async" draggable={false} />}
    </button>
  );
}

// =============================== Модалка ===============================

type ZoomState = { scale: number; tx: number; ty: number };

function MediaViewer({
  items,
  idx,
  onNavigate,
  onClose,
  onDelete,
  onNeedMore,
  FileDetail,
}: {
  items: MediaItem[];
  idx: number;
  onNavigate: (idx: number) => void;
  onClose: () => void;
  onDelete: (entryId: string) => void;
  onNeedMore: () => void;
  FileDetail: DetailComponent;
}) {
  const [pos, setPos] = useState(idx);
  const [dragging, setDragging] = useState(false);
  const [zoom, setZoom] = useState<ZoomState>({ scale: 1, tx: 0, ty: 0 });
  const [nat, setNat] = useState<{ w: number; h: number } | null>(null);
  const [stage, setStage] = useState({ w: 0, h: 0 });
  const [closing, setClosing] = useState(false);
  const [detail, setDetail] = useState(false);

  const stageRef = useRef<HTMLDivElement>(null);

  const posRef = useRef(pos);
  posRef.current = pos;
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const fitRef = useRef(nat ? fitGeom(stage.w, stage.h, nat.w, nat.h) : null);
  fitRef.current = nat && stage.w > 0 ? fitGeom(stage.w, stage.h, nat.w, nat.h) : null;

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

  const k = clamp(Math.round(pos), 0, items.length - 1);
  const curItem = items[k];

  // Позиция догоняет индекс после снапа/навигации кнопками/удаления.
  useEffect(() => {
    setPos(idx);
  }, [idx]);

  // Новый кадр — сбрасываем зум и ждём его натуральный размер.
  useEffect(() => {
    setZoom({ scale: 1, tx: 0, ty: 0 });
    setNat(null);
    setDetail(false);
  }, [k]);

  // Добор ленты, когда листаем к краю загруженного.
  useEffect(() => {
    if (items.length - k <= WIN_EDGE) onNeedMore();
  }, [k, items.length, onNeedMore]);

  // Escape закрывает (если не открыта деталка — она закрывается первой).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (detail) setDetail(false);
        else close();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [detail]);

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
      const t = clamp(Math.round(posRef.current) + delta, 0, items.length - 1);
      setDragging(false);
      setPos(t);
      onNavigate(t);
    },
    [items.length, onNavigate],
  );

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
      const np = clamp(gp.startPos - (e.clientX - gp.startX) / w, 0, items.length - 1);
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
      target = clamp(target, 0, items.length - 1);
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
      setPos((p) => clamp(p + e.deltaX / w, 0, items.length - 1));
      if (wheelTimer.current) window.clearTimeout(wheelTimer.current);
      wheelTimer.current = window.setTimeout(() => {
        if (closingRef.current) return;
        setDragging(false);
        const p = posRef.current;
        const t = clamp(Math.round(p), 0, items.length - 1);
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
  const slides = useMemo(() => {
    const out: Array<{ i: number; item: MediaItem }> = [];
    for (let i = k - 1; i <= k + 1; i++) {
      if (i < 0 || i >= items.length) continue;
      out.push({ i, item: items[i] });
    }
    return out;
  }, [k, items]);

  const del = async () => {
    if (!curItem) return;
    if (!confirm(`Удалить «${curItem.name}» в корзину?`)) return;
    try {
      await api.deleteFile(curItem.entryId);
      onDelete(curItem.entryId);
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
            key={item.entryId}
            style={{
              transform: `translateX(${(i - pos) * 100}%)`,
              transition: dragging ? 'none' : 'transform .28s cubic-bezier(.2,.7,.2,1)',
            }}
          >
            <Slide
              item={item}
              stage={stage}
              zoom={i === k ? zoom : { scale: 1, tx: 0, ty: 0 }}
              onNat={i === k ? setNat : undefined}
            />
          </div>
        ))}
      </div>

      <div className="mv-foot">
        <div className="mv-left">
          <button className="iconbtn" title="Инфо" onClick={() => setDetail((d) => !d)}>
            <Info />
          </button>
          <a className="iconbtn" title="Скачать оригинал" href={api.fileUrl(curItem.entryId)} download>
            <ArrowDownToLine />
          </a>
          <button className="iconbtn" title="Удалить (в корзину)" onClick={() => void del()}>
            <Trash />
          </button>
        </div>
        <div className="mv-right">
          <button className="iconbtn" title="Предыдущий снимок" disabled={k <= 0} onClick={() => go(-1)}>
            <ArrowLeft />
          </button>
          <button className="iconbtn" title="Следующий снимок" disabled={k >= items.length - 1} onClick={() => go(1)}>
            <ArrowRight />
          </button>
        </div>
      </div>

      {detail && curItem && (
        <div className="mvinfo">
          <FileDetail
            entryId={curItem.entryId}
            onBack={() => setDetail(false)}
            onDeleted={(id) => {
              setDetail(false);
              onDelete(id);
            }}
            inOverlay
          />
        </div>
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
  item: MediaItem;
  stage: { w: number; h: number };
  zoom: ZoomState;
  onNat?: (s: { w: number; h: number }) => void;
}) {
  const [nat, setNat] = useState<{ w: number; h: number } | null>(null);
  const [failed, setFailed] = useState(false);
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
