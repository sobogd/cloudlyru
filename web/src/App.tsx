import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import * as api from './api';
import './styles.css';

type Tab = 'files' | 'photos' | 'shares' | 'albums' | 'trash' | 'settings';
const NAV: Array<{ id: Tab; icon: string; label: string }> = [
  { id: 'files', icon: '📁', label: 'Файлы' },
  { id: 'photos', icon: '🖼️', label: 'Фото' },
  { id: 'shares', icon: '🔗', label: 'Шаринг' },
  { id: 'albums', icon: '🗂️', label: 'Альбомы' },
  { id: 'trash', icon: '🗑️', label: 'Корзина' },
  { id: 'settings', icon: '⚙️', label: 'Настройки' },
];

export default function App() {
  const [user, setUser] = useState<{ login: string } | null>(null);
  const [checking, setChecking] = useState(true);
  useEffect(() => {
    api.me().then(setUser).catch(() => setUser(null)).finally(() => setChecking(false));
  }, []);
  if (checking) return <div className="app">…</div>;
  if (!user) return <Login onLogin={(u) => setUser(u)} />;
  return <Shell user={user.login} onLogout={() => setUser(null)} />;
}

function Login({ onLogin }: { onLogin: (u: { login: string }) => void }) {
  const [login, setLogin] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState('');
  const submit = async () => {
    try {
      const r = await api.login(login, password);
      onLogin(r.user);
    } catch (e) {
      setErr((e as Error).message);
    }
  };
  return (
    <div className="loginbox">
      <div style={{ fontSize: 34 }}>☁️</div>
      <h2 style={{ margin: '0 0 4px' }}>CloudlyRu</h2>
      <input placeholder="логин" value={login} onChange={(e) => setLogin(e.target.value)} />
      <input placeholder="пароль" type="password" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && submit()} />
      {err && <div className="err">{err}</div>}
      <button className="btn" onClick={submit}>Войти</button>
    </div>
  );
}

function Shell({ user, onLogout }: { user: string; onLogout: () => void }) {
  const [tab, setTab] = useState<Tab>('files');
  return (
    <div className="app">
      <main className="content">
        {tab === 'files' && <Files />}
        {tab === 'photos' && <Photos />}
        {tab === 'shares' && <Shares />}
        {tab === 'albums' && <Albums />}
        {tab === 'trash' && <TrashPage />}
        {tab === 'settings' && <Settings login={user} onLogout={onLogout} />}
      </main>
      <nav className="nav">
        {NAV.map((n) => (
          <button key={n.id} className={tab === n.id ? 'navbtn active' : 'navbtn'} onClick={() => setTab(n.id)} title={n.label} aria-label={n.label}>
            <span className="navico">{n.icon}</span>
          </button>
        ))}
      </nav>
    </div>
  );
}

// ================= Файлы =================

function Files() {
  const [stack, setStack] = useState<Array<{ id?: string; name: string }>>([{ name: 'Главная' }]);
  const [view, setView] = useState<api.FolderView | null>(null);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<number | null>(null);
  const currentId = stack[stack.length - 1]?.id;

  const load = async (parentId?: string) => {
    setErr('');
    try { setView(await api.listFolder(parentId)); } catch (e) { setErr((e as Error).message); }
  };
  useEffect(() => { void load(currentId); }, [currentId]);

  const mkdir = async () => {
    const name = prompt('Имя новой папки');
    if (!name) return;
    try { await api.mkdir(name, currentId); await load(currentId); } catch (e) { setErr((e as Error).message); }
  };
  const upload = async (files: FileList | null) => {
    if (!files || !files.length) return;
    setBusy(true);
    setErr('');
    try {
      for (const f of Array.from(files)) {
        await api.uploadFile(f, currentId, setProgress);
        setNotice(`Загружено: ${f.name}`);
      }
      await load(currentId);
    } catch (e) { setErr((e as Error).message); }
    finally { setBusy(false); setProgress(null); }
  };
  const rm = async (kind: 'folder' | 'file', id: string, name: string) => {
    if (!confirm(`Удалить «${name}» в корзину?`)) return;
    try {
      if (kind === 'folder') await api.deleteFolder(id); else await api.deleteFile(id);
      await load(currentId);
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <div>
      <div className="row">
        {stack.map((c, i) => (
          <span key={i}>
            {i > 0 && <span>/</span>}
            <button className="crumb" onClick={() => setStack((s) => s.slice(0, i + 1))}>{c.name}</button>
          </span>
        ))}
        <span style={{ flex: 1 }} />
        <button className="btn" onClick={mkdir}>📁 Папка</button>
        <label className="btn" style={{ display: 'inline-block' }}>📤 Загрузить
          <input type="file" multiple style={{ display: 'none' }} disabled={busy} onChange={(e) => void upload(e.target.files)} />
        </label>
      </div>
      {progress !== null && <progress value={progress} max={100} />}
      {notice && <div className="notice">{notice}</div>}
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {(view?.folders || []).map((f) => (
          <div className="item" key={f.id}>
            <span className="icon">📁</span>
            <span className="fname" onClick={() => setStack((s) => [...s, { id: f.id, name: f.name }])}>{f.name}</span>
            <button className="btn ghost" onClick={() => rm('folder', f.id, f.name)}>🗑</button>
          </div>
        ))}
        {(view?.entries || []).map((e) => (
          <div className="item" key={e.id}>
            <span className="icon">📄</span>
            <a className="fname" href={api.fileUrl(e.id)}>{e.name}</a>
            <span className="meta">{fmt(e.size || 0)}</span>
            <button className="btn ghost" onClick={() => rm('file', e.id, e.name)}>🗑</button>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && <div className="copy">Пусто</div>}
      </div>
    </div>
  );
}

// ================= Фото (умный вид: таймлайн + поездки + карта) =================

function Photos() {
  type Screen = { kind: 'grid' } | { kind: 'view'; idx: number } | { kind: 'upload' };
  const [items, setItems] = useState<api.TimelineItem[]>([]);
  const [trips, setTrips] = useState<api.Trip[]>([]);
  const [activeTrip, setActiveTrip] = useState<string | null>(null);
  const [screen, setScreen] = useState<Screen>({ kind: 'grid' });
  const [pending, setPending] = useState<File[] | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [info, setInfo] = useState(false);
  const isImg = (m: string) => /^image\//.test(m || '');
  const isVid = (m: string) => /^video\//.test(m || '');

  const load = async () => {
    try { setItems(await api.timeline()); } catch { /* keep old */ }
  };
  useEffect(() => { void load(); api.trips().then(setTrips).catch(() => undefined); }, []);
  // #7: автообновление статусов, пока что-то грузится/конвертируется или открыта деталка
  useEffect(() => {
    if (screen.kind === 'upload') return;
    const t = setInterval(() => { void load(); }, 3000);
    return () => clearInterval(t);
  }, [screen.kind]);

  const media = items.filter((it) => isImg(it.mime) || isVid(it.mime));
  const current = screen.kind === 'view' ? media[screen.idx] : null;
  const openUpload = (files: FileList | null) => {
    if (!files || !files.length) return;
    setPending(Array.from(files));
    setScreen({ kind: 'upload' });
  };

  // ===== Экран загрузки (#5) =====
  if (screen.kind === 'upload') {
    return <UploadFlow initial={pending} onDone={() => { setScreen({ kind: 'grid' }); setPending(null); void load(); }} />;
  }

  // ===== Экран деталки (#1-4) =====
  if (screen.kind === 'view' && current) {
    const it = current;
    return (
      <div className="full">
        <div className="tbar">
          <button className="iconbtn" title="Назад" onClick={() => setScreen({ kind: 'grid' })}>◀️</button>
          <span style={{ flex: 1 }} />
          <button className="iconbtn" title="Инфо" onClick={() => setInfo(!info)}>ℹ️</button>
          <a className="iconbtn" title="Оригинал (AVIF/AV1)" href={api.originalUrl(it.sha256!)} target="_blank" rel="noreferrer">🖼️</a>
          <button className="iconbtn" disabled={screen.idx === 0} title="Назад" onClick={() => { setScreen({ kind: 'view', idx: screen.idx - 1 }); setInfo(false); }}>⬅️</button>
          <button className="iconbtn" disabled={screen.idx >= media.length - 1} title="Вперёд" onClick={() => { setScreen({ kind: 'view', idx: screen.idx + 1 }); setInfo(false); }}>➡️</button>
        </div>
        {info && (
          <div className="copy" style={{ margin: '2px 10px 6px', color: '#b6c2d4' }}>
            {it.name}{it.capturedAt ? ` · ${new Date(it.capturedAt).toLocaleString()}` : ''}
          </div>
        )}

        {!it.masterReady ? (
          <div className="panel">
            {/* #2: статус/лог, пока грузится или ошибка */}
            <div className="copy">
              {it.jobState === 'failed'
                ? '❌ Ошибка конвертации'
                : it.jobState === 'processing'
                  ? `⏳ Конвертация: ${it.jobProgress ?? 0}%`
                  : it.jobState === 'pending'
                    ? '⏳ В очереди на конвертацию'
                    : '⏳ Загрузка/подготовка…'}
            </div>
            {it.jobState === 'processing' && <progress value={it.jobProgress ?? 0} max={100} />}
            {it.jobState === 'failed' && it.jobError && <pre className="copy" style={{ whiteSpace: 'pre-wrap', color: '#ff9c9c' }}>{it.jobError}</pre>}
            <div className="copy">Статус обновляется автоматически — можно не перезагружать страницу.</div>
          </div>
        ) : isVid(it.mime) ? (
          <div className="mediaarea">
            <video src={api.video720Url(it.sha256!)} controls autoPlay style={{ width: '100%', height: '100%', objectFit: 'contain' }} />
          </div>
        ) : (
          <div className="mediaarea">
            <PhotoZoom src={api.previewUrl(it.sha256!, 2048)} />
          </div>
        )}

      </div>
    );
  }

  // ===== Экран-сетка =====
  return (
    <div>
      <div className="row">
        <label className="btn" style={{ display: 'inline-block' }}>📤 Загрузить
          <input type="file" accept="image/*,video/*" multiple style={{ display: 'none' }} disabled={busy} onChange={openUpload} />
        </label>
        {err && <span className="err">{err}</span>}
      </div>
      {trips.length > 0 && (
        <div className="panel">
          <div className="meta">Поездки — нажми, чтобы увидеть маршрут</div>
          {trips.map((t) => (
            <div className="item" key={t.id} onClick={() => setActiveTrip(t.id === activeTrip ? null : t.id)} style={{ cursor: 'pointer' }}>
              <span className="icon">✈️</span>
              <span className="fname">{t.title}</span>
              <span className="meta">{t.count}</span>
            </div>
          ))}
        </div>
      )}
      {activeTrip && <TripMap trip={trips.find((t) => t.id === activeTrip)!} />}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
        {media.map((it, idx) => (
          <div key={it.entryId} style={{ width: '31.5%' }} onClick={() => setScreen({ kind: 'view', idx })}>
            {!it.masterReady ? (
              <div
                title={it.jobError || 'конвертация'}
                style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: '#14181f', display: 'grid', placeItems: 'center', color: it.jobState === 'failed' ? '#ff8a8a' : '#8a95a6', fontSize: 11, textAlign: 'center', padding: 4, cursor: 'pointer' }}
              >
                {it.jobState === 'failed' ? '❌ ошибка' : it.jobState === 'processing' ? <>⏳ {it.jobProgress ?? 0}%</> : it.jobState === 'pending' ? '⏳ в очереди' : '⏳'}
              </div>
            ) : it.sha256 ? (
              <div style={{ position: 'relative', cursor: 'pointer' }}>
                <LoadImg src={api.previewUrl(it.sha256, 512)} style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', borderRadius: 6, background: '#1b212b' }} />
                {isVid(it.mime) && <span style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: '#fff', fontSize: 28, textShadow: '0 0 12px #000' }}>▶</span>}
              </div>
            ) : (
              <div style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: '#1b212b', display: 'grid', placeItems: 'center' }}>📄</div>
            )}
          </div>
        ))}
        {!media.length && <div className="copy">Нет фото/видео — загрузите из галереи</div>}
      </div>
    </div>
  );
}


// Зум только для фото (щипок/дабл-тап/пан); страница при этом не зуммится
function PhotoZoom({ src }: { src: string }) {
  const [ok, setOk] = useState(false);
  const [v, setV] = useState({ s: 1, x: 0, y: 0 });
  const cur = useRef({ s: 1, x: 0, y: 0 });
  const pts = useRef(new Map<number, { x: number; y: number }>());
  const pinch0 = useRef(0);
  const pan0 = useRef({ x: 0, y: 0, px: 0, py: 0 });
  const lastTap = useRef(0);

  const clamp = (n: number) => Math.max(1, Math.min(5, n));
  const apply = (s: number, x: number, y: number) => {
    s = clamp(s);
    if (s <= 1) { x = 0; y = 0; }
    cur.current = { s, x, y };
    setV({ s, x, y });
  };

  const onTouchStart = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.set(t.identifier, { x: t.clientX, y: t.clientY }));
    if (pts.current.size === 2) {
      const [a, b] = [...pts.current.values()];
      pinch0.current = Math.hypot(a.x - b.x, a.y - b.y);
      pan0.current = { x: cur.current.x, y: cur.current.y, px: 0, py: 0 };
    } else if (pts.current.size === 1) {
      const p = pts.current.values().next().value;
      pan0.current = { x: cur.current.x, y: cur.current.y, px: p.x, py: p.y };
    }
  };
  const onTouchMove = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.set(t.identifier, { x: t.clientX, y: t.clientY }));
    const arr = [...pts.current.values()];
    if (arr.length === 2 && pinch0.current > 0) {
      const d = Math.hypot(arr[0].x - arr[1].x, arr[0].y - arr[1].y);
      apply(cur.current.s * (d / pinch0.current), cur.current.x, cur.current.y);
    } else if (arr.length === 1 && cur.current.s > 1) {
      const p = arr[0];
      apply(cur.current.s, pan0.current.x + (p.x - pan0.current.px), pan0.current.y + (p.y - pan0.current.py));
    }
  };
  const onTouchEnd = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.delete(t.identifier));
    if (pts.current.size === 0) {
      const now = Date.now();
      if (now - lastTap.current < 300) {
        if (cur.current.s > 1) apply(1, 0, 0); else apply(2.5, 0, 0);
      }
      lastTap.current = now;
    }
  };

  return (
    <div
      style={{ width: '100%', height: '100%', display: 'grid', placeItems: 'center', touchAction: 'none', overflow: 'hidden', position: 'relative' }}
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
    >
      {!ok && (
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center' }}><span className="spin" /></div>
      )}
      <img
        src={src}
        alt=""
        onLoad={() => setOk(true)}
        onError={() => setOk(true)}
        style={{
          maxWidth: '100%', maxHeight: '100%', objectFit: 'contain',
          transform: `translate(${v.x}px, ${v.y}px) scale(${v.s})`,
          transition: 'transform 120ms ease-out',
          opacity: ok ? 1 : 0,
        }}
      />
    </div>
  );
}

// #4: лоадер для изображений
function LoadImg({ src, style }: { src: string; style?: React.CSSProperties }) {
  const [ok, setOk] = useState(false);
  return (
    <div style={{ position: 'relative' }}>
      {!ok && (
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', minHeight: 120 }}>
          <span className="spin" />
        </div>
      )}
      <img src={src} alt="" style={{ ...style, visibility: ok ? 'visible' : 'hidden' }} onLoad={() => setOk(true)} onError={() => setOk(true)} loading="lazy" />
    </div>
  );
}

// #5: загрузка на отдельном экране с полным статусом
function UploadFlow({ initial, onDone }: { initial: File[] | null; onDone: () => void }) {
  const [rows, setRows] = useState<Array<{ name: string; size: number; pct: number; phase: string; error?: string }>>([]);
  const [overall, setOverall] = useState(0);
  const [running, setRunning] = useState(false);
  const [finished, setFinished] = useState(false);

  const run = async (files: File[]) => {
    const list = files.map((f) => ({ name: f.name, size: f.size, pct: 0, phase: 'ожидание' }));
    setRows(list); setRunning(true); setFinished(false); setOverall(0);
    let doneCnt = 0;
    for (let i = 0; i < list.length; i++) {
      const f = files[i];
      try {
        await api.uploadFile(f, undefined, (p) => {
          list[i].pct = p;
          list[i].phase = p >= 100 ? 'загружено — конвертация в фоне' : 'загрузка';
          setRows([...list]);
        });
        list[i].pct = 100;
        list[i].phase = 'загружено — конвертация в фоне';
      } catch (e) {
        list[i].error = (e as Error).message;
        list[i].phase = 'ошибка';
      }
      setRows([...list]);
      doneCnt += 1;
      setOverall(Math.round((doneCnt / list.length) * 100));
    }
    setRunning(false);
    setFinished(true);
  };
  const started = useRef(false);
  useEffect(() => {
    if (initial && !started.current) { started.current = true; void run(initial); }
  }, [initial]);

  return (
    <div>
      <div className="row"><button className="btn ghost" onClick={onDone}>← Фото</button><strong>Загрузка</strong></div>
      {rows.length > 0 && running && (
        <div className="notice" style={{ margin: '6px 0' }}>⚠ Не закрывайте и не обновляйте страницу, пока идёт загрузка.</div>
      )}
      {rows.length > 0 && (
        <div className="panel">
          {rows.map((it, i) => (
            <div className="item" key={i}>
              <span className="icon">{it.error ? '❌' : it.pct >= 100 ? '✅' : '⬆️'}</span>
              <span className="fname">{it.name}</span>
              <span className="meta">{it.error ? 'ошибка' : it.phase + (it.pct >= 100 || it.error ? '' : ` ${it.pct}%`)}</span>
              {!it.error && it.pct < 100 && <progress value={it.pct} max={100} />}
            </div>
          ))}
          <div className="row">
            <span className="meta">Всего: {overall}%</span>
            <progress value={overall} max={100} style={{ flex: 1 }} />
          </div>
          {finished && <button className="btn" onClick={onDone}>Готово — смотреть в «Фото»</button>}
        </div>
      )}
      {rows.length === 0 && !running && (
        <div className="panel">
          <label className="btn" style={{ display: 'inline-block', fontSize: 16, padding: '12px 20px' }}>📤 Выбрать фото/видео
            <input type="file" accept="image/*,video/*" multiple style={{ display: 'none' }} onChange={(e) => { if (e.target.files) void run(Array.from(e.target.files)); }} />
          </label>
          <div className="copy" style={{ marginTop: 8 }}>Файлы загрузятся по очереди. Не уходите со страницы до завершения.</div>
        </div>
      )}
    </div>
  );
}



function TripMap({ trip }: { trip: api.Trip }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!ref.current || !trip.points.length) return;
    const pts = trip.points.map((p) => [p.latitude, p.longitude] as [number, number]);
    const map = L.map(ref.current, { scrollWheelZoom: false });
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '© OpenStreetMap' }).addTo(map);
    L.polyline(pts, { color: '#2b6cff', weight: 3 }).addTo(map);
    L.marker(pts[0]).addTo(map).bindPopup('старт');
    if (pts.length > 1) L.marker(pts[pts.length - 1]).addTo(map).bindPopup('финиш');
    map.fitBounds(L.latLngBounds(pts).pad(0.25), { maxZoom: 13 });
    return () => { map.remove(); };
  }, [trip]);
  return <div className="panel" style={{ padding: 0 }}><div ref={ref} style={{ height: 320, borderRadius: 8 }} /></div>;
}

// ================= Шаринг =================

function Shares() {
  const [items, setItems] = useState<api.ShareInfo[]>([]);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const load = () => api.listShares().then(setItems).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);
  const create = async () => {
    const kind = (prompt('Тип (folder/file)') || 'folder').toLowerCase() === 'file' ? 'file' : 'folder';
    const targetId = prompt('targetId') || '';
    const password = prompt('Пароль (пусто = нет)') || undefined;
    const capability = prompt('Права VIEW/DOWNLOAD/UPLOAD/RW') || 'DOWNLOAD';
    const days = prompt('Срок (дней, пусто = без)');
    if (!targetId) return;
    try {
      const r = await api.createShare({ kind, targetId, password, capability, expiresAt: days ? new Date(Date.now() + Number(days) * 86400000).toISOString() : null });
      setNotice(r.url);
      await load();
    } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      <div className="row"><button className="btn" onClick={create}>🔗 Создать ссылку</button></div>
      {notice && <div className="notice">{notice}</div>}
      {err && <div className="err">{err}</div>}
      {items.map((s) => (
        <div className="item" key={s.token}>
          <span className="icon">🔗</span>
          <span className="fname">{s.kind} · {s.capability}{s.hasPassword ? ' · 🔒' : ''}{s.expiresAt ? ` · до ${new Date(s.expiresAt).toLocaleDateString()}` : ''}</span>
          <button className="btn ghost" onClick={() => { navigator.clipboard.writeText(s.url); setNotice('Скопировано'); }}>📋</button>
          <button className="btn ghost" onClick={async () => { await api.revokeShare(s.token); await load(); }}>🚫</button>
        </div>
      ))}
      {!items.length && <div className="copy">Активных шарингов нет</div>}
    </div>
  );
}

// ================= Альбомы =================

function Albums() {
  const [albums, setAlbums] = useState<api.AlbumInfo[]>([]);
  const [open, setOpen] = useState<api.AlbumView | null>(null);
  const [err, setErr] = useState('');
  const load = () => api.listAlbums().then(setAlbums).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);
  const create = async () => {
    const name = prompt('Имя альбома');
    if (!name) return;
    try { await api.createAlbum(name); await load(); } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      <div className="row"><button className="btn" onClick={create}>🗂️ Альбом</button></div>
      {err && <div className="err">{err}</div>}
      {albums.map((a) => (
        <div className="item" key={a.id}>
          <span className="icon">🗂️</span>
          <span className="fname" onClick={async () => { try { setOpen(await api.getAlbum(a.id)); } catch (e) { setErr((e as Error).message); } }}>{a.name}</span>
          <span className="meta">{a.count}</span>
          <button className="btn ghost" onClick={async () => { if (confirm('Удалить альбом?')) { await api.deleteAlbum(a.id); setOpen(null); await load(); } }}>🗑</button>
        </div>
      ))}
      {!albums.length && <div className="copy">Альбомов нет</div>}
      {open && (
        <div className="panel">
          <div className="row"><strong>{open.name}</strong><span className="copy">{open.items.length}</span>
            <button className="btn ghost" onClick={() => setOpen(null)}>закрыть</button></div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
            {open.items.map((it) => (
              <div key={it.entryId} style={{ width: '31.5%' }}>
                {/^image\//.test(it.mime) ? (
                  <img src={api.fileUrl(it.entryId)} alt={it.name} loading="lazy" style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', borderRadius: 6, background: '#1b212b' }} />
                ) : (
                  <div style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: '#1b212b', display: 'grid', placeItems: 'center' }}>📄</div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ================= Настройки =================

function Settings({ login, onLogout }: { login: string; onLogout: () => void }) {
  const [tokens, setTokens] = useState<api.ApiTokenRow[]>([]);
  const [fresh, setFresh] = useState<string | null>(null);
  const [err, setErr] = useState('');
  const loadTokens = () => api.listTokens().then(setTokens).catch((e) => setErr((e as Error).message));
  useEffect(() => { void loadTokens(); }, []);
  const addToken = async () => {
    const label = prompt('Метка (например finder)') || 'app';
    try {
      const r = await api.createToken(label);
      setFresh(r.token);
      await loadTokens();
    } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      <div className="panel">
        <div className="row"><span className="icon">👤</span><strong>{login}</strong></div>
        <div className="row">
          <a className="fname" href={location.origin}>{location.origin}</a>
          <button className="btn danger" onClick={async () => { await api.logout().catch(() => undefined); onLogout(); }}>Выйти</button>
        </div>
      </div>
      <div className="panel">
        <div className="row"><strong>Приложения (WebDAV/Finder)</strong><button className="btn" onClick={addToken}>🔑 токен</button></div>
        {fresh && (
          <div className="panel" style={{ background: '#1c2430' }}>
            <div className="copy">Токен (один раз): <b>{fresh}</b></div>
            <div className="copy">WebDAV: https://files.iq-factura.com/api/v1/dav · логин: {login}</div>
          </div>
        )}
        {err && <div className="err">{err}</div>}
        {tokens.map((t) => (
          <div className="item" key={t.id}>
            <span className="icon">🔑</span>
            <span className="fname">{t.label}</span>
            <span className="meta">{t.lastUsedAt ? new Date(t.lastUsedAt).toLocaleString() : 'не использовался'}</span>
            <button className="btn ghost" onClick={async () => { await api.revokeToken(t.id); await loadTokens(); }}>🚫</button>
          </div>
        ))}
        {!tokens.length && <div className="copy">Токенов нет — нужен для Finder/WebDAV</div>}
      </div>
    </div>
  );
}

// ================= Корзина =================

function TrashPage() {
  const [view, setView] = useState<api.TrashView | null>(null);
  const [err, setErr] = useState('');
  const load = () => api.trash().then(setView).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);
  const restore = async (kind: 'folder' | 'file', id: string) => {
    try { await api.restoreItem(kind, id); await load(); } catch (e) { setErr((e as Error).message); }
  };
  const purge = async () => {
    if (!confirm('Очистить корзину полностью? Удалённые файлы и превью будут стёрты безвозвратно.')) return;
    try { await api.purgeTrash(); await load(); } catch (e) { setErr((e as Error).message); }
  };
  const items = [
    ...(view?.folders || []).map((t) => ({ ...t, kind: 'folder' as const })),
    ...(view?.entries || []).map((t) => ({ ...t, kind: 'file' as const })),
  ];
  return (
    <div>
      <div className="row">
        <strong>Корзина</strong>
        <span style={{ flex: 1 }} />
        <button className="btn danger" onClick={purge}>🧹 Очистить</button>
      </div>
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {items.map((t) => (
          <div className="item" key={t.kind + t.id}>
            <span className="icon">{t.kind === 'folder' ? '📁' : '📄'}</span>
            <span className="fname">{t.name}</span>
            <span className="meta">{new Date(t.deletedAt).toLocaleString()}</span>
            <button className="btn ghost" onClick={() => restore(t.kind, t.id)}>восстановить</button>
          </div>
        ))}
        {!items.length && <div className="copy">Корзина пуста</div>}
      </div>
    </div>
  );
}

function fmt(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} КБ`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} ГБ`;
}
