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
  const [user, setUser] = useState<api.UserInfo | null>(null);
  const [checking, setChecking] = useState(true);
  useEffect(() => {
    api.me().then(setUser).catch(() => setUser(null)).finally(() => setChecking(false));
  }, []);
  if (checking) return <div className="app">…</div>;
  if (!user) return <Login onLogin={(u) => setUser(u)} />;
  return <Shell user={user} onLogout={() => setUser(null)} />;
}

function Login({ onLogin }: { onLogin: (u: api.UserInfo) => void }) {
  const [login, setLogin] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState('');
  const submit = async () => {
    try {
      await api.login(login, password);
      onLogin(await api.me());
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

function Shell({ user, onLogout }: { user: api.UserInfo; onLogout: () => void }) {
  const [tab, setTab] = useState<Tab>('files');
  return (
    <div className="app">
      <main className="content">
        {tab === 'files' && <Files photoFolderId={user.photoFolderId} />}
        {tab === 'photos' && <Photos photoFolderId={user.photoFolderId} />}
        {tab === 'shares' && <Shares />}
        {tab === 'albums' && <Albums />}
        {tab === 'trash' && <TrashPage />}
        {tab === 'settings' && <Settings login={user.login} onLogout={onLogout} />}
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

function fileIcon(mime?: string): string {
  if (!mime) return '📄';
  if (mime.startsWith('image/')) return '🖼️';
  if (mime.startsWith('video/')) return '🎬';
  return '📄';
}

function Files({ photoFolderId }: { photoFolderId: string | null }) {
  const [stack, setStack] = useState<Array<{ id?: string; name: string }>>([{ name: 'Главная' }]);
  const [view, setView] = useState<api.FolderView | null>(null);
  const [err, setErr] = useState('');
  const [page, setPage] = useState<'list' | 'upload'>('list');
  const currentId = stack[stack.length - 1]?.id;
  const currentName = stack[stack.length - 1]?.name ?? 'Главная';

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
  const rm = async (kind: 'folder' | 'file', id: string, name: string) => {
    if (!confirm(`Удалить «${name}» в корзину?`)) return;
    try {
      if (kind === 'folder') await api.deleteFolder(id); else await api.deleteFile(id);
      await load(currentId);
    } catch (e) { setErr((e as Error).message); }
  };

  // Отдельная страница загрузки в текущую папку
  if (page === 'upload') {
    return (
      <UploadPage
        folderId={currentId}
        folderName={currentName}
        photoFolderId={photoFolderId}
        onClose={() => { setPage('list'); void load(currentId); }}
      />
    );
  }

  return (
    <div>
      <div className="filehead">
        <div className="crumbs">
          {stack.map((c, i) => (
            <span key={i}>
              {i > 0 && <span className="meta">/</span>}
              <button className="crumb" onClick={() => setStack((s) => s.slice(0, i + 1))}>{c.name}</button>
            </span>
          ))}
        </div>
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Новая папка" onClick={mkdir}>➕</button>
        <button className="iconbtn" title="Загрузить в эту папку" onClick={() => setPage('upload')}>⬆️</button>
      </div>
      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      <div className="panel">
        {(view?.folders || []).filter((f) => f.id !== photoFolderId).map((f) => (
          <div className="item" key={f.id}>
            <span className="icon">📁</span>
            <span className="fname" onClick={() => setStack((s) => [...s, { id: f.id, name: f.name }])}>{f.name}</span>
            <button className="btn ghost" onClick={() => rm('folder', f.id, f.name)}>🗑</button>
          </div>
        ))}
        {(view?.entries || []).map((e) => (
          <div className="item" key={e.id}>
            <span className="icon">{fileIcon(e.mime)}</span>
            <a className="fname" href={api.fileUrl(e.id)}>{e.name}</a>
            <span className="meta">{fmt(e.size || 0)}</span>
            <button className="btn ghost" onClick={() => rm('file', e.id, e.name)}>🗑</button>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && <div className="copy">Пусто — нажмите ⬆️, чтобы загрузить файлы в эту папку</div>}
      </div>
    </div>
  );
}

// ================= Страница загрузки (в конкретную папку) =================
// Кнопки «Фото / Видео / Документы» открывают правильный системный пикер
// (галерея для фото/видео, файлы — для документов), дальше — очередь с
// прогрессом, статусами, повтором ошибок и предупреждением не уходить.

type UpKind = 'photo' | 'video' | 'doc';
interface UpRow {
  key: string;
  file: File;
  name: string;
  size: number;
  kind: UpKind;
  state: 'queued' | 'uploading' | 'done' | 'failed';
  pct: number;
  error?: string;
}
const UP_META: Record<UpKind, { icon: string; label: string; accept: string; hint: string }> = {
  photo: { icon: '📷', label: 'Фото', accept: 'image/*', hint: 'откроется галерея' },
  video: { icon: '🎬', label: 'Видео', accept: 'video/*', hint: 'галерея/видео' },
  doc: { icon: '📄', label: 'Документы', accept: '', hint: 'любые файлы' },
};
let upKey = 0;

function UploadPage({ folderId, folderName, photoFolderId, onClose }: { folderId?: string; folderName: string; photoFolderId?: string | null; onClose: () => void }) {
  const rows = useRef<UpRow[]>([]);
  // «Фото» (медиа-зона): файлы конвертируются в AVIF/AV1 и появляются в разделе «Фото»;
  // обычные папки: файлы ложатся как есть, без конвертации
  const isPhotoLibrary = Boolean(folderId && photoFolderId && folderId === photoFolderId);
  const [, force] = useState(0);
  const [skipNote, setSkipNote] = useState('');
  const running = useRef(false);
  const stopped = useRef(false);
  const ctrl = useRef<AbortController | null>(null);
  const render = () => force((n) => n + 1);

  const pump = async () => {
    if (running.current) return;
    running.current = true;
    stopped.current = false;
    render();
    try {
      for (;;) {
        const i = rows.current.findIndex((r) => r.state === 'queued');
        if (i < 0 || stopped.current) break;
        const row = rows.current[i];
        row.state = 'uploading';
        row.pct = 0;
        render();
        const ac = new AbortController();
        ctrl.current = ac;
        try {
          await api.uploadFile(row.file, folderId, (p) => { row.pct = p; render(); }, ac.signal);
          row.state = 'done';
          row.pct = 100;
        } catch (e) {
          row.state = 'failed';
          row.pct = Math.min(row.pct, 99);
          row.error = ac.signal.aborted ? 'загрузка остановлена' : (e as Error).message || 'ошибка';
        } finally {
          ctrl.current = null;
        }
        render();
      }
    } finally {
      running.current = false;
      render();
    }
  };

  const addEntries = (files: File[], kind: UpKind | null) => {
    if (!files.length || running.current) return;
    for (const f of files) {
      const k = kind ?? (api.guessMime(f).startsWith('image/') ? 'photo' : api.guessMime(f).startsWith('video/') ? 'video' : 'doc');
      if (isPhotoLibrary && k === 'doc') {
        setSkipNote(`«${f.name}» — в «Фото» можно загружать только фото и видео`);
        continue;
      }
      setSkipNote('');
      rows.current.push({ key: `up${++upKey}`, file: f, name: f.name, size: f.size, kind: k, state: 'queued', pct: 0 });
    }
    render();
    void pump();
  };

  const retry = (i: number) => {
    const row = rows.current[i];
    if (!row || row.state !== 'failed') return;
    row.state = 'queued';
    row.pct = 0;
    row.error = undefined;
    render();
    void pump();
  };
  const stop = () => {
    stopped.current = true;
    ctrl.current?.abort();
  };

  // предупреждение при попытке уйти со страницы во время загрузки
  useEffect(() => {
    if (!running.current && !rows.current.some((r) => r.state === 'queued' || r.state === 'uploading')) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', h);
    return () => window.removeEventListener('beforeunload', h);
  });
  // уход со страницы (переключение вкладки) — отменяем активную загрузку
  useEffect(() => () => { ctrl.current?.abort(); }, []);

  const all = rows.current;
  const totalBytes = all.reduce((s, r) => s + r.size, 0);
  const gotBytes = all.reduce((s, r) => s + Math.round((r.size * r.pct) / 100), 0);
  const doneN = all.filter((r) => r.state === 'done').length;
  const failN = all.filter((r) => r.state === 'failed').length;
  const busyN = all.filter((r) => r.state === 'queued' || r.state === 'uploading').length;
  const pct = totalBytes ? Math.round((gotBytes / totalBytes) * 100) : 0;

  return (
    <div>
      <div className="filehead">
        <button className="iconbtn" title="Назад к файлам" onClick={onClose}>⬅️</button>
        <span style={{ flex: 1 }} />
        <strong className="up-title">Загрузка</strong>
        <span style={{ flex: 1 }} />
        <span style={{ width: 34 }} />
      </div>

      <div className="copy" style={{ margin: '10px 2px' }}>
        {isPhotoLibrary ? (
          <>Куда: <b>{folderName}</b> — фото/видео будут оптимизированы (AVIF/AV1 + превью) и появятся в разделе «Фото». Документы сюда загружать нельзя.</>
        ) : (
          <>Куда: <b>{folderName}</b> — файлы сохранятся как есть, без конвертации. Фото/видео с оптимизацией загружайте в разделе «Фото».</>
        )}
      </div>

      <div
        className="updrop"
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          if (e.dataTransfer?.files?.length) addEntries(Array.from(e.dataTransfer.files), null);
        }}
      >
        <div className="copy">Перетащите файлы сюда (можно несколько) — или выберите тип ниже</div>
      </div>

      {skipNote && <div className="notice" style={{ margin: '8px 2px' }}>⚠ {skipNote}</div>}

      <div className="upgrid">
        {(Object.keys(UP_META) as UpKind[]).filter((k) => !(isPhotoLibrary && k === 'doc')).map((k) => (
          <label key={k} className="upbtn">
            <input
              type="file"
              accept={UP_META[k].accept}
              multiple
              disabled={running.current}
              onChange={(e) => {
                if (e.target.files?.length) addEntries(Array.from(e.target.files), k);
                e.target.value = '';
              }}
            />
            <div className="upbtn-ico">{UP_META[k].icon}</div>
            <div className="upbtn-label">{UP_META[k].label}</div>
            <div className="meta">{UP_META[k].hint}</div>
          </label>
        ))}
      </div>

      {all.length > 0 && (
        <div className="panel" style={{ padding: '4px 12px' }}>
          {all.map((r, i) => (
            <div className="uprow" key={r.key}>
              <span className="icon">{r.state === 'done' ? '✅' : r.state === 'failed' ? '❌' : r.state === 'uploading' ? '⏳' : '🕒'}</span>
              <div className="upmain">
                <div className="upname">{r.name} <span className="meta">{fmt(r.size)}</span></div>
                <div className="upmeta">
                  {r.state === 'queued' && 'в очереди…'}
                  {r.state === 'uploading' && `загрузка ${r.pct}%`}
                  {r.state === 'done' && (isPhotoLibrary && r.kind !== 'doc' ? 'загружено · конвертация в фоне' : 'загружено')}
                  {r.state === 'failed' && `ошибка: ${r.error}`}
                </div>
                {r.state === 'uploading' && <progress value={r.pct} max={100} />}
                {r.state === 'queued' && <div className="ubar"><i style={{ width: 0 }} /></div>}
                {r.state === 'done' && <div className="ubar"><i style={{ width: '100%', background: '#2fae5f' }} /></div>}
                {r.state === 'failed' && (
                  <div className="row" style={{ margin: '2px 0 0' }}>
                    <button className="btn ghost" onClick={() => retry(i)}>⟳ Повторить</button>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {all.length > 0 && (
        <div className="panel">
          <div className="row" style={{ margin: '0 0 8px' }}>
            <span className="meta">Загружено {doneN} из {all.length} · {pct}%</span>
            <span style={{ flex: 1 }} />
            {running.current && <button className="btn danger" onClick={stop}>⏹ Остановить</button>}
            {!running.current && busyN > 0 && <button className="btn" onClick={() => void pump()}>▶ Продолжить</button>}
            {!running.current && busyN === 0 && failN > 0 && (
              <button className="btn" onClick={() => { rows.current.forEach((r, i) => { if (r.state === 'failed') retry(i); }); }}>⟳ Повторить ошибки</button>
            )}
          </div>
          <progress value={pct} max={100} />
          {!running.current && busyN === 0 && doneN === all.length && doneN > 0 && (
            <div className="notice" style={{ margin: '10px 0 4px' }}>
              ✅ Готово: {doneN} файлов загружено в «{folderName}»{isPhotoLibrary ? ' — конвертация выполняется в фоне' : ''}
            </div>
          )}
          {!running.current && busyN === 0 && failN > 0 && (
            <div className="err" style={{ margin: '10px 0 4px' }}>Не загрузилось файлов: {failN}</div>
          )}
          {!running.current && busyN === 0 && (
            <button className="btn" style={{ width: '100%', marginTop: 10 }} onClick={onClose}>Готово — вернуться в папку</button>
          )}
        </div>
      )}

      {all.length > 0 && running.current && (
        <div className="notice" style={{ margin: '8px 2px' }}>⚠ Не закрывайте и не обновляйте страницу, пока идёт загрузка</div>
      )}
    </div>
  );
}

// ================= Фото (медиатека: таймлайн + поездки + карта) =================
// Показывает только содержимое системной папки «Фото» (зона PHOTOS); сама папка скрыта из
// «Файлы» и WebDAV. Загрузка — через ⬆️ (только фото/видео), удаление — из деталки в корзину.

function Photos({ photoFolderId }: { photoFolderId: string | null }) {
  type Screen = { kind: 'grid' } | { kind: 'view'; idx: number };
  const [items, setItems] = useState<api.TimelineItem[]>([]);
  const [trips, setTrips] = useState<api.Trip[]>([]);
  const [activeTrip, setActiveTrip] = useState<string | null>(null);
  const [screen, setScreen] = useState<Screen>({ kind: 'grid' });
  const [upload, setUpload] = useState(false);
  const [info, setInfo] = useState(false);
  const isImg = (m: string) => /^image\//.test(m || '');
  const isVid = (m: string) => /^video\//.test(m || '');

  const load = async () => {
    try { setItems(await api.timeline()); } catch { /* keep old */ }
  };
  useEffect(() => { void load(); api.trips().then(setTrips).catch(() => undefined); }, []);
  // автообновление статусов конвертации
  useEffect(() => {
    const t = setInterval(() => { void load(); }, 3000);
    return () => clearInterval(t);
  }, []);

  // ===== Прямая загрузка в медиатеку «Фото» =====
  if (upload) {
    return (
      <UploadPage
        folderId={photoFolderId ?? undefined}
        folderName="Фото"
        photoFolderId={photoFolderId}
        onClose={() => { setUpload(false); void load(); api.trips().then(setTrips).catch(() => undefined); }}
      />
    );
  }

  const media = items.filter((it) => isImg(it.mime) || isVid(it.mime));
  const current = screen.kind === 'view' ? media[screen.idx] : null;

  // ===== Экран деталки (#1-4) =====
  if (screen.kind === 'view' && current) {
    const it = current;
    return (
      <div className="full">
        {/* медиа занимает весь канвас (верх экрана → нав-бар); шапка/инфо — поверх */}
        <div className="mediaarea">
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
            <video src={api.video720Url(it.sha256!)} controls autoPlay style={{ width: '100%', height: '100%', objectFit: 'contain', display: 'block' }} />
          ) : (
            <PhotoZoom src={api.previewUrl(it.sha256!, 2048)} />
          )}
        </div>
        <div className="tbar">
          <button className="iconbtn" title="Назад" onClick={() => setScreen({ kind: 'grid' })}>◀️</button>
          <span style={{ flex: 1 }} />
          <button className="iconbtn" title="Инфо" onClick={() => setInfo(!info)}>ℹ️</button>
          <a className="iconbtn" title="Оригинал (AVIF/AV1)" href={api.originalUrl(it.sha256!)} target="_blank" rel="noreferrer">🖼️</a>
          <button
            className="iconbtn"
            title="Удалить (в корзину)"
            onClick={async () => {
              if (!confirm(`Удалить «${it.name}» в корзину?`)) return;
              try {
                await api.deleteFile(it.entryId);
                setScreen({ kind: 'grid' });
                void load();
              } catch (e) {
                alert((e as Error).message);
              }
            }}
          >🗑</button>
          <button className="iconbtn" disabled={screen.idx === 0} title="Назад" onClick={() => { setScreen({ kind: 'view', idx: screen.idx - 1 }); setInfo(false); }}>⬅️</button>
          <button className="iconbtn" disabled={screen.idx >= media.length - 1} title="Вперёд" onClick={() => { setScreen({ kind: 'view', idx: screen.idx + 1 }); setInfo(false); }}>➡️</button>
        </div>
        {info && (
          <div className="det-info">
            {it.name}{it.capturedAt ? ` · ${new Date(it.capturedAt).toLocaleString()}` : ''}
          </div>
        )}
      </div>
    );
  }

  // ===== Экран-сетка =====
  return (
    <div>
      <div className="filehead">
        <strong>Фото</strong>
        <span style={{ flex: 1 }} />
        {photoFolderId && (
          <button className="iconbtn" title="Загрузить фото/видео в «Фото» (с оптимизацией)" onClick={() => setUpload(true)}>⬆️</button>
        )}
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
        {!media.length && <div className="copy">Нет фото и видео. Загрузите их через ⬆️ — медиа оптимизируется и появится здесь автоматически.</div>}
      </div>
    </div>
  );
}


// Зум только для фото (щипок/дабл-тап/пан); страница при этом не зуммится
function PhotoZoom({ src }: { src: string }) {
  const box = useRef<HTMLDivElement>(null);
  const [loaded, setLoaded] = useState(false);
  const nat = useRef({ w: 0, h: 0 });
  const [g, setG] = useState({ ox: 0, oy: 0, bw: 1, bh: 1, z: 1, tx: 0, ty: 0 });
  const gcur = useRef(g);
  const pts = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef({ d0: 0, z0: 1, ix: 0, iy: 0 });
  const pan0 = useRef({ tx: 0, ty: 0, px: 0, py: 0 });
  const lastTap = useRef(0);
  const [ready, setReady] = useState(false);

  const clampN = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

  const rect = () => box.current?.getBoundingClientRect() ?? { width: 0, height: 0, left: 0, top: 0 };

  // геометрия: fit по контейнеру, вертикально и горизонтально по центру
  const geometry = () => {
    const r = rect();
    const nw = nat.current.w || 1;
    const nh = nat.current.h || 1;
    const fit = Math.min(r.width / nw, r.height / nh);
    const bw = nw * fit;
    const bh = nh * fit;
    const ox = (r.width - bw) / 2;
    const oy = (r.height - bh) / 2;
    return { w: r.width, h: r.height, ox, oy, bw, bh };
  };

  const commit = (z: number, tx: number, ty: number) => {
    const geo = geometry();
    z = clampN(z, 1, 8);
    const w = geo.bw * z;
    const h = geo.bh * z;
    // горизонталь: панорама не дальше краёв изображения; если уже контейнера — центр
    if (w >= geo.w) {
      tx = clampN(tx, geo.w - w - geo.ox, -geo.ox);
    } else {
      tx = (geo.w - w) / 2 - geo.ox;
    }
    // вертикаль: та же логика
    if (h >= geo.h) {
      ty = clampN(ty, geo.h - h - geo.oy, -geo.oy);
    } else {
      ty = (geo.h - h) / 2 - geo.oy;
    }
    if (z <= 1.001) { z = 1; tx = 0; ty = 0; }
    const ng = { ox: geo.ox, oy: geo.oy, bw: geo.bw, bh: geo.bh, z, tx, ty };
    gcur.current = ng;
    setG(ng);
  };

  const onTouchStart = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.set(t.identifier, { x: t.clientX, y: t.clientY }));
    const r = rect();
    const arr = [...pts.current.values()];
    if (arr.length === 2) {
      const mx = (arr[0].x + arr[1].x) / 2 - r.left;
      const my = (arr[0].y + arr[1].y) / 2 - r.top;
      const cur = gcur.current;
      pinch.current = {
        d0: Math.hypot(arr[0].x - arr[1].x, arr[0].y - arr[1].y),
        z0: cur.z,
        // точка изображения под серединой пальцев (в координатах «базового» изображения)
        ix: (mx - (cur.ox + cur.tx)) / cur.z,
        iy: (my - (cur.oy + cur.ty)) / cur.z,
      };
    } else if (arr.length === 1) {
      const p = arr[0];
      pan0.current = { tx: gcur.current.tx, ty: gcur.current.ty, px: p.x, py: p.y };
    }
  };

  const onTouchMove = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.set(t.identifier, { x: t.clientX, y: t.clientY }));
    const arr = [...pts.current.values()];
    const r = rect();
    if (arr.length === 2 && pinch.current.d0 > 0) {
      const d = Math.hypot(arr[0].x - arr[1].x, arr[0].y - arr[1].y);
      const z = pinch.current.z0 * (d / pinch.current.d0);
      const mx = (arr[0].x + arr[1].x) / 2 - r.left;
      const my = (arr[0].y + arr[1].y) / 2 - r.top;
      const cur = gcur.current;
      // держим точку между пальцами на месте (зум «в точку щипка»)
      const tx = mx - cur.ox - pinch.current.ix * z;
      const ty = my - cur.oy - pinch.current.iy * z;
      commit(z, tx, ty);
    } else if (arr.length === 1 && gcur.current.z > 1.001) {
      const p = arr[0];
      commit(gcur.current.z, pan0.current.tx + (p.x - pan0.current.px), pan0.current.ty + (p.y - pan0.current.py));
    }
  };

  const onTouchEnd = (e: React.TouchEvent) => {
    Array.from(e.changedTouches).forEach((t) => pts.current.delete(t.identifier));
    if (pts.current.size === 0) {
      const now = Date.now();
      if (now - lastTap.current < 280) {
        const cur = gcur.current;
        if (cur.z > 1) commit(1, 0, 0);
        else {
          const z = 2.5;
          commit(z, (cur.bw * (1 - z)) / 2, (cur.bh * (1 - z)) / 2); // зум к центру
        }
      }
      lastTap.current = now;
    }
  };

  const onLoadImg = () => {
    const img = new Image();
    img.onload = () => {
      nat.current = { w: img.naturalWidth, h: img.naturalHeight };
      setLoaded(true);
      commit(1, 0, 0);
      setReady(true);
    };
    img.src = src;
  };

  return (
    <div
      ref={box}
      style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden', touchAction: 'none', background: '#000' }}
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
    >
      {!ready && (
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center' }}><span className="spin" /></div>
      )}
      {loaded && (
        <img
          src={src}
          alt=""
          draggable={false}
          style={{
            position: 'absolute',
            left: g.ox + g.tx,
            top: g.oy + g.ty,
            width: g.bw * g.z,
            height: g.bh * g.z,
            maxWidth: 'none',
            maxHeight: 'none',
            userSelect: 'none', WebkitUserSelect: 'none',
            touchAction: 'none',
          }}
        />
      )}
      {/* прогрев размера */}
      <img src={src} alt="" onLoad={onLoadImg} style={{ display: 'none' }} />
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
