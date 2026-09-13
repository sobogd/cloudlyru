import { useCallback, useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { LocateFixed } from 'lucide-react';
import * as api from './api';
import { MediaViewer } from './media';
import { patchUi, readUi } from './storage';

/**
 * Вкладка «Карта» — все кадры с геометкой на подложке OpenStreetMap.
 *
 * Вид как в Google Photos: издалека плотность съёмки рисуется тепловым слоем (свой canvas
 * в отдельной панели Leaflet, поэтому он едет вместе с тайлами без перерисовки), при
 * приближении вместо тепла появляются миниатюры кадров, сгруппированные по экранным
 * клеткам: тап открывает кадр в общем просмотрщике «Медиа» — тот же MediaViewer, что и
 * в ленте, поэтому листание и удаление работают одинаково.
 *
 * Точки приходят одним запросом (`/media/map`): имена, типы и размеры карте не нужны —
 * миниатюра берётся по entryId (`/files/:id/thumb`), а детали кадра подтягиваются только
 * для открытого и соседних кадров.
 */

/** С какого зума вместо теплового слоя показываем миниатюры кадров. */
const MARKER_ZOOM = 13;
/** Запас вокруг вида, в пределах которого кадры ещё участвуют в группировке, px. */
const CLUSTER_PX = 56;
/** Градус широты в километрах — из него считаем километровую клетку группировки. */
const KM_DEG = 1 / 110.574;
/** Потолок одновременных миниатюр: это DOM-узлы с картинками, больше браузер не тянет. */
const CLUSTER_MAX = 300;
/** Сторона клетки, в которую складываются точки теплового слоя (меньше — дороже отрисовка). */
const HEAT_CELL = 8;
/** Радиус пятна теплового слоя, px. */
const HEAT_RADIUS = 30;
/** Размер миниатюры-кластера, px. */
const CLUSTER_ICON = 46;
/** Вид по умолчанию, если пользователь ещё не двигал карту. */
const DEFAULT_VIEW = { lat: 20, lon: 10, zoom: 2 };
/**
 * Сторона клетки (в градусах), по которой ищем самое «фотографируемое» место для первого
 * вида: ~5 км. Кадры одной поездки и одного города попадают в такую клетку, а редкие
 * outliers (отпуск на другом конце света) первый вид не растягивают.
 */
const FIRST_CELL = 0.05;

/** Палитра теплового слоя: накопленная плотность (0…1) → цвет. */
const HEAT_STOPS: Array<[number, [number, number, number]]> = [
  [0, [43, 108, 255]],
  [0.35, [64, 196, 255]],
  [0.6, [47, 174, 95]],
  [0.8, [255, 204, 51]],
  [1, [255, 77, 79]],
];

function heatColor(t: number): [number, number, number] {
  let lo = HEAT_STOPS[0];
  let hi = HEAT_STOPS[HEAT_STOPS.length - 1];
  for (let i = 0; i < HEAT_STOPS.length - 1; i++) {
    if (t >= HEAT_STOPS[i][0] && t <= HEAT_STOPS[i + 1][0]) {
      lo = HEAT_STOPS[i];
      hi = HEAT_STOPS[i + 1];
      break;
    }
  }
  const span = hi[0] - lo[0] || 1;
  const k = Math.min(1, Math.max(0, (t - lo[0]) / span));
  return [
    Math.round(lo[1][0] + (hi[1][0] - lo[1][0]) * k),
    Math.round(lo[1][1] + (hi[1][1] - lo[1][1]) * k),
    Math.round(lo[1][2] + (hi[1][2] - lo[1][2]) * k),
  ];
}

/** Пятно теплового слоя: рисуется один раз и потом только копируется по точкам. */
function makeSprite(): HTMLCanvasElement {
  const size = HEAT_RADIUS * 2;
  const cv = document.createElement('canvas');
  cv.width = size;
  cv.height = size;
  const ctx = cv.getContext('2d');
  if (ctx) {
    const g = ctx.createRadialGradient(HEAT_RADIUS, HEAT_RADIUS, 0, HEAT_RADIUS, HEAT_RADIUS, HEAT_RADIUS);
    g.addColorStop(0, 'rgba(255,255,255,1)');
    g.addColorStop(0.4, 'rgba(255,255,255,0.45)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, size, size);
  }
  return cv;
}

/**
 * Размер клетки группировки миниатюр в градусах широты.
 *
 * При обычном приближении (13–15) это километр: кадры одного двора, кафе или площади —
 * одна точка места, как в Google Photos, а не десяток точек друг на друге. Дальше клетка
 * мельчает, иначе на сильном зуме один маркер накрывал бы весь экран и отдельные кадры
 * было бы не выбрать.
 */
function clusterCellDeg(zoom: number): number {
  if (zoom <= 15) return KM_DEG;
  if (zoom === 16) return KM_DEG / 4;
  if (zoom === 17) return KM_DEG / 10;
  return KM_DEG / 100;
}

/** Ключ географической клетки: широтная и долготная полосы клетки одной строкой. */
const cellKey = (latKey: number, lonKey: number) => `${latKey}:${lonKey}`;

/** Ключ экранной клетки теплового слоя: координаты клетки в одно число. */
const heatKey = (gx: number, gy: number) => (gx + 8192) * 65536 + (gy + 8192);

export default function MapSection({ onOverlayChange }: {
  /** Открыт просмотрщик кадра — Shell прячет нижний остров, чтобы он не наезжал на футер. */
  onOverlayChange?: (open: boolean) => void;
}) {
  const [points, setPoints] = useState<api.MapPoint[] | null>(null);
  const [total, setTotal] = useState(0);
  const [truncated, setTruncated] = useState(false);
  const [error, setError] = useState('');
  const [openIdx, setOpenIdx] = useState<number | null>(null);
  /** Зум достаточный, чтобы вместо тепла показывать миниатюры. */
  const [markers, setMarkers] = useState(false);
  /** Сколько кадров попадает в текущий вид: ноль — показываем подсказку «здесь кадров нет». */
  const [visibleCount, setVisibleCount] = useState(-1);

  const hostRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<L.Map | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const offRef = useRef<HTMLCanvasElement | null>(null);
  const spriteRef = useRef<HTMLCanvasElement | null>(null);
  const markerLayerRef = useRef<L.LayerGroup | null>(null);
  const pointsRef = useRef<api.MapPoint[]>([]);
  const drawRef = useRef<() => void>(() => {});
  const markersRef = useRef<() => void>(() => {});
  /** Вид карты, сохранённый в прошлый раз: восстановим его вместо «показать всё». */
  const [savedView] = useState(() => readUi().map);

  useEffect(() => {
    onOverlayChange?.(openIdx != null);
  }, [openIdx, onOverlayChange]);

  // Точки всей ленты — одним запросом при входе на вкладку.
  useEffect(() => {
    let stopped = false;
    api
      .mediaMap()
      .then((r) => {
        if (stopped) return;
        pointsRef.current = r.points;
        setPoints(r.points);
        setTotal(r.total);
        setTruncated(r.truncated);
      })
      .catch((e) => {
        if (!stopped) setError((e as Error).message);
      });
    return () => {
      stopped = true;
    };
  }, []);

  /** Показать все кадры разом (или вернуть мир, если геометок нет). */
  const fitAll = useCallback(() => {
    const map = mapRef.current;
    if (!map) return;
    const pts = pointsRef.current;
    if (!pts.length) {
      map.setView([DEFAULT_VIEW.lat, DEFAULT_VIEW.lon], DEFAULT_VIEW.zoom);
      return;
    }
    map.fitBounds(L.latLngBounds(pts.map((p) => [p.lat, p.lon] as [number, number])), {
      padding: [40, 40],
      maxZoom: 15,
    });
  }, []);

  /**
   * Первый вид — там, где кадров больше всего. Общий охват всей библиотеки (от Патагонии
   * до Байкала, если такие поездки были) на первом открытии выглядит пустой картой мира
   * с крошечными пятнами; полный охват остаётся на кнопке в шапке.
   */
  const fitFirst = useCallback(() => {
    const map = mapRef.current;
    const pts = pointsRef.current;
    if (!map) return;
    if (!pts.length) {
      map.setView([DEFAULT_VIEW.lat, DEFAULT_VIEW.lon], DEFAULT_VIEW.zoom);
      return;
    }
    const cell = (p: api.MapPoint) => `${Math.round(p.lat / FIRST_CELL)}:${Math.round(p.lon / FIRST_CELL)}`;
    const counts = new Map<string, number>();
    for (const p of pts) {
      const k = cell(p);
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    let best = '';
    let bestN = 0;
    for (const [k, n] of counts) {
      if (n > bestN) {
        best = k;
        bestN = n;
      }
    }
    const near = pts.filter((p) => cell(p) === best);
    const box = L.latLngBounds(near.map((p) => [p.lat, p.lon] as [number, number]));
    if (!box.isValid()) {
      fitAll();
      return;
    }
    map.fitBounds(box, { padding: [60, 60], maxZoom: 16 });
  }, [fitAll]);

  // Карта живёт вне React: Leaflet сам двигает тайлы, мы только рисуем тепло и маркеры.
  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const map = L.map(host, {
      center: [savedView?.lat ?? DEFAULT_VIEW.lat, savedView?.lon ?? DEFAULT_VIEW.lon],
      zoom: savedView?.zoom ?? DEFAULT_VIEW.zoom,
      minZoom: 2,
      maxZoom: 19,
      worldCopyJump: true,
      // Кнопок +/− и подписи OSM на карте нет: зум — колесом, щипком и двойным тапом,
      // а весь служебный текст занимал место над нижним островом.
      zoomControl: false,
      attributionControl: false,
    });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19 }).addTo(map);
    // Отдельная панель под тепловой слой: canvas лежит среди панелей карты и потому
    // переезжает вместе с тайлами — во время панорамирования перерисовка не нужна.
    const pane = map.createPane('heat');
    pane.style.zIndex = '350';
    pane.style.pointerEvents = 'none';
    const canvas = document.createElement('canvas');
    canvas.className = 'map-heat';
    pane.appendChild(canvas);
    canvasRef.current = canvas;
    markerLayerRef.current = L.layerGroup().addTo(map);
    mapRef.current = map;
    spriteRef.current = makeSprite();

    const draw = () => {
      const cv = canvasRef.current;
      if (!cv) return;
      const size = map.getSize();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const w = Math.max(1, Math.round(size.x * dpr));
      const h = Math.max(1, Math.round(size.y * dpr));
      if (cv.width !== w || cv.height !== h) {
        cv.width = w;
        cv.height = h;
      }
      cv.style.width = `${size.x}px`;
      cv.style.height = `${size.y}px`;
      // Позицию canvas не трогаем: он лежит в своей панели, а панель уже стоит в начале
      // координат вида — ровно там же, где отсчитываются latLngToLayerPoint. Сдвиг на
      // pixelOrigin (он равен абсолютным пикселям проекции, миллионы) уносил слой за экран.
      const ctx = cv.getContext('2d');
      if (!ctx) return;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, size.x, size.y);
      const pts = pointsRef.current;
      // Вблизи вместо тепла — миниатюры, но слой не убираем совсем, а бледним: иначе карта
      // в месте без кадров выглядела бы пустой и непонятной.
      if (!pts.length) return;
      const dim = map.getZoom() >= MARKER_ZOOM ? 0.55 : 1;

      // Точки складываются в клетки: десятки тысяч пятен по одному рисовать нельзя, а клетка
      // ещё и показывает плотность — чем больше кадров, тем ярче пятно. Координаты слоя
      // (latLngToLayerPoint) уже отсчитаны от начала вида — ровно та система, в которой
      // стоит сам canvas, поэтому вычитать pixelOrigin второй раз нельзя.
      const buckets = new Map<number, { x: number; y: number; n: number }>();
      for (const p of pts) {
        const lp = map.latLngToLayerPoint([p.lat, p.lon]);
        const x = lp.x;
        const y = lp.y;
        if (x < -HEAT_RADIUS || y < -HEAT_RADIUS || x > size.x + HEAT_RADIUS || y > size.y + HEAT_RADIUS) continue;
        const key = heatKey(Math.floor(x / HEAT_CELL), Math.floor(y / HEAT_CELL));
        const b = buckets.get(key);
        if (b) b.n++;
        else buckets.set(key, { x, y, n: 1 });
      }
      if (!buckets.size) return;

      let off = offRef.current;
      if (!off) {
        off = document.createElement('canvas');
        offRef.current = off;
      }
      if (off.width !== w || off.height !== h) {
        off.width = w;
        off.height = h;
      }
      // willReadFrequently: альфу этого canvas мы читаем на каждой перерисовке, и без флага
      // браузер гоняет пиксели между GPU и CPU — на телефоне это заметно.
      const octx = off.getContext('2d', { willReadFrequently: true });
      const sprite = spriteRef.current;
      if (!octx || !sprite) return;
      octx.setTransform(dpr, 0, 0, dpr, 0, 0);
      octx.clearRect(0, 0, size.x, size.y);
      // 'lighter' складывает альфу пятен — из неё и получается градиент плотности
      octx.globalCompositeOperation = 'lighter';
      for (const b of buckets.values()) {
        octx.globalAlpha = Math.min(1, 0.45 + 0.2 * Math.sqrt(b.n));
        octx.drawImage(sprite, b.x - HEAT_RADIUS, b.y - HEAT_RADIUS);
      }
      octx.globalAlpha = 1;
      octx.globalCompositeOperation = 'source-over';
      // Накопленная альфа — это и есть мера плотности: раскрашиваем её палитрой
      const img = octx.getImageData(0, 0, off.width, off.height);
      const d = img.data;
      for (let i = 0; i < d.length; i += 4) {
        const a = d[i + 3];
        if (!a) continue;
        // 1.6 — гамма: середина накопления уходит в тёплые цвета, иначе бледные пятна
        // на светлой подложке читались как «тепла нет».
        const [r, g, bl] = heatColor(Math.min(1, (a / 255) * 1.6));
        d[i] = r;
        d[i + 1] = g;
        d[i + 2] = bl;
      }
      octx.putImageData(img, 0, 0);
      ctx.globalAlpha = dim;
      ctx.drawImage(off, 0, 0, size.x, size.y);
      ctx.globalAlpha = 1;
    };

    const syncMarkers = () => {
      const layer = markerLayerRef.current;
      if (!layer) return;
      layer.clearLayers();
      const pts = pointsRef.current;
      // Кадры в текущем виде: нужно отдельно от зума миниатюр — по этому признаку показываем
      // «в этой области кадров нет», когда пользователь уехал туда, где съёмок не было.
      const view = map.getBounds().pad(0.05);
      let inView = 0;
      for (const p of pts) if (view.contains([p.lat, p.lon])) inView++;
      setVisibleCount(inView);
      const show = map.getZoom() >= MARKER_ZOOM && pts.length > 0;
      setMarkers(show);
      if (!show) return;
      const size = map.getSize();
      const step = clusterCellDeg(map.getZoom());
      // Кадры одной клетки — одна миниатюра; points уже идут от свежих, поэтому первый
      // в клетке и есть самый новый кадр места. Берём только то, что попадает на экран:
      // иначе потолок CLUSTER_MAX съедали бы густые места за пределами вида, и в текущем
      // месте не было бы ни одной миниатюры.
      const cells = new Map<string, { lat: number; lon: number; n: number; idx: number }>();
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        const lp = map.latLngToLayerPoint([p.lat, p.lon]);
        if (lp.x < -CLUSTER_PX || lp.y < -CLUSTER_PX || lp.x > size.x + CLUSTER_PX || lp.y > size.y + CLUSTER_PX) continue;
        // Долготная клетка уже широтной во столько раз, во сколько раз параллель короче
        // экватора: без этого на севере клетки вытягивались бы вдоль широты.
        const lonStep = step / Math.max(0.05, Math.cos((p.lat * Math.PI) / 180));
        const key = cellKey(Math.round(p.lat / step), Math.round(p.lon / lonStep));
        const c = cells.get(key);
        if (c) c.n++;
        else cells.set(key, { lat: p.lat, lon: p.lon, n: 1, idx: i });
      }
      const list = [...cells.values()].sort((a, b) => b.n - a.n).slice(0, CLUSTER_MAX);
      for (const c of list) {
        const item = pts[c.idx];
        const icon = L.divIcon({
          className: 'map-cluster',
          html:
            `<img src="${api.thumbUrl(item.entryId)}" alt="" loading="lazy" decoding="async">` +
            (c.n > 1 ? `<i>${c.n}</i>` : ''),
          iconSize: [CLUSTER_ICON, CLUSTER_ICON],
          iconAnchor: [CLUSTER_ICON / 2, CLUSTER_ICON / 2],
        });
        const marker = L.marker([c.lat, c.lon], { icon, keyboard: false, riseOnHover: true });
        marker.on('click', () => setOpenIdx(c.idx));
        layer.addLayer(marker);
      }
    };

    drawRef.current = draw;
    markersRef.current = syncMarkers;

    let saveTimer: number | null = null;
    const onViewChange = () => {
      draw();
      syncMarkers();
      if (saveTimer != null) window.clearTimeout(saveTimer);
      saveTimer = window.setTimeout(() => {
        const c = map.getCenter();
        patchUi({ map: { lat: c.lat, lon: c.lng, zoom: map.getZoom() } });
      }, 400);
    };
    map.on('moveend', onViewChange);
    map.on('zoomend', onViewChange);
    map.on('resize', () => draw());

    return () => {
      if (saveTimer != null) window.clearTimeout(saveTimer);
      map.off();
      map.remove();
      mapRef.current = null;
      canvasRef.current = null;
      markerLayerRef.current = null;
      drawRef.current = () => {};
      markersRef.current = () => {};
    };
    // Карта создаётся один раз: смена вида и точек идёт через refs, а не пересоздание Leaflet.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Точки пришли (или изменились после удаления) — перерисовать слои.
  const fittedRef = useRef(false);
  useEffect(() => {
    if (points == null) return;
    drawRef.current();
    markersRef.current();
    if (fittedRef.current) return;
    fittedRef.current = true;
    // Восстановленный вид принимаем, только если в нём есть кадры: прошлая версия карты
    // сохраняла любой вид, и можно было открыть вкладку в пустом месте и решить,
    // что карта не работает.
    const box = mapRef.current?.getBounds().pad(0.1);
    const hasPhotos = !!box && points.some((p) => box.contains([p.lat, p.lon]));
    if (!savedView || !hasPhotos) fitFirst();
  }, [points, savedView, fitFirst]);

  // ---- Источник кадров для просмотрщика: у карты нет ленты, детали берём по entryId ----
  const itemsRef = useRef(new Map<string, api.MediaItem>());
  const pendingRef = useRef(new Set<string>());
  const [, bump] = useState(0);

  const ensure = useCallback((start: number, end: number) => {
    const pts = pointsRef.current;
    const from = Math.max(0, start);
    const to = Math.min(pts.length - 1, end);
    for (let i = from; i <= to; i++) {
      const p = pts[i];
      if (!p || itemsRef.current.has(p.entryId) || pendingRef.current.has(p.entryId)) continue;
      pendingRef.current.add(p.entryId);
      void api
        .mediaInfo(p.entryId)
        .then((d) => {
          itemsRef.current.set(p.entryId, {
            entryId: p.entryId,
            name: d.name,
            mime: d.mime,
            sha256: d.sha256,
            capturedAt: d.capturedAt,
            size: d.size,
            previewState: 'done',
            jobState: null,
          });
          bump((n) => n + 1);
        })
        .catch(() => undefined)
        .finally(() => pendingRef.current.delete(p.entryId));
    }
  }, []);

  const getItem = useCallback((i: number) => {
    const p = pointsRef.current[i];
    return p ? itemsRef.current.get(p.entryId) : undefined;
  }, []);

  // Удаление кадра: точка уходит с карты, индексы дальше сдвигаются — как в ленте.
  const handleDelete = useCallback((index: number) => {
    const next = pointsRef.current.filter((_, i) => i !== index);
    pointsRef.current = next;
    setPoints(next);
    setOpenIdx(next.length ? Math.min(index, next.length - 1) : null);
  }, []);

  const count = points?.length ?? 0;

  return (
    <div className="mapwrap">
      <div className="mhead">
        <span className="mmonth">
          {error
            ? 'Карта'
            : points == null
              ? 'Карта'
              : count === 0
                ? 'Нет фото с геоданными'
                : `${count} фото на карте${truncated ? ` из ${total}` : ''}`}
        </span>
        <button className="iconbtn" title="Показать все фото" onClick={fitAll} disabled={!count}>
          <LocateFixed />
        </button>
      </div>
      <div className="mapbox">
        <div className="map-host" ref={hostRef} />
        {error && <div className="map-pill err">{error}</div>}
        {!error && points == null && <div className="map-pill">Загружаю метки…</div>}
        {!error && points != null && count === 0 && (
          <div className="map-note copy">
            Здесь появятся кадры с геометкой. Координаты берутся из EXIF фото и видео, а само
            превью должно быть уже собрано — у снимков без геоданных или без превью их нет.
          </div>
        )}
        {!error && points != null && count > 0 && visibleCount === 0 && (
          <button type="button" className="map-pill map-pill-btn" onClick={fitAll}>
            <LocateFixed /> В этой области кадров нет — показать все
          </button>
        )}
        {!error && points != null && count > 0 && visibleCount !== 0 && !markers && (
          <div className="map-pill">Плотность съёмки · приблизьте, чтобы увидеть кадры</div>
        )}
      </div>

      {openIdx != null && points != null && points.length > 0 && (
        <MediaViewer
          total={points.length}
          idx={openIdx}
          getItem={getItem}
          ensure={ensure}
          onNavigate={setOpenIdx}
          onClose={() => setOpenIdx(null)}
          onDelete={handleDelete}
        />
      )}
    </div>
  );
}
