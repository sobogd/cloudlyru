import { useEffect, useState } from 'react';
import * as api from './api';
import './styles.css';

type Section = 'files' | 'shares' | 'trash' | 'timeline' | 'albums';
interface Crumb { id?: string; name: string }

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
      <h2>CloudlyRu</h2>
      <input placeholder="логин" value={login} onChange={(e) => setLogin(e.target.value)} />
      <input placeholder="пароль" type="password" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && submit()} />
      {err && <div className="err">{err}</div>}
      <button className="btn" onClick={submit}>Войти</button>
    </div>
  );
}

function Shell({ user, onLogout }: { user: string; onLogout: () => void }) {
  const [tab, setTab] = useState<Section>('files');
  return (
    <div className="app">
      <div className="topbar">
        <h1>CloudlyRu · {user}</h1>
        <button className={tab === 'files' ? 'tab active' : 'tab'} onClick={() => setTab('files')}>Файлы</button>
        <button className={tab === 'shares' ? 'tab active' : 'tab'} onClick={() => setTab('shares')}>Шаринг</button>
        <button className={tab === 'timeline' ? 'tab active' : 'tab'} onClick={() => setTab('timeline')}>Таймлайн</button>
        <button className={tab === 'albums' ? 'tab active' : 'tab'} onClick={() => setTab('albums')}>Альбомы</button>
        <button className={tab === 'trash' ? 'tab active' : 'tab'} onClick={() => setTab('trash')}>Корзина</button>
        <button className="btn ghost" onClick={async () => { await api.logout().catch(() => undefined); onLogout(); }}>Выйти</button>
      </div>
      {tab === 'files' && <Files />}
      {tab === 'shares' && <Shares />}
      {tab === 'trash' && <Trash />}
      {tab === 'timeline' && <Timeline />}
      {tab === 'albums' && <Albums />}
    </div>
  );
}

function Files() {
  const [stack, setStack] = useState<Crumb[]>([{ name: 'Главная' }]);
  const [view, setView] = useState<api.FolderView | null>(null);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<number | null>(null);
  const currentId = stack[stack.length - 1]?.id;

  const load = async (parentId?: string) => {
    setErr('');
    try {
      setView(await api.listFolder(parentId));
    } catch (e) {
      setErr((e as Error).message);
    }
  };
  useEffect(() => { void load(currentId); }, [currentId]);

  const open = (id: string, name: string) => {
    setStack((s) => [...s, { id, name }]);
  };
  const toCrumb = (i: number) => setStack((s) => s.slice(0, i + 1));

  const mkdir = async () => {
    const name = prompt('Имя новой папки');
    if (!name) return;
    try {
      await api.mkdir(name, currentId);
      await load(currentId);
    } catch (e) { setErr((e as Error).message); }
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
            <button className="crumb" onClick={() => toCrumb(i)}>{c.name}</button>
          </span>
        ))}
        <span style={{ flex: 1 }} />
        <button className="btn" onClick={mkdir}>Новая папка</button>
        <label className="btn" style={{ display: 'inline-block' }}>Загрузить
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
            <span className="fname" onClick={() => open(f.id, f.name)}>{f.name}</span>
            <button className="btn ghost" onClick={() => rm('folder', f.id, f.name)}>🗑</button>
          </div>
        ))}
        {(view?.entries || []).map((e) => (
          <div className="item" key={e.id}>
            <span className="icon">📄</span>
            <a className="fname" href={api.fileUrl(e.id)} onClick={(ev) => { ev.preventDefault(); window.location.href = api.fileUrl(e.id); }}>{e.name}</a>
            <span className="meta">{fmt(e.size || 0)} · {e.mime || ''}</span>
            <button className="btn ghost" onClick={() => rm('file', e.id, e.name)}>🗑</button>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && <div className="copy">Пусто</div>}
      </div>
    </div>
  );
}

function Shares() {
  const [items, setItems] = useState<api.ShareInfo[]>([]);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const load = () => api.listShares().then(setItems).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);

  const create = async () => {
    const kind = (prompt('Тип: folder или file') || 'folder').toLowerCase();
    const targetId = prompt('targetId (id папки/файла — виден в ответе API, для M1 вводим вручную)');
    const password = prompt('Пароль (пусто = без пароля)') || undefined;
    const cap = prompt('Права: VIEW|DOWNLOAD|UPLOAD|RW') || 'DOWNLOAD';
    const days = prompt('Срок действия в днях (пусто = без срока)');
    if (!targetId) return;
    try {
      const r = await api.createShare({
        kind: kind === 'file' ? 'file' : 'folder',
        targetId,
        password,
        capability: cap,
        expiresAt: days ? new Date(Date.now() + Number(days) * 86400000).toISOString() : null,
      });
      setNotice(`Готово: ${r.url}`);
      await load();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <div>
      <div className="row">
        <button className="btn" onClick={create}>Создать шаринг</button>
        <span className="copy">targetId — из списка файлов (id виден в консоли/API).</span>
      </div>
      {notice && <div className="notice">{notice}</div>}
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {items.map((s) => (
          <div className="item" key={s.token}>
            <span className="icon">🔗</span>
            <span className="fname">{s.kind} · {s.capability}{s.hasPassword ? ' · 🔒' : ''}{s.expiresAt ? ` · до ${new Date(s.expiresAt).toLocaleDateString()}` : ''}</span>
            <span className="copy">{s.url}</span>
            <button className="btn ghost" onClick={() => { navigator.clipboard.writeText(s.url); setNotice('Скопировано'); }}>копия</button>
            <button className="btn danger" onClick={async () => { await api.revokeShare(s.token); await load(); }}>отозвать</button>
          </div>
        ))}
        {!items.length && <div className="copy">Пока нет активных шарингов</div>}
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
  const purge = async () => {
    if (!confirm('Очистить корзину полностью?')) return;
    try { await api.purgeTrash(); await load(); } catch (e) { setErr((e as Error).message); }
  };

  return (
    <div>
      <div className="row"><button className="btn danger" onClick={purge}>Очистить корзину</button></div>
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {[...(view?.folders || []).map((t) => ({ ...t, kind: 'folder' as const })), ...(view?.entries || []).map((t) => ({ ...t, kind: 'file' as const }))].map((t) => (
          <div className="item" key={t.kind + t.id}>
            <span className="icon">{t.kind === 'folder' ? '📁' : '📄'}</span>
            <span className="fname">{t.name}</span>
            <span className="meta">{new Date(t.deletedAt).toLocaleString()}</span>
            <button className="btn ghost" onClick={() => restore(t.kind, t.id)}>восстановить</button>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && <div className="copy">Корзина пуста</div>}
      </div>
    </div>
  );
}

function Timeline() {
  const [items, setItems] = useState<api.TimelineItem[]>([]);
  const [trips, setTrips] = useState<api.Trip[]>([]);
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
          <h3>Поездки ({trips.length})</h3>
          {trips.map((t) => (
            <div className="item" key={t.id}>
              <span className="icon">✈️</span>
              <span className="fname">{t.title}</span>
              <span className="meta">{t.count} точек на карте</span>
            </div>
          ))}
          <div className="copy">Карта появится в следующем шаге M2.</div>
        </div>
      )}
      <div className="panel">
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
          {items.map((it) => (
            <div key={it.entryId} style={{ width: 150 }}>
              {isImg(it.mime) ? (
                <img src={api.fileUrl(it.entryId)} alt={it.name} loading="lazy"
                  style={{ width: 150, height: 150, objectFit: 'cover', borderRadius: 8, background: '#1b212b' }} />
              ) : (
                <div style={{ width: 150, height: 150, borderRadius: 8, background: '#1b212b', display: 'grid', placeItems: 'center' }}>🎞</div>
              )}
              <div className="meta" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{it.name}</div>
              {it.capturedAt && <div className="meta">{new Date(it.capturedAt).toLocaleString()}</div>}
            </div>
          ))}
          {!items.length && <div className="copy">Нет фото с метаданными — загрузите изображение</div>}
        </div>
      </div>
    </div>
  );
}

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
  const openAlbum = async (id: string) => {
    try { setOpen(await api.getAlbum(id)); } catch (e) { setErr((e as Error).message); }
  };
  const del = async (id: string) => {
    if (!confirm('Удалить альбом?')) return;
    try { await api.deleteAlbum(id); setOpen(null); await load(); } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      <div className="row"><button className="btn" onClick={create}>Новый альбом</button></div>
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {albums.map((a) => (
          <div className="item" key={a.id}>
            <span className="icon">🗂️</span>
            <span className="fname" onClick={() => openAlbum(a.id)}>{a.name}</span>
            <span className="meta">{a.count} файлов</span>
            <button className="btn ghost" onClick={() => del(a.id)}>🗑</button>
          </div>
        ))}
        {!albums.length && <div className="copy">Альбомов нет</div>}
      </div>
      {open && (
        <div className="panel">
          <h3>{open.name} — {open.items.length} файлов</h3>
          <div className="row"><span className="copy">Добавить текущие файлы папки можно через API/WebDAV (M3 добавит UI-выбор).</span></div>
          {open.items.map((it) => (
            <div className="item" key={it.entryId}>
              <span className="icon">📄</span>
              <a className="fname" href={api.fileUrl(it.entryId)}>{it.name}</a>
              <span className="meta">{it.capturedAt ? new Date(it.capturedAt).toLocaleDateString() : ''}</span>
            </div>
          ))}
          {!open.items.length && <div className="copy">Пусто</div>}
        </div>
      )}
    </div>
  );
}

function fmt(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} КБ`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} ГБ`;
}
