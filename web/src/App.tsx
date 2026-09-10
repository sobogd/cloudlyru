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

// ===== Восстановление экрана после перезагрузки (F5) =====
// Открытая вкладка, путь в «Файлах», открытый файл/папка и альбом живут в sessionStorage:
// переживают F5, но не «протекают» в новую вкладку (там стартуем с «Файлов»).

type UiState = {
  tab?: Tab;
  files?: { stack?: Array<{ id?: string; name: string }>; openFile?: string | null; folderMeta?: boolean };
  photos?: { viewEntryId?: string | null; detailId?: string | null };
  albums?: { openId?: string | null };
};
const UI_KEY = 'cloudlyru:ui';

function readUi(): UiState {
  try { return JSON.parse(sessionStorage.getItem(UI_KEY) || '{}') as UiState; } catch { return {}; }
}
function patchUi(patch: UiState) {
  try { sessionStorage.setItem(UI_KEY, JSON.stringify({ ...readUi(), ...patch })); } catch { /* приватный режим */ }
}
function clearUi() {
  try { sessionStorage.removeItem(UI_KEY); } catch { /* приватный режим */ }
}

export default function App() {
  const [user, setUser] = useState<api.UserInfo | null>(null);
  const [checking, setChecking] = useState(true);
  useEffect(() => {
    api.me().then(setUser).catch(() => setUser(null)).finally(() => setChecking(false));
  }, []);
  if (checking) return <div className="app">…</div>;
  if (!user) return <Login onLogin={(u) => setUser(u)} />;
  return <Shell user={user} onLogout={() => { clearUi(); setUser(null); }} />;
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
  const [tab, setTab] = useState<Tab>(() => {
    const saved = readUi().tab;
    return NAV.some((n) => n.id === saved) ? (saved as Tab) : 'files';
  });
  useEffect(() => { patchUi({ tab }); }, [tab]);

  // Очередь загрузки живёт здесь: переключение вкладки её больше не убивает,
  // и прогресс-панель видна в любом разделе. uploadedAt — сигнал спискам перечитать себя.
  const [uploadedAt, setUploadedAt] = useState(0);
  const up = useBulkUpload(() => setUploadedAt(Date.now()));

  // Запрет «свайпа обновления страницы» (pull-to-refresh): на современных браузерах —
  // CSS overscroll-behavior:none; здесь фолбэк JS для старых Safari, где CSS не работает.
  useEffect(() => {
    if (typeof CSS !== 'undefined' && CSS.supports('overscroll-behavior-y', 'none')) return;
    let y0: number | null = null;
    const onStart = (e: TouchEvent) => { y0 = e.changedTouches[0]?.clientY ?? null; };
    const onMove = (e: TouchEvent) => {
      if (window.scrollY > 0 || y0 == null) return;
      // жесты внутри деталки/зума/карты не трогаем
      const el = e.target as HTMLElement | null;
      if (el && el.closest('.mediaarea, .viewer, .tbar, .det-info')) return;
      const y = e.changedTouches[0]?.clientY;
      if (y != null && y > y0) e.preventDefault();
    };
    document.addEventListener('touchstart', onStart, { passive: true });
    document.addEventListener('touchmove', onMove, { passive: false });
    return () => {
      document.removeEventListener('touchstart', onStart);
      document.removeEventListener('touchmove', onMove);
    };
  }, []);

  return (
    <div className="app">
      <main className="content">
        {up.rows.length > 0 && (
          <UploadPanel
            rows={up.rows}
            busy={up.busy}
            onCancel={up.cancel}
            onRetryFailed={up.retryFailed}
            onDismissFailed={up.dismissFailed}
          />
        )}
        {tab === 'files' && <Files photoFolderId={user.photoFolderId} up={up} uploadedAt={uploadedAt} />}
        {tab === 'photos' && <Photos photoFolderId={user.photoFolderId} up={up} uploadedAt={uploadedAt} />}
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

// ================= Общая инлайн-загрузка (без отдельной страницы) =================
// Очередь живёт в Shell, а не внутри вкладки: загрузку можно продолжать, переключая
// разделы, и её не теряет ни один переход. Панель прогресса висит над содержимым.

interface UpFile {
  key: number;
  file: File;
  /** Папка-приёмник на момент выбора файла (своя для «Файлов» и «Фото»). */
  folderId?: string;
  state: 'queued' | 'uploading' | 'done' | 'failed';
  pct: number;
  phase?: api.UploadPhase;
  /** Пояснение текущего шага: номер части, причина перехода на релей и т.п. */
  note?: string;
  error?: string;
}
let upSeq = 0;

function useBulkUpload(onUploaded?: () => void) {
  const ref = useRef<UpFile[]>([]);
  const [rows, setRows] = useState<UpFile[]>([]);
  const cb = useRef(onUploaded);
  cb.current = onUploaded;
  const running = useRef(false);
  const stopped = useRef(false);
  const ctrl = useRef<AbortController | null>(null);
  const sync = () => setRows(ref.current.slice());

  const start = async () => {
    if (running.current) return;
    running.current = true;
    stopped.current = false;
    try {
      for (;;) {
        const i = ref.current.findIndex((r) => r.state === 'queued');
        if (i < 0 || stopped.current) break;
        const row = ref.current[i];
        row.state = 'uploading';
        row.pct = 0;
        row.note = undefined;
        sync();
        const ac = new AbortController();
        ctrl.current = ac;
        try {
          await api.uploadFile(row.file, row.folderId, (p, phase, note) => { row.pct = p; row.phase = phase; row.note = note; sync(); }, ac.signal);
          row.state = 'done';
          row.pct = 100;
          sync();
          cb.current?.();
        } catch (e) {
          if (stopped.current || ac.signal.aborted) {
            // отменённый текущий файл не показываем (он не загрузился)
            ref.current = ref.current.filter((x) => x.key !== row.key);
          } else {
            row.state = 'failed';
            row.error = (e as Error).message || 'ошибка';
          }
          sync();
        } finally {
          ctrl.current = null;
        }
      }
    } finally {
      running.current = false;
      if (stopped.current) {
        stopped.current = false;
        // отмена: остаются только уже загруженные
        ref.current = ref.current.filter((x) => x.state === 'done');
        sync();
      }
    }
  };

  const addFiles = (files: File[], folderId?: string) => {
    if (!files.length || running.current) return;
    ref.current = ref.current.filter((r) => r.state !== 'done');
    for (const f of files) ref.current.push({ key: ++upSeq, file: f, folderId, state: 'queued', pct: 0 });
    sync();
    void start();
  };

  const cancel = () => {
    stopped.current = true;
    ctrl.current?.abort();
  };
  const retryFailed = () => {
    ref.current = ref.current.map((r) => (r.state === 'failed' ? { ...r, state: 'queued' as const, pct: 0, error: undefined } : r));
    sync();
    void start();
  };
  const dismissFailed = () => {
    ref.current = ref.current.filter((r) => r.state !== 'failed');
    sync();
  };

  // когда всё догрузилось — панель сама исчезает
  const allDone = rows.length > 0 && !rows.some((r) => r.state !== 'done');
  useEffect(() => {
    if (!allDone) return;
    const t = setTimeout(() => { ref.current = []; sync(); }, 900);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [allDone]);

  return {
    rows,
    busy: rows.some((r) => r.state === 'queued' || r.state === 'uploading'),
    addFiles,
    cancel,
    retryFailed,
    dismissFailed,
  };
}

/** Очередь загрузки, поднятая в Shell и передаваемая разделам как проп. */
type Uploader = ReturnType<typeof useBulkUpload>;

/** Панель прогресса инлайн-загрузки: «x из N» + иконка отмены справа + прогресс по каждому файлу. */
function UploadPanel({ rows, busy, onCancel, onRetryFailed, onDismissFailed }: {
  rows: UpFile[];
  busy: boolean;
  onCancel: () => void;
  onRetryFailed: () => void;
  onDismissFailed: () => void;
}) {
  const doneN = rows.filter((r) => r.state === 'done').length;
  const failN = rows.filter((r) => r.state === 'failed').length;
  const active = rows.find((r) => r.state === 'uploading');
  const label = busy
    ? `загрузка ${doneN + (active ? 1 : 0)} из ${rows.length}`
    : failN > 0
      ? `не загрузилось: ${failN}`
      : `загружено ${doneN} из ${rows.length}`;
  return (
    <div className="uppanel">
      <div className="uphead">
        <span className="upcount">{label}</span>
        <span style={{ flex: 1 }} />
        {busy ? (
          <button className="iconbtn" title="Отменить — убрать незагруженное" onClick={onCancel}>✕</button>
        ) : failN > 0 ? (
          <>
            <button className="btn ghost" onClick={onRetryFailed}>⟳ повторить</button>
            <button className="iconbtn" title="Убрать ошибки" onClick={onDismissFailed}>✕</button>
          </>
        ) : null}
      </div>
      {rows.map((r) => (
        <div className="uprow" key={r.key}>
          <span className="icon">{r.state === 'done' ? '✅' : r.state === 'failed' ? '❌' : r.state === 'uploading' ? '⏳' : '🕒'}</span>
          <div className="upmain">
            <div className="upname">{r.file.name} <span className="meta">{fmt(r.file.size)}</span></div>
            {r.state === 'failed' ? (
              <div className="upmeta">{r.error}</div>
            ) : (
              <>
                <div className="ubar">
                  <i style={{ width: `${r.state === 'done' ? 100 : r.pct}%`, background: r.state === 'done' ? '#2fae5f' : undefined }} />
                </div>
                {r.state === 'uploading' && (
                  <div className="upmeta">
                    {r.phase === 'hash' ? `считаю sha256 · ${r.pct}%`
                      : r.phase === 'verify' ? 'сервер проверяет целостность…'
                      : `${r.phase === 'relay' ? 'загружаю через сервер' : 'загружаю'} · ${r.pct}%`}
                    {r.note ? ` · ${r.note}` : ''}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

function Files({ photoFolderId, up, uploadedAt }: { photoFolderId: string | null; up: Uploader; uploadedAt: number }) {
  const [saved] = useState(() => readUi().files);
  const [stack, setStack] = useState<Array<{ id?: string; name: string }>>(
    () => (saved?.stack?.length ? saved.stack : [{ name: 'Главная' }]),
  );
  const [view, setView] = useState<api.FolderView | null>(null);
  const [err, setErr] = useState('');
  const [openFile, setOpenFile] = useState<string | null>(saved?.openFile ?? null);
  const [folderMeta, setFolderMeta] = useState(!!saved?.folderMeta);
  const currentId = stack[stack.length - 1]?.id;

  // запоминаем экран, чтобы F5 возвращал в ту же папку/файл
  useEffect(() => { patchUi({ files: { stack, openFile, folderMeta } }); }, [stack, openFile, folderMeta]);

  const load = async (parentId?: string) => {
    setErr('');
    try { setView(await api.listFolder(parentId)); } catch (e) { setErr((e as Error).message); }
  };
  useEffect(() => { void load(currentId); }, [currentId]);
  // очередной файл догрузился — показываем его в текущей папке
  useEffect(() => { if (uploadedAt) void load(currentId); }, [uploadedAt]); // eslint-disable-line react-hooks/exhaustive-deps

  const busy = up.busy;

  const mkdir = async () => {
    const name = prompt('Имя новой папки');
    if (!name) return;
    try { await api.mkdir(name, currentId); await load(currentId); } catch (e) { setErr((e as Error).message); }
  };
  const goUp = () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s));
  const closeFile = () => { setOpenFile(null); void load(currentId); };

  // ===== Деталка файла (из списка) =====
  if (openFile) return <FileDetail entryId={openFile} onBack={closeFile} />;

  // ===== Деталка текущей папки (из шестерёнки, только внутри папок) =====
  if (folderMeta && currentId) {
    return (
      <FolderDetail
        folderId={currentId}
        onBack={() => { setFolderMeta(false); void load(currentId); }}
        onDeleted={() => {
          setFolderMeta(false);
          setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)); // после удаления — на уровень выше
        }}
      />
    );
  }

  return (
    <div>
      <div className="filehead">
        <button className="iconbtn" title="На уровень выше" onClick={goUp} disabled={stack.length === 1}>⬆️</button>
        {stack.length > 1 && (
          <button className="iconbtn" title="Инфо о папке" onClick={() => setFolderMeta(true)} disabled={busy}>ℹ️</button>
        )}
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Новая папка" onClick={mkdir} disabled={busy}>📂</button>
        <label className="iconbtn" title="Загрузить файлы (любого типа)">
          📄
          <input
            type="file"
            multiple
            style={{ display: 'none' }}
            disabled={busy}
            onChange={(e) => {
              if (e.target.files?.length) up.addFiles(Array.from(e.target.files), currentId);
              e.target.value = '';
            }}
          />
        </label>
      </div>

      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      <div className="fileslist">
        {(view?.folders || []).filter((f) => f.id !== photoFolderId).map((f) => (
          <div className="item" key={f.id} onClick={() => setStack((s) => [...s, { id: f.id, name: f.name }])}>
            <span className="icon">📁</span>
            <span className="fname">{f.name}</span>
          </div>
        ))}
        {(view?.entries || []).map((e) => (
          <div className="item" key={e.id} onClick={() => setOpenFile(e.id)}>
            <span className="icon">{fileIcon(e.mime)}</span>
            <span className="fname">{e.name}</span>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && (
          <div className="copy" style={{ padding: '14px 6px' }}>Пусто — нажмите 📄, чтобы загрузить файлы в эту папку</div>
        )}
      </div>
    </div>
  );
}

// ===== Деталка файла: назад / скачать / удалить + вся метадата на фоне =====

const rawNum = (v: unknown): number | undefined => {
  const n = Number(v);
  return Number.isFinite(n) && v !== null && v !== '' ? n : undefined;
};

function fmtDuration(sec?: number): string | undefined {
  if (!sec || !Number.isFinite(sec)) return undefined;
  const total = Math.round(sec);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s2 = total % 60;
  return h ? `${h} ч ${m} мин ${s2} с` : `${m}:${String(s2).padStart(2, '0')}`;
}
/** Причина падения сборки превью в одну строку: ffmpeg сыпет баннер и настройки,
 *  поэтому причина — в самом конце stderr, а не в начале. */
function shortErr(e?: string | null, max = 110): string {
  const s = String(e ?? '').replace(/\s+/g, ' ').trim();
  if (!s) return 'не удалось собрать превью';
  return s.length > max ? `…${s.slice(-max)}` : s;
}

/** EXIF-даты без часового пояса показываем «как в файле», без пересчёта. */
function fmtExifDate(iso?: unknown): string | undefined {
  if (typeof iso !== 'string' || !iso) return undefined;
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/);
  if (!m) return undefined;
  const [, y, mo, d, h, mi, sec] = m;
  return `${d}.${mo}.${y} ${h}:${mi}:${sec}`;
}
/** ffprobe отдаёт время с таймзоной — его показываем в местном времени. */
function fmtLocal(iso?: unknown): string | undefined {
  if (typeof iso !== 'string' || !iso) return undefined;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? undefined : d.toLocaleString();
}
const ORIENTATION: Record<number, string> = {
  1: 'нормальная', 2: 'зеркально по горизонтали', 3: 'повёрнуто на 180°',
  4: 'зеркально по вертикали', 5: 'зеркально + 90°', 6: 'повёрнуто на 90°',
  7: 'зеркально + 270°', 8: 'повёрнуто на 270°',
};
const COLOR_SPACE: Record<number, string> = { 1: 'sRGB', 2: 'Adobe RGB', 65535: 'некалиброванное' };
const EXPOSURE_PROGRAM: Record<number, string> = {
  0: 'не задано', 1: 'ручной', 2: 'авто', 3: 'приоритет диафрагмы',
  4: 'приоритет выдержки', 5: 'творческий', 6: 'спорт', 7: 'портрет', 8: 'пейзаж',
};

function fmtBitrate(bps?: number): string | undefined {
  if (!bps || !Number.isFinite(bps)) return undefined;
  return bps >= 1e6 ? `${(bps / 1e6).toFixed(1)} Мбит/с` : `${Math.round(bps / 1e3)} кбит/с`;
}

function MetaRow({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <div className="metarow">
      <span className="metak">{k}</span>
      <span className={`metav${mono ? ' mono' : ''}`}>{v}</span>
    </div>
  );
}

/** Строки метаданных, извлечённых из самого файла (EXIF для фото / ffprobe для видео). */
function mediaRows(raw: Record<string, unknown> | null): Array<[string, string]> {
  const rows: Array<[string, string]> = [];
  if (!raw) return rows;
  const push = (k: string, v: unknown, f?: (x: never) => string | undefined) => {
    if (v === undefined || v === null || v === '') return;
    const val = f ? f(v as never) : String(v);
    if (val && !rows.some(([kk]) => kk === k)) rows.push([k, val]);
  };
  const num1 = (v: number) => String(Number(v).toFixed(1)).replace(/\.0$/, '');

  if (raw.kind === 'image') {
    push('Дата съёмки', raw.dateTimeOriginal, fmtExifDate);
    push('Создан (EXIF)', raw.createDate, fmtExifDate);
    push('Изменён (EXIF)', raw.modifyDate, fmtExifDate);
    push('Часовой пояс', raw.offsetTime);
    push('Камера', [raw.make, raw.model].filter(Boolean).join(' '));
    push('Объектив', raw.lens);
    push('Выдержка', raw.exposureTime);
    push('Диафрагма', raw.fNumber, (v: number) => `f/${num1(v)}`);
    push('ISO', raw.iso);
    push('Фокусное', raw.focalLength, (v: number) => `${num1(v)} мм`);
    push('Фокусное (35 мм)', raw.focalLength35, (v: number) => `${v} мм`);
    push('Программа съёмки', raw.exposureProgram, (v: number) => EXPOSURE_PROGRAM[v] ?? String(v));
    push('Ориентация', raw.orientation, (v: number) => ORIENTATION[v] ?? String(v));
    push('Цвет. пространство', raw.colorSpace, (v: number) => COLOR_SPACE[v] ?? String(v));
    if (rawNum(raw.width) && rawNum(raw.height)) push('Кадр', `${raw.width} × ${raw.height}`);
    if (rawNum(raw.latitude) != null && rawNum(raw.longitude) != null) {
      push('Координаты', `${Number(raw.latitude).toFixed(6)}, ${Number(raw.longitude).toFixed(6)}`);
    }
    push('Высота', raw.altitude, (v: number) => `${Math.round(v)} м`);
    push('Описание', raw.description);
    push('Автор', raw.artist);
    push('Copyright', raw.copyright);
    push('ПО', raw.software);
  } else if (raw.kind === 'video') {
    push('Длительность', raw.durationSec, fmtDuration);
    push('Контейнер', raw.container);
    push('Видеокодек', raw.videoCodec);
    push('Аудиокодек', raw.audioCodec);
    if (rawNum(raw.width) && rawNum(raw.height)) push('Кадр', `${raw.width} × ${raw.height}`);
    push('Кадров/с', raw.fps, (v: number) => v.toFixed(2));
    push('Битрейт', raw.bitrate, fmtBitrate);
    push('Каналы', raw.audioChannels);
    push('Частота дискретизации', raw.audioSampleRate, (v: number) => `${v} Гц`);
    push('Создан', raw.createdAt, fmtLocal);
  }
  return rows;
}

function FileDetail({ entryId, onBack }: { entryId: string; onBack: () => void }) {
  const [meta, setMeta] = useState<api.FileMeta | null>(null);
  const [err, setErr] = useState('');
  const [job, setJob] = useState<api.UnzipJob | null>(null);
  const isZip = !!meta && (meta.mime === 'application/zip' || /\.zip$/i.test(meta.name));
  const busy = job?.state === 'pending' || job?.state === 'processing';

  useEffect(() => {
    api.fileMeta(entryId).then(setMeta).catch((e) => setErr((e as Error).message));
    // если распаковка уже идёт — подхватываем её прогресс
    api.latestUnzip(entryId)
      .then((j) => { if (j && (j.state === 'pending' || j.state === 'processing' || j.state === 'done')) setJob(j); })
      .catch(() => undefined);
  }, [entryId]);

  // опрос прогресса распаковки
  useEffect(() => {
    if (!job || (job.state !== 'pending' && job.state !== 'processing')) return;
    const t = setInterval(() => {
      api.unzipStatus(job.id).then(setJob).catch(() => undefined);
    }, 2000);
    return () => clearInterval(t);
  }, [job?.id, job?.state]);

  const startUnzip = async () => {
    try { setJob(await api.startUnzip(entryId)); } catch (e) { alert((e as Error).message); }
  };
  const cancelUnzip = async () => {
    if (!job) return;
    try { setJob(await api.cancelUnzip(job.id)); } catch (e) { alert((e as Error).message); }
  };

  // метаданные из самого файла — одним списком, без разделов
  const rows = mediaRows((meta?.media?.raw ?? null) as Record<string, unknown> | null);

  const del = async () => {
    if (!confirm(`Удалить «${meta?.name ?? 'файл'}» в корзину?`)) return;
    try { await api.deleteFile(entryId); onBack(); } catch (e) { alert((e as Error).message); }
  };
  // «держать офлайн»: флаг живёт на сервере и перекрывает автоудаление на телефоне
  const toggleOffline = async () => {
    const next = !meta?.keepOffline;
    try {
      await api.setFileKeepOffline(entryId, next);
      setMeta((m) => (m ? { ...m, keepOffline: next } : m));
    } catch (e) { alert((e as Error).message); }
  };

  return (
    <div>
      <div className="filehead">
        <button className="iconbtn" title="Назад" onClick={onBack}>⬅️</button>
        <span style={{ flex: 1 }} />
        {isZip && (
          <button
            className="iconbtn"
            title="Разархивировать рядом с архивом"
            disabled={busy}
            onClick={startUnzip}
          >📦</button>
        )}
        {meta && (
          <a className="iconbtn" title="Скачать" href={api.fileUrl(entryId)} download>⬇️</a>
        )}
        <button
          className="iconbtn"
          title={meta?.keepOffline ? 'Держать офлайн: включено (нажмите, чтобы снять)' : 'Держать офлайн на телефоне'}
          style={meta?.keepOffline ? { opacity: 1 } : { opacity: 0.45 }}
          onClick={toggleOffline}
        >📌</button>
        <button className="iconbtn" title="Удалить (в корзину)" onClick={del}>🗑</button>
      </div>
      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      {job && (
        <div className="panel" style={{ margin: '10px 2px' }}>
          <div className="row">
            <span className="icon">📦</span>
            <strong>Распаковка</strong>
            <span style={{ flex: 1 }} />
            <span className="meta">
              {job.state === 'done' ? 'готово'
                : job.state === 'failed' ? 'ошибка'
                : job.state === 'cancelled' ? 'отменено'
                : `${job.percent}%`}
            </span>
            {busy && <button className="btn ghost" onClick={cancelUnzip}>✕</button>}
          </div>
          <div className="ubar"><i style={{ width: `${job.percent}%`, background: job.state === 'done' ? '#2fae5f' : undefined }} /></div>
          <div className="copy">
            файлов: {job.doneEntries} из {job.totalEntries || '…'} · {fmt(job.doneBytes)} из {fmt(job.totalBytes)}
            {job.skippedEntries ? ` · уже было: ${job.skippedEntries}` : ''}
          </div>
          {busy && job.currentName && <div className="copy" style={{ wordBreak: 'break-all' }}>сейчас: {job.currentName}</div>}
          {job.error && <div className="err">{job.error}</div>}
          {job.state === 'done' && (
            <div className="copy">Папка создана рядом с архивом — вернись в «Файлы», она появится в списке</div>
          )}
        </div>
      )}
      {!meta && !err && <div className="copy" style={{ padding: '14px 6px' }}>Загрузка…</div>}
      {meta && (
        <div className="detbody">
          <MetaRow k="Имя" v={meta.name} />
          <MetaRow k="Тип" v={meta.ext ? `${meta.ext.toUpperCase()} — ${meta.mime}` : meta.mime} />
          <MetaRow k="Размер" v={fmt(meta.size)} />
          <MetaRow k="Расположение" v={meta.path} />
          <MetaRow k="Создан" v={new Date(meta.createdAt).toLocaleString()} />
          {meta.masterMime && <MetaRow k="Оптимизирован" v={meta.masterMime} />}
          {rows.length === 0 && meta.media && (
            <>
              {meta.media.capturedAt && <MetaRow k="Дата съёмки" v={new Date(meta.media.capturedAt).toLocaleString()} />}
              {meta.media.make || meta.media.model ? <MetaRow k="Камера" v={[meta.media.make, meta.media.model].filter(Boolean).join(' ')} /> : null}
              {meta.media.width && meta.media.height ? <MetaRow k="Кадр" v={`${meta.media.width} × ${meta.media.height}`} /> : null}
              {meta.media.latitude != null && meta.media.longitude != null ? (
                <MetaRow k="Координаты" v={`${meta.media.latitude.toFixed(6)}, ${meta.media.longitude.toFixed(6)}`} />
              ) : null}
            </>
          )}
          {rows.map(([k, v]) => <MetaRow key={k} k={k} v={v} />)}
          <MetaRow k="SHA-256" v={meta.sha256} mono />
        </div>
      )}
    </div>
  );
}

// ===== Деталка папки (шестерёнка внутри папки): назад / удалить + метадата на фоне =====

function FolderDetail({ folderId, onBack, onDeleted }: { folderId: string; onBack: () => void; onDeleted: () => void }) {
  const [meta, setMeta] = useState<api.FolderMeta | null>(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    api.folderMeta(folderId).then(setMeta).catch((e) => setErr((e as Error).message));
  }, [folderId]);

  const del = async () => {
    if (!confirm(`Удалить папку «${meta?.name ?? ''}» с содержимым в корзину?`)) return;
    try { await api.deleteFolder(folderId); onDeleted(); } catch (e) { alert((e as Error).message); }
  };
  const toggleOffline = async () => {
    const next = !meta?.keepOffline;
    try {
      await api.setFolderKeepOffline(folderId, next);
      setMeta((m) => (m ? { ...m, keepOffline: next } : m));
    } catch (e) { alert((e as Error).message); }
  };

  return (
    <div>
      <div className="filehead">
        <button className="iconbtn" title="Назад" onClick={onBack}>⬅️</button>
        <span style={{ flex: 1 }} />
        <button
          className="iconbtn"
          title={meta?.keepOffline
            ? 'Держать офлайн: включено (нажмите, чтобы снять)'
            : 'Держать офлайн на телефоне: папка не будет вытесняться'}
          style={meta?.keepOffline ? { opacity: 1 } : { opacity: 0.45 }}
          onClick={toggleOffline}
        >📌</button>
        <button className="iconbtn" title="Удалить (в корзину)" onClick={del}>🗑</button>
      </div>
      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      {!meta && !err && <div className="copy" style={{ padding: '14px 6px' }}>Загрузка…</div>}
      {meta && (
        <div className="detbody">
          <MetaRow k="Имя" v={meta.name} />
          <MetaRow k="Расположение" v={meta.path} />
          <MetaRow k="Вложенные папки" v={String(meta.folders)} />
          <MetaRow k="Файлы" v={String(meta.entries)} />
          <MetaRow k="Держать офлайн" v={meta.keepOffline ? 'да (не вытесняется на телефоне)' : 'нет'} />
          <MetaRow k="Создана" v={new Date(meta.createdAt).toLocaleString()} />
          <MetaRow k="Изменена" v={new Date(meta.updatedAt).toLocaleString()} />
        </div>
      )}
    </div>
  );
}


// ================= Фото (медиатека: таймлайн + поездки + карта) =================
// Показывает только содержимое системной папки «Фото» (зона PHOTOS); сама папка скрыта из
// «Файлы» и WebDAV. Загрузка — иконки 📷/🎬 в шапке (только фото/видео), прогресс — панелью
// над галереей, UI блокируется на время загрузки; удаление — из деталки в корзину.

function Photos({ photoFolderId, up, uploadedAt }: { photoFolderId: string | null; up: Uploader; uploadedAt: number }) {
  type Screen = { kind: 'grid' } | { kind: 'view'; idx: number };
  const [saved] = useState(() => readUi().photos);
  const [items, setItems] = useState<api.TimelineItem[]>([]);
  const [trips, setTrips] = useState<api.Trip[]>([]);
  const [activeTrip, setActiveTrip] = useState<string | null>(null);
  const [screen, setScreen] = useState<Screen>({ kind: 'grid' });
  // полноценная деталка (как в «Файлах»): открывается кнопкой ℹ️ из просмотра
  const [detailId, setDetailId] = useState<string | null>(saved?.detailId ?? null);
  // открытый файл после F5 восстанавливаем по entryId (индекс в таймлайне мог сдвинуться)
  const restoreOpen = useRef<string | null>(saved?.viewEntryId ?? null);
  const isImg = (m: string) => /^image\//.test(m || '');
  const isVid = (m: string) => /^video\//.test(m || '');

  const load = async () => {
    try { setItems(await api.timeline()); } catch { /* keep old */ }
  };
  /** Пересобрать превью упавшего файла: сервер сбрасывает задачу в очередь. */
  const retryPreview = async (entryId: string) => {
    try { await api.retryPreview(entryId); await load(); } catch (e) { alert((e as Error).message); }
  };
  useEffect(() => { void load(); api.trips().then(setTrips).catch(() => undefined); }, []);
  // автообновление статусов сборки превью
  useEffect(() => {
    const t = setInterval(() => { void load(); }, 3000);
    return () => clearInterval(t);
  }, []);

  const busy = up.busy;
  // файл догрузился — сразу показываем его в таймлайне (опрос раз в 3 с для этого не нужен)
  useEffect(() => { if (uploadedAt) void load(); }, [uploadedAt]); // eslint-disable-line react-hooks/exhaustive-deps

  const media = items.filter((it) => isImg(it.mime) || isVid(it.mime));
  const current = screen.kind === 'view' ? media[screen.idx] : null;

  // восстановление открытого файла после F5: ждём таймлайн и находим его позицию
  useEffect(() => {
    const id = restoreOpen.current;
    if (!id || !items.length) return;
    const idx = media.findIndex((it) => it.entryId === id);
    restoreOpen.current = null;
    if (idx >= 0) setScreen({ kind: 'view', idx });
    else setDetailId(null); // файла больше нет — и деталка не нужна
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items]);

  // запоминаем открытый файл/деталку для F5
  useEffect(() => {
    if (restoreOpen.current) return; // пока не восстановили — не затираем сохранённое
    patchUi({ photos: { viewEntryId: current?.entryId ?? null, detailId } });
  }, [current?.entryId, detailId]);

  // ===== Экран деталки (#1-4) =====
  if (screen.kind === 'view' && current) {
    const it = current;
    // полноценная деталка: те же метаданные и кнопки, что в «Файлах»
    if (detailId) return <FileDetail entryId={detailId} onBack={() => setDetailId(null)} />;
    return (
      <div className="full">
        {/* медиа занимает весь канвас (верх экрана → нав-бар); шапка/инфо — поверх */}
        <div className="mediaarea">
          {!it.masterReady ? (
            <div className="panel">
              {/* #2: плейсхолдер, пока превью не собрано; процент не показываем — он врёт */}
              {it.jobState === 'failed' ? (
                <>
                  <div className="copy">❌ Не удалось собрать превью</div>
                  {it.jobError && (
                    <pre className="copy" style={{ whiteSpace: 'pre-wrap', color: '#ff9c9c', maxHeight: 180, overflow: 'auto' }}>{it.jobError}</pre>
                  )}
                  <div className="row" style={{ justifyContent: 'center' }}>
                    <button className="btn ghost" onClick={() => void retryPreview(it.entryId)}>⟳ Пересобрать</button>
                    <a className="btn ghost" href={api.fileUrl(it.entryId)} download>⬇️ Скачать оригинал</a>
                  </div>
                </>
              ) : (
                <div style={{ display: 'grid', placeItems: 'center', gap: 10 }}>
                  <span className="spin" />
                  <div className="copy">⏳ Готовлю превью…</div>
                </div>
              )}
            </div>
          ) : isVid(it.mime) ? (
            <video src={api.videoPreviewUrl(it.sha256!)} controls autoPlay style={{ width: '100%', height: '100%', objectFit: 'contain', display: 'block' }} />
          ) : (
            <PhotoZoom src={api.previewUrl(it.sha256!, 2048)} />
          )}
        </div>
        <div className="tbar">
          <button className="iconbtn" title="Назад в галерею" onClick={() => setScreen({ kind: 'grid' })}>◀️</button>
          <span style={{ flex: 1 }} />
          <button className="iconbtn" title="Инфо и действия" onClick={() => setDetailId(it.entryId)}>ℹ️</button>
          {/* Скачивание живёт только в деталке (ℹ️) — из превью его убрали */}
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
          <button className="iconbtn" disabled={screen.idx === 0} title="Назад" onClick={() => setScreen({ kind: 'view', idx: screen.idx - 1 })}>⬅️</button>
          <button className="iconbtn" disabled={screen.idx >= media.length - 1} title="Вперёд" onClick={() => setScreen({ kind: 'view', idx: screen.idx + 1 })}>➡️</button>
        </div>
      </div>
    );
  }

  // ===== Экран-сетка =====
  return (
    <div>
      <div className="filehead">
        <span style={{ flex: 1 }} />
        {photoFolderId && (
          <>
            <label className="iconbtn" title="Загрузить фото (из галереи)">
              📷
              <input
                type="file"
                accept="image/*"
                multiple
                style={{ display: 'none' }}
                disabled={busy}
                onChange={(e) => {
                  if (e.target.files?.length) up.addFiles(Array.from(e.target.files), photoFolderId ?? undefined);
                  e.target.value = '';
                }}
              />
            </label>
            <label className="iconbtn" title="Загрузить видео">
              🎬
              <input
                type="file"
                accept="video/*"
                multiple
                style={{ display: 'none' }}
                disabled={busy}
                onChange={(e) => {
                  if (e.target.files?.length) up.addFiles(Array.from(e.target.files), photoFolderId ?? undefined);
                  e.target.value = '';
                }}
              />
            </label>
          </>
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
                title={it.jobError || 'превью'}
                style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: '#14181f', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 6, color: it.jobState === 'failed' ? '#ff8a8a' : '#8a95a6', fontSize: 11, textAlign: 'center', padding: 4, cursor: 'pointer' }}
              >
                {it.jobState === 'failed' ? (
                  <>
                    <span style={{ overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflowWrap: 'anywhere' }}>❌ {shortErr(it.jobError, 70)}</span>
                    <span style={{ display: 'flex', gap: 2 }}>
                      <button
                        className="iconbtn"
                        title="Пересобрать превью"
                        style={{ fontSize: 16, padding: '2px 6px' }}
                        onClick={(e) => { e.stopPropagation(); void retryPreview(it.entryId); }}
                      >⟳</button>
                      <a
                        className="iconbtn"
                        title="Скачать оригинал"
                        href={api.fileUrl(it.entryId)}
                        download
                        style={{ fontSize: 16, padding: '2px 6px' }}
                        onClick={(e) => e.stopPropagation()}
                      >⬇️</a>
                    </span>
                  </>
                ) : <span className="spin" />}
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
        {!media.length && <div className="copy">Нет фото и видео. Нажмите 📷 или 🎬 — медиа оптимизируется и появится здесь автоматически.</div>}
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
      <div className="row"><span style={{ flex: 1 }} /><button className="btn" title="Создать ссылку" onClick={create}>🔗</button></div>
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
  // открытый альбом переживает F5: храним id и перезапрашиваем содержимое
  const [openId, setOpenId] = useState<string | null>(() => readUi().albums?.openId ?? null);
  const [open, setOpen] = useState<api.AlbumView | null>(null);
  const [err, setErr] = useState('');
  const load = () => api.listAlbums().then(setAlbums).catch((e) => setErr((e as Error).message));
  useEffect(() => { void load(); }, []);
  useEffect(() => { patchUi({ albums: { openId } }); }, [openId]);
  useEffect(() => {
    if (!openId) { setOpen(null); return; }
    api.getAlbum(openId).then(setOpen).catch(() => setOpenId(null)); // альбом удалили — назад к списку
  }, [openId]);
  const create = async () => {
    const name = prompt('Имя альбома');
    if (!name) return;
    try { await api.createAlbum(name); await load(); } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div>
      <div className="row"><span style={{ flex: 1 }} /><button className="btn" title="Новый альбом" onClick={create}>🗂️</button></div>
      {err && <div className="err">{err}</div>}
      {albums.map((a) => (
        <div className="item" key={a.id}>
          <span className="icon">🗂️</span>
          <span className="fname" onClick={() => setOpenId(a.id)}>{a.name}</span>
          <span className="meta">{a.count}</span>
          <button className="btn ghost" onClick={async () => { if (confirm('Удалить альбом?')) { await api.deleteAlbum(a.id); if (openId === a.id) setOpenId(null); await load(); } }}>🗑</button>
        </div>
      ))}
      {!albums.length && <div className="copy">Альбомов нет</div>}
      {open && (
        <div className="panel">
          <div className="row"><strong>{open.name}</strong><span className="copy">{open.items.length}</span>
            <button className="btn ghost" onClick={() => setOpenId(null)}>закрыть</button></div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
            {open.items.map((it) => (
              <div key={it.entryId} style={{ width: '31.5%' }}>
                {/^image\//.test(it.mime) ? (
                  <img src={api.fileInlineUrl(it.entryId)} alt={it.name} loading="lazy" style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', borderRadius: 6, background: '#1b212b' }} />
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
        <span style={{ flex: 1 }} />
        <button className="btn danger" title="Очистить корзину" onClick={purge}>🧹</button>
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
