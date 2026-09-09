import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import * as api from './api';
import './styles.css';

type Tab = 'files' | 'photos' | 'shares' | 'albums' | 'settings';
const NAV: Array<{ id: Tab; icon: string; label: string }> = [
  { id: 'files', icon: '📁', label: 'Файлы' },
  { id: 'photos', icon: '🖼️', label: 'Фото' },
  { id: 'shares', icon: '🔗', label: 'Шаринг' },
  { id: 'albums', icon: '🗂️', label: 'Альбомы' },
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
      <header className="head">
        <strong>CloudlyRu</strong>
        <span className="meta">{user}</span>
      </header>
      <main className="content">
        {tab === 'files' && <Files />}
        {tab === 'photos' && <Photos />}
        {tab === 'shares' && <Shares />}
        {tab === 'albums' && <Albums />}
        {tab === 'settings' && <Settings login={user} onLogout={onLogout} />}
      </main>
      <nav className="nav">
        {NAV.map((n) => (
          <button key={n.id} className={tab === n.id ? 'navbtn active' : 'navbtn'} onClick={() => setTab(n.id)}>
            <span className="navico">{n.icon}</span>
            <span>{n.label}</span>
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
        <button className="btn" onClick={mkdir}>＋Папка</button>
        <label className="btn" style={{ display: 'inline-block' }}>⬆
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
  const [items, setItems] = useState<api.TimelineItem[]>([]);
  const [trips, setTrips] = useState<api.Trip[]>([]);
  const [activeTrip, setActiveTrip] = useState<string | null>(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    api.timeline().then(setItems).catch((e) => setErr((e as Error).message));
    api.trips().then(setTrips).catch(() => undefined);
  }, []);
  const isImg = (m: string) => /^image\//.test(m || '');
  return (
    <div>
      {err && <div className="err">{err}</div>}
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
        {items.map((it) => (
          <div key={it.entryId} style={{ width: '31.5%' }}>
            {isImg(it.mime) ? (
              <img src={api.fileUrl(it.entryId)} alt={it.name} loading="lazy"
                style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', borderRadius: 6, background: '#1b212b' }} />
            ) : (
              <div style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: '#1b212b', display: 'grid', placeItems: 'center' }}>🎞</div>
            )}
          </div>
        ))}
        {!items.length && <div className="copy">Нет фото — загрузите изображения</div>}
      </div>
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
      <div className="row"><button className="btn" onClick={create}>＋ Создать ссылку</button></div>
      {notice && <div className="notice">{notice}</div>}
      {err && <div className="err">{err}</div>}
      {items.map((s) => (
        <div className="item" key={s.token}>
          <span className="icon">🔗</span>
          <span className="fname">{s.kind} · {s.capability}{s.hasPassword ? ' · 🔒' : ''}{s.expiresAt ? ` · до ${new Date(s.expiresAt).toLocaleDateString()}` : ''}</span>
          <button className="btn ghost" onClick={() => { navigator.clipboard.writeText(s.url); setNotice('Скопировано'); }}>⧉</button>
          <button className="btn ghost" onClick={async () => { await api.revokeShare(s.token); await load(); }}>✕</button>
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
      <div className="row"><button className="btn" onClick={create}>＋ Альбом</button></div>
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
  const [showTrash, setShowTrash] = useState(false);
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
        <div className="row"><strong>Приложения (WebDAV/Finder)</strong><button className="btn" onClick={addToken}>＋ токен</button></div>
        {fresh && (
          <div className="panel" style={{ background: '#1c2430' }}>
            <div className="copy">Токен (показывается один раз): <b>{fresh}</b></div>
            <div className="copy">WebDAV: https://files.iq-factura.com/api/v1/dav · логин: {login}</div>
          </div>
        )}
        {err && <div className="err">{err}</div>}
        {tokens.map((t) => (
          <div className="item" key={t.id}>
            <span className="icon">🔑</span>
            <span className="fname">{t.label}</span>
            <span className="meta">{t.lastUsedAt ? new Date(t.lastUsedAt).toLocaleString() : 'не использовался'}</span>
            <button className="btn ghost" onClick={async () => { await api.revokeToken(t.id); await loadTokens(); }}>✕</button>
          </div>
        ))}
        {!tokens.length && <div className="copy">Токенов нет — нужен для Finder/WebDAV</div>}
      </div>
      <div className="panel">
        <div className="row"><strong>Корзина</strong><button className="btn ghost" onClick={() => setShowTrash(!showTrash)}>{showTrash ? 'скрыть' : 'открыть'}</button></div>
        {showTrash && <Trash />}
      </div>
    </div>
  );
}

function Trash() {
  const [view, setView] = useState<api.TrashView | null>(null);
  const [err, setErr] = useState('');
  const load = () => api.trash().then(setView).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);
  const restore = async (kind: 'folder' | 'file', id: string) => {
    try { await api.restoreItem(kind, id); await load(); } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      {err && <div className="err">{err}</div>}
      {[...(view?.folders || []).map((t) => ({ ...t, kind: 'folder' as const })), ...(view?.entries || []).map((t) => ({ ...t, kind: 'file' as const }))].map((t) => (
        <div className="item" key={t.kind + t.id}>
          <span className="icon">{t.kind === 'folder' ? '📁' : '📄'}</span>
          <span className="fname">{t.name}</span>
          <button className="btn ghost" onClick={() => restore(t.kind, t.id)}>восстановить</button>
        </div>
      ))}
      {!view?.folders.length && !view?.entries.length && <div className="copy">Корзина пуста</div>}
    </div>
  );
}

function fmt(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} КБ`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} ГБ`;
}
