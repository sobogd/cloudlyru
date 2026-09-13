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
 * Миниатюры кадров сгруппированы по клеткам экранного размера: издалека это одна точка
 * на город со счётчиком, вблизи точки расходятся до отдельных снимков. Клетка привязана
 * к мировым пикселям, а не к краям вида, поэтому при перетаскивании кадры не перескакивают
 * между группами. Тап открывает кадр в общем просмотрщике «Медиа» — том же MediaViewer,
 * что и в ленте, поэтому листание и удаление работают одинаково.
 *
 * Точки приходят одним запросом (`/media/map`): имена, типы и размеры карте не нужны —
 * миниатюра берётся по entryId (`/files/:id/thumb`), а детали кадра подтягиваются только
 * для открытого и соседних кадров.
 */

/**
 * Сторона клетки группировки, px. Клетка мелкая намеренно: чем она меньше, тем больше
 * точек на экране и тем точнее видно, где именно снимали. Слишком крупные клетки на
 * дальней карте превращались в несколько больших плиток, которые закрывали саму карту.
 */
const CLUSTER_PX = 48;
/**
 * Потолок одновременных миниатюр: это DOM-узлы с картинками. При клетке 48 px на широком
 * экране их помещается около 300, поэтому запас — 400; на телефоне упирается в экран раньше.
 */
const CLUSTER_MAX = 400;
/** Сторона миниатюры-кластера: мелкие точки, чтобы поле точек не закрывало карту. */
const CLUSTER_SIDE_MIN = 24;
const CLUSTER_SIDE_MAX = 38;
/** Вид по умолчанию, если пользователь ещё не двигал карту. */
const DEFAULT_VIEW = { lat: 20, lon: 10, zoom: 2 };
/**
 * Сторона клетки (в градусах), по которой ищем самое «фотографируемое» место для первого
 * вида: ~5 км. Кадры одной поездки и одного города попадают в такую клетку, а редкие
 * outliers (отпуск на другом конце света) первый вид не растягивают.
 */
const FIRST_CELL = 0.05;

/**
 * Сторона точки: чем больше кадров в клетке, тем крупнее миниатюра — плотность видно сразу.
 * Рост логарифмический: разницу между 10 и 100 кадрами видно, а между 400 и 3000 — уже нет,
 * и упираться в потолок размера незачем.
 */
function clusterSide(n: number): number {
  const k = Math.min(1, Math.log10(n + 1) / 2.5);
  return Math.round(CLUSTER_SIDE_MIN + (CLUSTER_SIDE_MAX - CLUSTER_SIDE_MIN) * k);
}

/** Ключ клетки — её координаты в мировых пикселях (одна строка, чтобы не путать с лат/лон). */
const cellKey = (gx: number, gy: number) => `${gx}:${gy}`;

export default function MapSection({ onOverlayChange }: {
  /** Открыт просмотрщик кадра — Shell прячет нижний остров, чтобы он не наезжал на футер. */
  onOverlayChange?: (open: boolean) => void;
}) {
  const [points, setPoints] = useState<api.MapPoint[] | null>(null);
  const [total, setTotal] = useState(0);
  const [truncated, setTruncated] = useState(false);
  const [error, setError] = useState('');
  /**
   * Открытая группа: индексы её кадров в общем списке точек. Деталка листает только их —
   * кликнул по площадке, значит и смотришь кадры этой площадки, а не всю библиотеку.
   */
  const [openGroup, setOpenGroup] = useState<number[] | null>(null);
  /** Позиция внутри открытой группы. */
  const [openAt, setOpenAt] = useState(0);
  /** Сколько кадров попадает в текущий вид: ноль — показываем подсказку «здесь кадров нет». */
  const [visibleCount, setVisibleCount] = useState(-1);

  const hostRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<L.Map | null>(null);
  const markerLayerRef = useRef<L.LayerGroup | null>(null);
  const pointsRef = useRef<api.MapPoint[]>([]);
  const groupRef = useRef<number[] | null>(null);
  const markersRef = useRef<() => void>(() => {});
  /** Вид карты, сохранённый в прошлый раз: восстановим его вместо «показать всё». */
  const [savedView] = useState(() => readUi().map);

  useEffect(() => {
    onOverlayChange?.(openGroup != null);
  }, [openGroup, onOverlayChange]);

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
    markerLayerRef.current = L.layerGroup().addTo(map);
    mapRef.current = map;

    /**
     * Точки-миниатюры. Клетка — квадрат CLUSTER_PX в мировых пикселях текущего зума:
     * на дальнем плане в неё попадает целый город (одна миниатюра со счётчиком), вблизи —
     * один двор. Мировые пиксели, а не координаты экрана: иначе при перетаскивании клетки
     * пересобирались бы и точки прыгали между группами.
     */
    const syncMarkers = () => {
      const layer = markerLayerRef.current;
      if (!layer) return;
      layer.clearLayers();
      const pts = pointsRef.current;
      // Кадры в текущем виде: ноль — показываем «в этой области кадров нет».
      const view = map.getBounds().pad(0.05);
      let inView = 0;
      for (const p of pts) if (view.contains([p.lat, p.lon])) inView++;
      setVisibleCount(inView);
      if (!inView) return;

      const zoom = map.getZoom();
      const size = map.getSize();
      const cell = CLUSTER_PX;
      const margin = cell;
      const tl = map.getPixelBounds().min ?? L.point(0, 0);
      const cells = new Map<string, { lat: number; lon: number; n: number; ids: number[] }>();
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        const abs = map.project([p.lat, p.lon], zoom);
        const x = abs.x - tl.x;
        const y = abs.y - tl.y;
        if (x < -margin || y < -margin || x > size.x + margin || y > size.y + margin) continue;
        const key = cellKey(Math.floor(abs.x / cell), Math.floor(abs.y / cell));
        const c = cells.get(key);
        if (c) {
          c.n++;
          c.lat += p.lat;
          c.lon += p.lon;
          c.ids.push(i);
        } else {
          cells.set(key, { lat: p.lat, lon: p.lon, n: 1, ids: [i] });
        }
      }

      // Густые точки первыми: они уходят под мелкие и не закрывают их собой
      const list = [...cells.values()].sort((a, b) => b.n - a.n).slice(0, CLUSTER_MAX);
      for (const c of list) {
        const side = clusterSide(c.n);
        // ids идут в порядке ленты (points отсортированы от свежих): первым открываем
        // самый новый кадр группы, дальше листание идёт только по этой группе
        const group = c.ids;
        // Центр группы — среднее её кадров, а не первый попавшийся: точка стоит там,
        // где снимали, а не на краю клетки
        const icon = L.divIcon({
          className: 'map-cluster',
          html:
            `<img src="${api.thumbUrl(pts[group[0]].entryId)}" alt="" loading="lazy" decoding="async">` +
            // размер счётчика едет за размером точки: на мелких точках крупный бейдж не влезал
            (c.n > 1 ? `<i style="--side:${side}px">${c.n}</i>` : ''),
          iconSize: [side, side],
          iconAnchor: [side / 2, side / 2],
        });
        const marker = L.marker([c.lat / c.n, c.lon / c.n], { icon, keyboard: false, riseOnHover: true });
        marker.on('click', () => {
          groupRef.current = group;
          setOpenGroup(group);
          setOpenAt(0);
        });
        layer.addLayer(marker);
      }
    };

    markersRef.current = syncMarkers;

    let saveTimer: number | null = null;
    const onViewChange = () => {
      syncMarkers();
      if (saveTimer != null) window.clearTimeout(saveTimer);
      saveTimer = window.setTimeout(() => {
        const c = map.getCenter();
        patchUi({ map: { lat: c.lat, lon: c.lng, zoom: map.getZoom() } });
      }, 400);
    };
    map.on('moveend', onViewChange);
    map.on('zoomend', onViewChange);
    map.on('resize', syncMarkers);

    return () => {
      if (saveTimer != null) window.clearTimeout(saveTimer);
      map.off();
      map.remove();
      mapRef.current = null;
      markerLayerRef.current = null;
      markersRef.current = () => {};
    };
    // Карта создаётся один раз: смена вида и точек идёт через refs, а не пересоздание Leaflet.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Точки пришли (или изменились после удаления) — перерисовать слои.
  const fittedRef = useRef(false);
  useEffect(() => {
    if (points == null) return;
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

  /** Кадр открытой группы по её позиции: деталка работает с ней, а не со всей лентой. */
  const groupPoint = (i: number) => {
    const gi = groupRef.current?.[i];
    return gi == null ? undefined : pointsRef.current[gi];
  };

  const ensure = useCallback((start: number, end: number) => {
    const group = groupRef.current;
    if (!group) return;
    const from = Math.max(0, start);
    const to = Math.min(group.length - 1, end);
    for (let i = from; i <= to; i++) {
      const p = pointsRef.current[group[i]];
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
    const p = groupPoint(i);
    return p ? itemsRef.current.get(p.entryId) : undefined;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Удаление кадра: точка уходит с карты, а индексы и в списке точек, и в открытой группе
  // сдвигаются на единицу — как в ленте, иначе следующее листание открыло бы не тот кадр.
  const handleDelete = useCallback((pos: number) => {
    const group = groupRef.current;
    const gi = group?.[pos];
    if (!group || gi == null) return;
    const nextPoints = pointsRef.current.filter((_, i) => i !== gi);
    pointsRef.current = nextPoints;
    setPoints(nextPoints);
    const nextGroup = group.filter((_, i) => i !== pos).map((i) => (i > gi ? i - 1 : i));
    groupRef.current = nextGroup.length ? nextGroup : null;
    setOpenGroup(nextGroup.length ? nextGroup : null);
    setOpenAt(Math.min(pos, Math.max(0, nextGroup.length - 1)));
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
      </div>

      {openGroup && openGroup.length > 0 && (
        <MediaViewer
          total={openGroup.length}
          idx={openAt}
          getItem={getItem}
          ensure={ensure}
          onNavigate={setOpenAt}
          onClose={() => {
            groupRef.current = null;
            setOpenGroup(null);
          }}
          onDelete={handleDelete}
        />
      )}
    </div>
  );
}
