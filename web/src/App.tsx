import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { LucideIcon } from 'lucide-react';
import {
  ArrowDownToLine, ArrowLeft, ArrowRight, ArrowUp, Ban, Check, ChevronLeft, ChevronRight,
  CircleAlert, CircleCheck, CircleX, Clock, Cloud, Copy, Eraser, FileText, Film, Folder,
  FolderOpen, Image as ImageIcon, Images, Info, KeyRound, Link2, LoaderCircle, Lock, Package,
  Pause, Pencil, Play, Plus, RefreshCw, Scissors, Settings as SettingsIcon, Trash, Upload,
  UserRound, X,
} from 'lucide-react';
import * as api from './api';
import './styles.css';

type Tab = 'files' | 'photos' | 'shares' | 'albums' | 'trash' | 'settings';
/** Иконки навигации — компоненты lucide, а не эмодзи: они наследуют цвет и размер от кнопки.
    Settings импортируется как SettingsIcon: имя Settings занято локальным компонентом-экраном. */
const NAV: Array<{ id: Tab; Icon: LucideIcon; label: string }> = [
  { id: 'files', Icon: Folder, label: 'Файлы' },
  { id: 'photos', Icon: ImageIcon, label: 'Фото' },
  { id: 'shares', Icon: Link2, label: 'Шаринг' },
  { id: 'albums', Icon: Images, label: 'Альбомы' },
  { id: 'trash', Icon: Trash, label: 'Корзина' },
  { id: 'settings', Icon: SettingsIcon, label: 'Настройки' },
];

/** Иконка файла по MIME — одна на все списки: строка, деталка, аплоадер. */
function FileIcon({ mime, className }: { mime?: string; className?: string }) {
  const cls = className ?? 'icon';
  if (mime?.startsWith('image/')) return <span className={cls}><ImageIcon /></span>;
  if (mime?.startsWith('video/')) return <span className={cls}><Film /></span>;
  return <span className={cls}><FileText /></span>;
}

// ===== Восстановление экрана после перезагрузки (F5) =====
// Открытая вкладка, путь в «Файлах», открытый файл/папка и альбом живут в sessionStorage:
// переживают F5, но не «протекают» в новую вкладку (там стартуем с «Файлов»).

type UiState = {
  tab?: Tab;
  files?: { stack?: Array<{ id?: string; name: string }>; openFile?: string | null; folderMeta?: boolean };
  photos?: { month?: string | null; photo?: api.TimelineItem | null; detailId?: string | null };
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
      <div className="brand"><Cloud size={40} strokeWidth={1.5} /></div>
      <h2>CloudlyRu</h2>
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
        {tab === 'files' && (
          <Files
            photoFolderId={user.photoFolderId}
            up={up}
            uploadedAt={uploadedAt}
          />
        )}
        {tab === 'photos' && <Photos photoFolderId={user.photoFolderId} up={up} uploadedAt={uploadedAt} />}
        {tab === 'shares' && <Shares />}
        {tab === 'albums' && <Albums />}
        {tab === 'trash' && <TrashPage />}
        {tab === 'settings' && <Settings login={user.login} onLogout={onLogout} />}
      </main>
      {/* Нижний остров-навигация: иконка + подпись, активная вкладка подсвечена */}
      <nav className="island island-bottom">
        {NAV.map(({ id, Icon, label }) => (
          <button
            key={id}
            className={tab === id ? 'navbtn active' : 'navbtn'}
            onClick={() => setTab(id)}
            title={label}
            aria-label={label}
            aria-current={tab === id ? 'page' : undefined}
          >
            <span className="navico"><Icon /></span>
            <span className="navlbl">{label}</span>
          </button>
        ))}
      </nav>
    </div>
  );
}

// ================= Файлы =================

function fileIcon(mime?: string): JSX.Element {
  if (!mime) return <FileText />;
  if (mime.startsWith('image/')) return <ImageIcon />;
  if (mime.startsWith('video/')) return <Film />;
  return <FileText />;
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
          <button className="iconbtn" title="Отменить — убрать незагруженное" onClick={onCancel}><X /></button>
        ) : failN > 0 ? (
          <>
            <button className="btn ghost" onClick={onRetryFailed}><RefreshCw size={14} /> повторить</button>
            <button className="iconbtn" title="Убрать ошибки" onClick={onDismissFailed}><X /></button>
          </>
        ) : null}
      </div>
      {rows.map((r) => (
        <div className="uprow" key={r.key}>
          <span className="icon">{r.state === 'done' ? <CircleCheck /> : r.state === 'failed' ? <CircleX /> : r.state === 'uploading' ? <LoaderCircle /> : <Clock />}</span>
          <div className="upmain">
            <div className="upname">{r.file.name} <span className="meta">{fmt(r.file.size)}</span></div>
            {r.state === 'failed' ? (
              <div className="upmeta">{r.error}</div>
            ) : (
              <>
                <div className="ubar">
                  <i style={{ width: `${r.state === 'done' ? 100 : r.pct}%`, background: r.state === 'done' ? 'var(--ok)' : undefined }} />
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
  const [clip, setClip] = useState<api.ClipboardView | null>(null);
  const [notice, setNotice] = useState('');
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

  // Буфер перечитываем при возврате из деталки: там его и наполняют (копировать/вырезать)
  useEffect(() => {
    if (openFile || folderMeta) return;
    api.clipboard().then(setClip).catch(() => undefined);
  }, [openFile, folderMeta, currentId]);

  const busy = up.busy;

  const mkdir = async () => {
    const name = prompt('Имя новой папки');
    if (!name) return;
    try { await api.mkdir(name, currentId); await load(currentId); } catch (e) { setErr((e as Error).message); }
  };
  const goUp = () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s));

  const pasteHere = async () => {
    // На верхнем уровне в стеке нет id (это «Главная»), но сервер вернул настоящий id папки
    const target = view?.parentId ?? currentId;
    if (!target) return;
    setNotice('');
    try {
      const r = await api.pasteClipboard(target);
      await load(currentId);
      await api.clipboard().then(setClip).catch(() => undefined);
      setNotice(r.action === 'copied' ? `Скопировано: ${r.name}` : `Перенесено: ${r.name}`);
    } catch (e) { setErr((e as Error).message); }
  };
  const clearClip = async () => {
    try {
      await api.clearClipboard();
      setClip(null);
    } catch (e) { setErr((e as Error).message); }
  };
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
        <button className="iconbtn" title="На уровень выше" onClick={goUp} disabled={stack.length === 1}><ArrowUp /></button>
        {stack.length > 1 && (
          <button className="iconbtn" title="Инфо о папке" onClick={() => setFolderMeta(true)} disabled={busy}><Info /></button>
        )}
        <span style={{ flex: 1 }} />
        {/* «Вставить» живёт в шапке любой папки: буфер серверный, поэтому он одинаков
            и в списке файлов, и на другом устройстве */}
        {clip && (
          <>
            <button
              className="iconbtn"
              title={clip.available
                ? `Вставить сюда: ${clip.mode === 'cut' ? 'перенести' : 'скопировать'} «${clip.name}»`
                : `Источник «${clip.name}» больше недоступен`}
              onClick={pasteHere}
            ><Upload /></button>
            <span className="clipnote" title={`${clip.mode === 'cut' ? 'вырезано' : 'скопировано'}: ${clip.name}`}>
              {clip.mode === 'cut' ? <Scissors size={12} /> : <Copy size={12} />} {clip.name}
              <button className="iconbtn" title="Очистить буфер" onClick={clearClip}><X /></button>
            </span>
          </>
        )}
        <button className="iconbtn" title="Новая папка" onClick={mkdir} disabled={busy}><FolderOpen /></button>
        <label className="iconbtn" title="Загрузить файлы (любого типа)">
          <FileText />
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
      {notice && <div className="notice" style={{ margin: '10px 2px' }}>{notice}</div>}
      <div className="fileslist">
        {(view?.folders || []).filter((f) => f.id !== photoFolderId).map((f) => (
          <div className="item" key={f.id} onClick={() => setStack((s) => [...s, { id: f.id, name: f.name }])}>
            <span className="icon"><Folder /></span>
            <span className="fname">{f.name}</span>
          </div>
        ))}
        {(view?.entries || []).map((e) => (
          <div className="item" key={e.id} onClick={() => setOpenFile(e.id)}>
            <FileThumb entry={e} />
            <span className="fname">{e.name}</span>
          </div>
        ))}
        {!view?.folders.length && !view?.entries.length && (
          <div className="copy empty" style={{ padding: '14px 6px' }}><FileText size={14} /> <span>Пусто — нажмите «Загрузить» в шапке, чтобы добавить файлы в эту папку</span></div>
        )}
      </div>
    </div>
  );
}

// ===== Деталка файла: назад / скачать / удалить + вся метадата на фоне =====

/**
 * Миниатюра строки списка (50×50 — столько отдаёт сервер): собранное очередью превью,
 * а не оригинал. Превью ещё нет — остаётся иконка типа файла.
 */
function FileThumb({ entry }: { entry: api.FolderEntry }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <span className="icon">{fileIcon(entry.mime)}</span>;
  return (
    <img
      className="thumb"
      src={api.thumbUrl(entry.id)}
      alt=""
      loading="lazy"
      onError={() => setFailed(true)}
    />
  );
}

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

function FileDetail({ entryId, onBack, onDeleted, inOverlay }: { entryId: string; onBack: () => void; onDeleted?: (entryId: string) => void; inOverlay?: boolean }) {
  const [meta, setMeta] = useState<api.FileMeta | null>(null);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [job, setJob] = useState<api.UnzipJob | null>(null);
  /** Минимум ожидания на лоадере: на быстром ответе спиннер иначе мигал бы одно мгновение. */
  const [minDone, setMinDone] = useState(false);
  const isZip = !!meta && (meta.mime === 'application/zip' || /\.zip$/i.test(meta.name));
  const busy = job?.state === 'pending' || job?.state === 'processing';
  /** Деталка показывается целиком: и данные пришли, и минимальное ожидание прошло. */
  const ready = Boolean(meta) && minDone;

  useEffect(() => {
    setMinDone(false);
    const t = window.setTimeout(() => setMinDone(true), LOADER_MIN_MS);
    return () => window.clearTimeout(t);
  }, [entryId]);

  useEffect(() => {
    api.fileMeta(entryId).then(setMeta).catch((e) => setErr((e as Error).message));
    // если распаковка уже идёт — подхватываем её прогресс
    api.latestUnzip(entryId)
      .then((j) => { if (j && (j.state === 'pending' || j.state === 'processing' || j.state === 'done')) setJob(j); })
      .catch(() => undefined);
  }, [entryId]);

  // Превью PDF собирает очередь уже после загрузки: пока числа страниц нет, файл открыт
  // «на будущее» — спрашиваем мету заново, иначе деталка так и осталась бы со спиннером.
  const waitingPages = meta?.mime === 'application/pdf' && !meta.pageCount;
  useEffect(() => {
    if (!waitingPages) return;
    const t = setInterval(() => {
      api.fileMeta(entryId).then(setMeta).catch(() => undefined);
    }, 3000);
    return () => clearInterval(t);
  }, [waitingPages, entryId]);

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
    try { await api.deleteFile(entryId); onDeleted?.(entryId); onBack(); } catch (e) { alert((e as Error).message); }
  };
  // Копировать/вырезать: цель уезжает в серверный буфер, вставка — в шапке нужной папки
  const toClipboard = async (mode: 'copy' | 'cut') => {
    try {
      await api.setClipboard('file', entryId, mode);
      alert(mode === 'copy'
        ? 'Скопировано. Откройте нужную папку и нажмите «Вставить сюда» в её шапке.'
        : 'Вырезано. Откройте нужную папку и нажмите «Вставить сюда» в её шапке.');
    } catch (e) { alert((e as Error).message); }
  };
  // Переименование: имя проверяет сервер (255 байт, без «/», конфликт с тёзкой — 409)
  const rename = async () => {
    const next = prompt('Новое имя файла', meta?.name ?? '');
    if (!next || next === meta?.name) return;
    try {
      await api.renameFile(entryId, next);
      setMeta((m) => (m ? { ...m, name: next } : m));
      setNotice('Имя изменено');
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <div>
      <div className={inOverlay ? 'filehead in-ovl' : 'filehead'}>
        <button className="iconbtn" title="Назад" onClick={onBack}><ArrowLeft /></button>
        <span style={{ flex: 1 }} />
        {ready && (
          <>
            <button className="iconbtn" title="Переименовать" onClick={rename}><Pencil /></button>
            <button className="iconbtn" title="Копировать в другую папку" onClick={() => toClipboard('copy')}><Copy /></button>
            <button className="iconbtn" title="Вырезать (перенести) в другую папку" onClick={() => toClipboard('cut')}><Scissors /></button>
          </>
        )}
        {isZip && (
          <button
            className="iconbtn"
            title="Разархивировать рядом с архивом"
            disabled={busy}
            onClick={startUnzip}
          ><Package /></button>
        )}
        {ready && (
          <a className="iconbtn" title="Скачать" href={api.fileUrl(entryId)} download><ArrowDownToLine /></a>
        )}
        <button className="iconbtn" title="Удалить (в корзину)" onClick={del}><Trash /></button>
      </div>
      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      {notice && <div className="notice" style={{ margin: '10px 2px' }}>{notice}</div>}
      {job && (
        <div className="panel" style={{ margin: '10px 2px' }}>
          <div className="row">
            <span className="icon"><Package /></span>
            <strong>Распаковка</strong>
            <span style={{ flex: 1 }} />
            <span className="meta">
              {job.state === 'done' ? 'готово'
                : job.state === 'failed' ? 'ошибка'
                : job.state === 'cancelled' ? 'отменено'
                : `${job.percent}%`}
            </span>
            {busy && <button className="btn ghost" onClick={cancelUnzip}><X size={16} /></button>}
          </div>
          <div className="ubar"><i style={{ width: `${job.percent}%`, background: job.state === 'done' ? 'var(--ok)' : undefined }} /></div>
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
      {/* Пока деталка не готова — только лоадер: тела ещё нет, показывать нечего. */}
      {!ready && !err && <div className="detload"><span className="spin" /></div>}
      {ready && meta && (
        <div className="detbody">
          <MetaRow k="Имя" v={meta.name} />
          <MetaRow k="Тип" v={meta.ext ? `${meta.ext.toUpperCase()} — ${meta.mime}` : meta.mime} />
          <MetaRow k="Размер" v={fmt(meta.size)} />
          <MetaRow k="Расположение" v={meta.path} />
          <MetaRow k="Создан" v={new Date(meta.createdAt).toLocaleString()} />
          {/* Главное из метаданных — всегда на виду, а не только когда полного дампа нет:
              дата съёмки, камера, кадр и координаты нужны сразу, а остальные теги лежат
              ниже в свёрнутом «Все теги из файла» (он длинный и не должен отодвигать превью). */}
          {meta.media && (
            <>
              {/* Дату показываем тем же способом, что заголовки месяцев в ленте («как в файле»,
                  без пересчёта в часовой пояс браузера): иначе у снимка, сделанного около
                  полуночи, месяц в ленте и дата в деталке расходились. */}
              {meta.media.capturedAt && <MetaRow k="Дата съёмки" v={fmtExifDate(meta.media.capturedAt) ?? new Date(meta.media.capturedAt).toLocaleString()} />}
              {meta.media.make || meta.media.model ? <MetaRow k="Камера" v={[meta.media.make, meta.media.model].filter(Boolean).join(' ')} /> : null}
              {meta.media.width && meta.media.height ? <MetaRow k="Кадр" v={`${meta.media.width} × ${meta.media.height}`} /> : null}
              {meta.media.latitude != null && meta.media.longitude != null ? (
                <MetaRow k="Координаты" v={`${meta.media.latitude.toFixed(6)}, ${meta.media.longitude.toFixed(6)}`} />
              ) : null}
            </>
          )}
          <MetaRow k="SHA-256" v={meta.sha256} mono />
        </div>
      )}
      {ready && meta && <FilePreview meta={meta} />}
      {/* Дамп тегов (EXIF/ffprobe) — десятки строк: он не должен отодвигать превью вниз,
          поэтому по умолчанию свёрнут, а сам дамп никуда не делся. */}
      {!!rows.length && (
        <details className="tags">
          <summary className="copy">Все теги из файла ({rows.length})</summary>
          <div className="detbody">
            {rows.map(([k, v]) => <MetaRow key={k} k={k} v={v} />)}
          </div>
        </details>
      )}
    </div>
  );
}

// ================= Превью содержимого в деталке файла =================
// Показываем только то, что браузер рисует сам или что уже собрано сервером:
// фото — готовое превью (AVIF; заодно HEIC/TIFF/RAW, которые браузер не показывает),
// видео — превью 1080, а если браузер без AV1 — оригинал, PDF — pdf.js в канвасе.
// Оригинал картинки в <img> не подставляем как основной путь: у файлов в «Файлах»
// он всегда на месте, но это лишний трафик, а превью кэшируется браузером.

function previewKind(mime: string, name: string): 'image' | 'video' | 'pdf' | null {
  if (/^image\//.test(mime)) return 'image';
  if (/^video\//.test(mime)) return 'video';
  if (mime === 'application/pdf' || /\.pdf$/i.test(name)) return 'pdf';
  return null;
}

function FilePreview({ meta }: { meta: api.FileMeta }) {
  const kind = previewKind(meta.mime, meta.name);
  if (!kind) return null;
  return (
    <div className="preview">
      {/* key по id: при переходе к другому файлу состояние фолбэков сбрасывается */}
      {kind === 'image' && <ImagePreview key={meta.id} meta={meta} />}
      {kind === 'video' && <VideoPreview key={meta.id} meta={meta} />}
      {kind === 'pdf' && <PdfPreview key={meta.id} meta={meta} />}
    </div>
  );
}

/** Нечем показать — говорим об этом прямо: кнопка ставит превью в очередь, рядом скачивание. */
function PreviewNote({ text, url, entryId }: { text: string; url: string; entryId: string }) {
  const [sent, setSent] = useState(false);
  const rebuild = async () => {
    try {
      await api.retryPreview(entryId);
      setSent(true);
    } catch (e) { alert((e as Error).message); }
  };
  return (
    <div className="pnote">
      <span className="copy">{text}</span>
      <button className="btn ghost" disabled={sent} onClick={rebuild}>
        {sent ? <><Check size={16} /> задача поставлена</> : <><RefreshCw size={16} /> Пересобрать</>}
      </button>
      <a className="btn ghost" href={url} download><ArrowDownToLine size={16} /> Скачать</a>
    </div>
  );
}

function ImagePreview({ meta }: { meta: api.FileMeta }) {
  // 0 — превью, собранное сервером; 1 — оригинал (inline); 2 — показать нечем
  // (превью ещё не готово, а формат браузер не рисует — например RAW или SVG)
  const [stage, setStage] = useState(0);
  if (stage > 1) {
    return <PreviewNote text="Превью ещё не собрано, а этот формат браузер не показывает" url={api.fileUrl(meta.id)} entryId={meta.id} />;
  }
  const src = stage === 0 ? api.previewUrl(meta.sha256, 1080) : api.fileInlineUrl(meta.id);
  return (
    <div className="pmedia">
      <img src={src} alt={meta.name} onError={() => setStage((s) => s + 1)} />
    </div>
  );
}

function VideoPreview({ meta }: { meta: { id: string; sha256: string; name: string } }) {
  // 0 — превью 1080 (AV1), 1 — оригинал: AV1 умеют не все браузеры (Safari/iOS — частично)
  const [stage, setStage] = useState(0);
  if (stage > 1) return <PreviewNote text="Видео не проигрывается в этом браузере" url={api.fileUrl(meta.id)} entryId={meta.id} />;
  return (
    <div className="pmedia">
      <video
        key={stage}
        src={api.videoPreviewUrl(meta.sha256, stage === 1)}
        controls
        playsInline
        preload="metadata"
        onError={() => setStage((s) => s + 1)}
      />
    </div>
  );
}

/**
 * PDF показываем превью страниц, которые отрисовал сервер (poppler в очереди):
 * страница = обычная картинка, поэтому в браузере ничего не парсится и не исполняется,
 * а на телефоне не приходится тянуть рендерер. Число страниц приходит в мете файла —
 * оно же появляется там только после того, как очередь отрисовала превью.
 */
function PdfPreview({ meta }: { meta: api.FileMeta }) {
  const [page, setPage] = useState(1);
  const [failed, setFailed] = useState(false);
  const pages = meta.pageCount ?? 0;

  if (!pages) {
    return (
      <div className="pmedia">
        <div style={{ display: 'grid', placeItems: 'center', gap: 10 }}>
          <span className="spin" />
          <span className="copy empty"><LoaderCircle size={14} /> <span>Готовлю превью страниц…</span></span>
        </div>
      </div>
    );
  }
  if (failed) {
    return <PreviewNote text="Превью этой страницы не собралось — посмотрите очередь конвертации в настройках" url={api.fileUrl(meta.id)} entryId={meta.id} />;
  }
  return (
    <>
      <div className="pmedia">
        <img
          src={api.pdfPageUrl(meta.sha256, page)}
          alt={`${meta.name} — страница ${page}`}
          onError={() => setFailed(true)}
        />
      </div>
      <div className="pbar">
        <button className="iconbtn" title="Предыдущая страница" disabled={page <= 1} onClick={() => { setFailed(false); setPage(page - 1); }}><ChevronLeft /></button>
        <span className="meta">{page} / {pages}</span>
        <button className="iconbtn" title="Следующая страница" disabled={page >= pages} onClick={() => { setFailed(false); setPage(page + 1); }}><ChevronRight /></button>
      </div>
    </>
  );
}

// ===== Деталка папки (шестерёнка внутри папки): назад / удалить + метадата на фоне =====

function FolderDetail({ folderId, onBack, onDeleted }: { folderId: string; onBack: () => void; onDeleted: () => void }) {
  const [meta, setMeta] = useState<api.FolderMeta | null>(null);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  useEffect(() => {
    api.folderMeta(folderId).then(setMeta).catch((e) => setErr((e as Error).message));
  }, [folderId]);

  const del = async () => {
    if (!confirm(`Удалить папку «${meta?.name ?? ''}» с содержимым в корзину?`)) return;
    try { await api.deleteFolder(folderId); onDeleted(); } catch (e) { alert((e as Error).message); }
  };
  // Папку можно вырезать (перенести), но не копировать: копия поддерева — отдельная задача
  const cutFolder = async () => {
    try {
      await api.setClipboard('folder', folderId, 'cut');
      alert('Папка вырезана. Откройте нужную папку и нажмите «Вставить сюда» в её шапке.');
    } catch (e) { alert((e as Error).message); }
  };
  // Переименование: корень и зарезервированное имя сервер не даст переименовать (400/409)
  const rename = async () => {
    const next = prompt('Новое имя папки', meta?.name ?? '');
    if (!next || next === meta?.name) return;
    try {
      await api.renameFolder(folderId, next);
      setMeta((m) => (m ? { ...m, name: next } : m));
      setNotice('Имя изменено');
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <div>
      <div className="filehead">
        <button className="iconbtn" title="Назад" onClick={onBack}><ArrowLeft /></button>
        <span style={{ flex: 1 }} />
        <button className="iconbtn" title="Переименовать" onClick={rename}><Pencil /></button>
        <button className="iconbtn" title="Вырезать (перенести) в другую папку" onClick={cutFolder}><Scissors /></button>
        {/* защищать от удаления в этом разделе больше нечего: корень зеркала у каждого
            устройства свой и лежит в корне облака, а папка «Телефон» — легаси */}
        <button className="iconbtn" title="Удалить (в корзину)" onClick={del}><Trash /></button>
      </div>
      {err && <div className="err" style={{ margin: '10px 2px' }}>{err}</div>}
      {notice && <div className="notice" style={{ margin: '10px 2px' }}>{notice}</div>}
      {!meta && !err && <div className="copy" style={{ padding: '14px 6px' }}>Загрузка…</div>}
      {meta && (
        <div className="detbody">
          <MetaRow k="Имя" v={meta.name} />
          <MetaRow k="Расположение" v={meta.path} />
          <MetaRow k="Вложенные папки" v={String(meta.folders)} />
          <MetaRow k="Файлы" v={String(meta.entries)} />
          <MetaRow k="Создана" v={new Date(meta.createdAt).toLocaleString()} />
          <MetaRow k="Изменена" v={new Date(meta.updatedAt).toLocaleString()} />
        </div>
      )}
    </div>
  );
}


// ================= Фото (календарь по месяцам + просмотр снимков) =================
// Два разных экрана, и они не пересекаются:
//   • список — календарь: один месяц на странице, в кружке дня один снимок этого дня и число,
//     месяцы листаются стрелками (удержание ускоряет). Данные — /timeline/days: строка на день,
//     ~30 строк на месяц вместо сотен строк ленты, которые календарю не нужны;
//   • просмотр (деталка) — отдельная страница: там листаются СНИМКИ по очереди, все, что есть в
//     дне, а на краю дня — соседний день (/timeline/photos).
// Прокрутки на экране-календаре нет вообще, поэтому и виртуализация не нужна: в DOM один месяц.

/**
 * Сколько ждём после открытия месяца, прежде чем уйти в сеть. Кэша месяцев нет: месяц всегда
 * перечитывается, а секунда нужна, чтобы экран успел показать, куда мы пришли, и чтобы листание
 * удержанием не превращалось в очередь запросов.
 */
const MONTH_WAIT_MS = 1000;
/** Через сколько удержания стрелки начинается ускоренное листание и с какого шага. */
const HOLD_DELAY_MS = 380;
const HOLD_STEP_MS = 220;
const HOLD_STEP_MIN_MS = 60;
/** Как часто переспрашиваем статусы снимков, которые ещё собираются. */
const STATUS_POLL_MS = 4000;
/** Задержка перед перечитыванием месяца после загрузки: файлы идут пачкой, месяц нужен один раз. */
const REFRESH_DEBOUNCE_MS = 1500;
/** В календаре ровно 7 колонок на любом экране. */
const CAL_COLS = 7;
/**
 * Окно просмотра: столько снимков держим по каждую сторону от открытого кадра (сервер отдаёт их
 * одним запросом). Ближе PHOTO_WINDOW_EDGE к краю окна — добираем ещё пачку в сторону движения.
 */
const PHOTO_WINDOW = 20;
const PHOTO_WINDOW_EDGE = 5;
/** Минимум, сколько крутится лоадер кадра: без него он мигает на уже загруженной картинке. */
const LOADER_MIN_MS = 1000;

const MONTHS = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];

function monthTitleOf(key: string): string {
  const [year, month] = key.split('-');
  return `${MONTHS[Number(month) - 1] ?? key} ${year}`;
}

/** Соседний месяц по ключу 'YYYY-MM': shiftMonth('2026-01', -1) === '2025-12'. */
function shiftMonth(key: string, delta: number): string {
  const [y, m] = key.split('-').map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

/** Текущий месяц по календарю устройства (даты съёмки показываем «как в файле», без пересчёта). */
function currentMonthKey(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

/** День человеческим текстом: '2026-09-13' → «13 сентября 2026 г.». */
function dayTitle(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' });
}

/** Статус сборки превью: приходит ручкой /timeline/status, а не внутри самих дней. */
type PreviewStatus = { previewState: string; previewError: string | null; jobState: string | null; jobError: string | null };

/** Готов ли снимок к показу и что с задачей сборки: ответ статусов уточняет данные дня. */
function previewState(item: api.TimelineItem, status?: PreviewStatus) {
  const state = status?.previewState ?? item.previewState;
  const ready = state === 'done';
  const jobState = status?.jobState ?? null;
  // Причина известна серверу: «собрать нельзя» — это состояние ассета, а не догадка клиента
  // по отсутствию задачи (раньше «превью не будет» выводилось из jobState === null).
  const jobError = status?.jobError ?? (state === 'impossible' ? status?.previewError ?? null : null);
  const impossible = state === 'impossible';
  const hopeless = !ready && (impossible || jobState === 'failed');
  return { ready, jobState, jobError, failed: jobState === 'failed', impossible, hopeless };
}

/**
 * Удержание кнопки: первое нажатие срабатывает сразу, дальше действие повторяется со всё
 * меньшим шагом (нужно, чтобы пролистать месяцы за годы, а не щёлкать сотни раз).
 * Возвращает обработчики для pointer-событий кнопки; клик с клавиатуры обрабатывается отдельно.
 */
function useHoldRepeat(action: () => void, enabled: boolean) {
  const act = useRef(action);
  act.current = action;
  const timers = useRef<{ start: number | null; step: number | null }>({ start: null, step: null });

  const stop = useCallback(() => {
    if (timers.current.start !== null) { window.clearTimeout(timers.current.start); timers.current.start = null; }
    if (timers.current.step !== null) { window.clearTimeout(timers.current.step); timers.current.step = null; }
  }, []);

  const start = useCallback(() => {
    if (!enabled) return;
    stop();
    act.current(); // первое нажатие — сразу, без ожидания
    timers.current.start = window.setTimeout(() => {
      let delay = HOLD_STEP_MS;
      const tick = () => {
        act.current();
        delay = Math.max(HOLD_STEP_MIN_MS, Math.round(delay * 0.75));
        timers.current.step = window.setTimeout(tick, delay);
      };
      tick();
    }, HOLD_DELAY_MS);
  }, [enabled, stop]);

  useEffect(() => stop, [stop]);

  return { start, stop };
}

/**
 * Кружок дня: под числом — обложка дня (один снимок из этого дня). Превью ещё собирается —
 * кружок тёмный, но число видно; в дни без снимков число приглушено и кружок не рисуется.
 */
function DayCell({ day, row, status, onOpen }: {
  day: number;
  row: api.TimelineDayItem | null;
  status?: PreviewStatus;
  onOpen: (row: api.TimelineDayItem) => void;
}) {
  if (!row) {
    return <div className="calcell off" title={`${day} — снимков нет`}><span className="calnum">{day}</span></div>;
  }
  const st = previewState(row.cover, status);
  const photo = st.ready && row.cover.sha256;
  return (
    <div
      className={photo ? 'calcell' : 'calcell wait'}
      title={`${day} — снимков: ${row.count}${photo ? '' : st.hopeless ? ', превью не собрать' : ', превью собирается'}`}
      onClick={() => onOpen(row)}
    >
      {photo && <img className="calphoto" src={api.previewUrl(row.cover.sha256!)} alt="" loading="lazy" />}
      <span className="calnum">{day}</span>
    </div>
  );
}

function Photos({ photoFolderId, up, uploadedAt }: { photoFolderId: string | null; up: Uploader; uploadedAt: number }) {
  const [saved] = useState(() => readUi().photos);
  /** Видимый месяц ('YYYY-MM'): листается стрелками и переживает F5. */
  const [month, setMonth] = useState<string>(() => saved?.month ?? currentMonthKey());
  /** Края листания — самый новый и самый старый месяцы со снимками (null — снимков нет). */
  const [bounds, setBounds] = useState<{ newest: string | null; oldest: string | null } | null>(null);
  /**
   * Окно просмотра: снимки вокруг открытого кадра и позиция в нём. Кадр переключается по уже
   * загруженному окну (±20 одним запросом), поэтому стрелки не ждут сеть; когда окно подходит к
   * краю, оно добирается от своего крайнего снимка. Сам кадр — это items[idx].
   */
  const [win, setWin] = useState<{ items: api.TimelineItem[]; idx: number }>(() => (
    saved?.photo ? { items: [saved.photo], idx: 0 } : { items: [], idx: -1 }
  ));
  /** Полноценная деталка (как в «Файлах») — открывается кнопкой «Инфо» из просмотра. */
  const [detailId, setDetailId] = useState<string | null>(saved?.detailId ?? null);
  /** Статусы сборки превью: спрашиваем только про те снимки, что видит пользователь. */
  const [statuses, setStatuses] = useState<Map<string, PreviewStatus>>(() => new Map());
  const [loadErr, setLoadErr] = useState<string | null>(null);
  /** Дни открытого месяца: null — ещё не пришли (календарь на это время не рисуем). */
  const [rows, setRows] = useState<api.TimelineDayItem[] | null>(null);
  /** Фаза открытого месяца: секунда ожидания → запрос → готово. */
  const [phase, setPhase] = useState<'wait' | 'loading' | 'ready' | 'error'>('wait');
  /** Счётчик «перечитать месяц» (после загрузки файлов и удаления снимка). */
  const [reload, setReload] = useState(0);

  const refreshTimerRef = useRef<number | null>(null);
  /** Перечитывание без секундной паузы и без пустого экрана: сетка не мигает. */
  const silentRef = useRef(false);
  /** Окно и позиция для асинхронных переходов: состояние читается из ref, а не из замыкания. */
  const winRef = useRef(win);
  winRef.current = win;
  /** Край галереи по стороне: дальше снимков нет — там уже нечего добирать. */
  const endsRef = useRef({ next: false, prev: false });

  const photo = win.idx >= 0 ? win.items[win.idx] ?? null : null;

  const openPhoto = useCallback((item: api.TimelineItem) => {
    endsRef.current = { next: false, prev: false };
    // Показываем кадр сразу (метаданные уже есть) и подтягиваем окно вокруг него.
    setWin({ items: [item], idx: 0 });
    const key = item.capturedAt?.slice(0, 7);
    if (key) setMonth(key); // календарь под просмотром идёт вместе со снимком
    api.timelineWindow(item.entryId, PHOTO_WINDOW, PHOTO_WINDOW)
      .then((items) => {
        if (!items.length) return;
        const idx = Math.max(0, items.findIndex((i) => i.entryId === item.entryId));
        setWin((cur) => (cur.items[cur.idx]?.entryId === item.entryId ? { items, idx } : cur));
      })
      .catch((e) => setLoadErr((e as Error).message));
  }, []);

  /**
   * Добор окна от его края: пачка в сторону движения плюс сам крайний снимок. Уже известные id
   * отбрасываем — окно растёт, но не перезапрашивает то, что в нём уже лежит.
   */
  const extendWindow = useCallback(async (dir: 'next' | 'prev') => {
    const cur = winRef.current;
    if (!cur.items.length) return;
    const edge = dir === 'next' ? cur.items[cur.items.length - 1] : cur.items[0];
    const fresh = dir === 'next'
      ? await api.timelineWindow(edge.entryId, 0, PHOTO_WINDOW)
      : await api.timelineWindow(edge.entryId, PHOTO_WINDOW, 0);
    if (fresh.length <= 1) endsRef.current[dir] = true; // кроме самого края ничего нет — это край галереи
    setWin((c) => {
      const seen = new Set(c.items.map((i) => i.entryId));
      const add = fresh.filter((i) => !seen.has(i.entryId));
      if (!add.length) return c;
      return dir === 'next'
        ? { items: [...c.items, ...add], idx: c.idx }
        : { items: [...add, ...c.items], idx: c.idx + add.length };
    });
  }, []);

  /** Шаг в просмотре: внутри окна — мгновенно, у края окна — с добором следующей пачки. */
  const stepPhoto = useCallback((dir: 'next' | 'prev') => {
    const cur = winRef.current;
    const at = dir === 'next' ? cur.idx + 1 : cur.idx - 1;
    if (at < 0 || at >= cur.items.length) return; // край галереи: остаёмся на текущем кадре
    setWin({ items: cur.items, idx: at });
    const key = cur.items[at].capturedAt?.slice(0, 7);
    if (key && key !== month) setMonth(key);
    const left = dir === 'next' ? cur.items.length - 1 - at : at;
    if (left <= PHOTO_WINDOW_EDGE && !endsRef.current[dir]) {
      void extendWindow(dir).catch(() => undefined);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [month, extendWindow]);

  // Края листания: без них календарь открывался бы на текущем месяце, даже если снимков в нём нет.
  useEffect(() => {
    api.timelineMonths()
      .then((b) => {
        setBounds(b);
        setMonth((m) => {
          if (b.newest && m > b.newest) return b.newest;
          if (b.oldest && m < b.oldest) return b.oldest;
          return m;
        });
      })
      .catch(() => undefined);
  }, []);

  // Кадр, восстановленный после F5, показываем сразу, а окно вокруг него собираем фоном: иначе
  // стрелки в просмотре упёрлись бы в единственный известный снимок.
  useEffect(() => {
    const restored = winRef.current.items[winRef.current.idx];
    if (!restored) return;
    api.timelineWindow(restored.entryId, PHOTO_WINDOW, PHOTO_WINDOW)
      .then((items) => {
        if (!items.length) return;
        const idx = Math.max(0, items.findIndex((i) => i.entryId === restored.entryId));
        // Окно не подменяем, если пользователь уже успел уйти на другой кадр.
        setWin((cur) => (cur.items.length === 1 ? { items, idx } : cur));
      })
      .catch(() => undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /**
   * Открытый месяц: секунда ожидания (экран успевает показать, куда мы пришли), затем запрос.
   * Кэша месяцев нет — месяц всегда перечитывается. Любое новое нажатие стрелки меняет `month`,
   * эффект перезапускается: таймер и запрос прошлого месяца отменяются, и мы идём дальше, не
   * дожидаясь ответа, который уже никому не нужен.
   */
  useEffect(() => {
    const silent = silentRef.current;
    silentRef.current = false;
    if (!silent) {
      setRows(null);
      setPhase('wait');
    }
    setLoadErr(null);
    const ac = new AbortController();
    const fire = () => {
      if (!silent) setPhase('loading');
      api.timelineDays(month, month, ac.signal)
        .then((list) => {
          if (ac.signal.aborted) return;
          setRows(list);
          setPhase('ready');
        })
        .catch((e) => {
          if (ac.signal.aborted) return; // месяц уже сменили — это не ошибка, а отменённый запрос
          setLoadErr((e as Error).message);
          setPhase('error');
        });
    };
    const t = window.setTimeout(fire, silent ? 0 : MONTH_WAIT_MS);
    return () => {
      window.clearTimeout(t);
      ac.abort();
    };
  }, [month, reload]);

  // Файл догрузился — перечитываем месяц (с задержкой: файлы идут пачкой, месяц нужен один раз).
  // Тихо: сетка под загрузкой не мигает лоадером.
  useEffect(() => {
    if (!uploadedAt || refreshTimerRef.current !== null) return;
    refreshTimerRef.current = window.setTimeout(() => {
      refreshTimerRef.current = null;
      silentRef.current = true;
      setReload((n) => n + 1);
    }, REFRESH_DEBOUNCE_MS);
  }, [uploadedAt]);
  useEffect(() => () => { if (refreshTimerRef.current !== null) window.clearTimeout(refreshTimerRef.current); }, []);

  // Запоминаем экран (месяц, открытый снимок, деталку) — F5 возвращает туда же.
  useEffect(() => {
    patchUi({ photos: { month, photo, detailId } });
  }, [month, photo, detailId]);

  const atNewest = Boolean(bounds?.newest && month >= bounds.newest);
  const atOldest = Boolean(bounds?.oldest && month <= bounds.oldest);

  /**
   * Шаг по месяцам. Стрелки не гаснут никогда: за краями листания месяца нет, но кнопка остаётся
   * живой, а открытый кадр закрывается — идти дальше можно в любой момент, в том числе пока
   * прошлый месяц ещё грузится (его запрос отменяет эффект загрузки).
   */
  const gotoMonth = useCallback((delta: number) => {
    setMonth((m) => {
      const next = shiftMonth(m, delta);
      if (delta > 0 && atNewest) return m;
      if (delta < 0 && atOldest) return m;
      return next;
    });
    // Удержание стрелки зовёт это по многу раз в секунду: без изменений состояние не трогаем,
    // иначе каждая отмена открытого кадра перерисовывала бы экран.
    setWin((c) => (c.idx >= 0 ? { items: [], idx: -1 } : c));
  }, [atNewest, atOldest]);

  /** «К последнему месяцу»: тот же шаг, только сразу на самый свежий месяц со снимками. */
  const gotoNewest = useCallback(() => {
    setWin((c) => (c.idx >= 0 ? { items: [], idx: -1 } : c));
    if (bounds?.newest) setMonth(bounds.newest);
  }, [bounds]);

  const holdPrev = useHoldRepeat(() => gotoMonth(-1), true);
  const holdNext = useHoldRepeat(() => gotoMonth(1), true);

  const dayRows = rows ?? [];

  // Клетки месяца: пустые до первого числа и после последнего — сетка всегда ровная.
  const cells = useMemo(() => {
    const byDay = new Map((rows ?? []).map((r) => [r.day, r]));
    const [y, m] = month.split('-').map(Number);
    const days = new Date(Date.UTC(y, m, 0)).getUTCDate();
    const offset = (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 6) % 7; // Пн — первый столбец
    const out: Array<{ day: number; row: api.TimelineDayItem | null } | null> = new Array(offset).fill(null);
    for (let d = 1; d <= days; d++) {
      const key = `${month}-${String(d).padStart(2, '0')}`;
      out.push({ day: d, row: byDay.get(key) ?? null });
    }
    while (out.length % CAL_COLS !== 0) out.push(null);
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [month, rows]);

  const photoCount = dayRows.reduce((n, r) => n + r.count, 0);

  // Спрашиваем статусы только про то, что видно: обложки дней месяца и открытый кадр.
  const askIds = useMemo(() => {
    const ids = new Set<string>();
    for (const r of dayRows) if (r.cover.previewState !== 'done') ids.add(r.cover.entryId);
    if (photo && photo.previewState !== 'done') ids.add(photo.entryId);
    return [...ids];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dayRows, photo, statuses]);
  const askIdsRef = useRef(askIds);
  askIdsRef.current = askIds;
  useEffect(() => {
    if (!askIds.length) return;
    let stopped = false;
    const tick = async () => {
      const ids = askIdsRef.current;
      if (!ids.length) return;
      try {
        const rows = await api.timelineStatus(ids);
        if (stopped || !rows.length) return;
        setStatuses((prev) => {
          const next = new Map(prev);
          for (const row of rows) {
            next.set(row.entryId, {
              previewState: row.previewState,
              previewError: row.previewError,
              jobState: row.jobState,
              jobError: row.jobError,
            });
          }
          return next;
        });
      } catch { /* следующий тик попробует снова */ }
    };
    void tick();
    const t = setInterval(() => void tick(), STATUS_POLL_MS);
    return () => { stopped = true; clearInterval(t); };
  }, [askIds.length]);

  // Пока открыт просмотр или деталка, страница под ними не прокручивается: иначе получался
  // «двойной скролл» — сдвигалась и галерея, и просмотр.
  const overlay = Boolean(photo || detailId);
  useEffect(() => {
    if (!overlay) return;
    const y = window.scrollY;
    const de = document.documentElement;
    const prevDe = de.style.overflow;
    const prevBody = document.body.style.overflow;
    de.style.overflow = 'hidden';
    document.body.style.overflow = 'hidden';
    return () => {
      de.style.overflow = prevDe;
      document.body.style.overflow = prevBody;
      if (window.scrollY !== y) window.scrollTo(0, y);
    };
  }, [overlay]);

  /**
   * Удаление кадра: соседа запоминаем ДО удаления (после него записи уже нет и соседа не найти),
   * затем открываем его заново (окно строится вокруг нового кадра), а если соседа нет — закрываем
   * просмотр. Месяц перечитываем тихо: сетка под просмотром не должна мигать лоадером.
   */
  const forgetEntry = useCallback((entryId: string, next?: api.TimelineItem | null) => {
    setStatuses((prev) => {
      const nextMap = new Map(prev);
      nextMap.delete(entryId);
      return nextMap;
    });
    setDetailId(null);
    if (next) {
      openPhoto(next);
    } else {
      setWin({ items: [], idx: -1 });
    }
    const key = (next?.capturedAt ?? photo?.capturedAt)?.slice(0, 7) ?? month;
    if (key === month) {
      silentRef.current = true; // день и счётчики месяца перечитываем без секундной паузы
      setReload((n) => n + 1);
    } else {
      setMonth(key);
    }
  }, [photo, month, openPhoto]);

  const retryPreview = useCallback(async (entryId: string) => {
    try {
      await api.retryPreview(entryId);
      setStatuses((prev) => {
        const next = new Map(prev);
        next.delete(entryId);
        return next;
      });
    } catch (e) {
      alert((e as Error).message);
    }
  }, []);

  const busy = up.busy;
  const view2 = photo ? previewState(photo, statuses.get(photo.entryId)) : null;

  // ===== Экран-календарь =====
  return (
    <div>
      <div className="calnav">
        <button
          className="iconbtn"
          title="Предыдущий месяц (удерживайте — быстрее)"
          onPointerDown={holdPrev.start}
          onPointerUp={holdPrev.stop}
          onPointerLeave={holdPrev.stop}
          onPointerCancel={holdPrev.stop}
          onClick={(e) => { if (e.detail === 0) gotoMonth(-1); }}
        ><ChevronLeft /></button>
        {/* Название месяца во время загрузки живёт в центре экрана: в шапке его не дублируем. */}
        <button className="caltitle" title="К последнему месяцу со снимками" onClick={gotoNewest}>
          {phase === 'ready' ? monthTitleOf(month) : ''}
        </button>
        <button
          className="iconbtn"
          title="Следующий месяц (удерживайте — быстрее)"
          onPointerDown={holdNext.start}
          onPointerUp={holdNext.stop}
          onPointerLeave={holdNext.stop}
          onPointerCancel={holdNext.stop}
          onClick={(e) => { if (e.detail === 0) gotoMonth(1); }}
        ><ChevronRight /></button>
      </div>

      {loadErr && <div className="err" style={{ margin: '8px 2px' }}>Не удалось загрузить месяц: {loadErr}</div>}

      {/* Пока месяц не открылся, на экране нет ничего, кроме названия месяца с годом и лоадера. */}
      <div className="calwrap">
        {phase === 'ready' ? (
          <div className="calcenter">
            <div className="calgrid" style={{ gridTemplateColumns: `repeat(${CAL_COLS}, minmax(0, 1fr))` }}>
              {cells.map((c, i) => (c
                ? <DayCell key={c.day} day={c.day} row={c.row} status={c.row ? statuses.get(c.row.cover.entryId) : undefined} onOpen={(row) => openPhoto(row.cover)} />
                : <div key={`b${i}`} className="calcell blank" />))}
            </div>
            <div className="calmeta">
              {dayRows.length
                ? `дней со снимками: ${dayRows.length} · всего фото: ${photoCount}`
                : 'В этом месяце снимков нет'}
            </div>
          </div>
        ) : phase === 'error' ? null : (
          <div className="calload">
            <div className="calloadmonth">{monthTitleOf(month)}</div>
            <span className="spin" />
          </div>
        )}
      </div>

      {/* Кнопка «+»: одна на фото и видео, всегда под большим пальцем — над нижним нав-баром. */}
      {photoFolderId && !overlay && phase === 'ready' && (
        <label
          className={busy ? 'fab off' : 'fab'}
          role="button"
          tabIndex={0}
          aria-label="Добавить фото или видео"
          title={busy ? 'Загрузка уже идёт' : 'Добавить фото или видео'}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              (e.currentTarget.querySelector('input') as HTMLInputElement | null)?.click();
            }
          }}
        >
          <Plus size={26} />
          <input
            type="file"
            accept="image/*,video/*"
            multiple
            tabIndex={-1}
            disabled={busy}
            onChange={(e) => {
              if (e.target.files?.length) up.addFiles(Array.from(e.target.files), photoFolderId);
              e.target.value = '';
            }}
          />
        </label>
      )}

      {/* ===== Экран просмотра: отдельная страница, кадр за кадром ===== */}
      {photo && view2 && (
        <div className="full">
          <div className="mediaarea">
            {view2.ready && photo.sha256 && /^video\//.test(photo.mime) ? (
              // Тот же компонент, что в деталке файла: у него есть фолбэк на оригинал для
              // браузеров без AV1 (Safari/iOS) и playsInline для телефона.
              <VideoPreview key={photo.entryId} meta={{ id: photo.entryId, sha256: photo.sha256, name: photo.name }} />
            ) : view2.ready && photo.sha256 ? (
              // key по снимку: у каждого своя геометрия и свой зум. Лоадер кадра крутится не
              // меньше секунды — переключение стрелками не мигает, даже если картинка уже в памяти.
              <PhotoZoom key={photo.entryId} src={api.previewUrl(photo.sha256, 1080)} />
            ) : (
              <div className="panel">
                {view2.failed ? (
                  <>
                    <div className="copy empty"><CircleX size={14} /> <span>Не удалось собрать превью</span></div>
                    {view2.jobError && (
                      <pre className="copy" style={{ whiteSpace: 'pre-wrap', color: 'var(--danger)', maxHeight: 180, overflow: 'auto' }}>{view2.jobError}</pre>
                    )}
                    <div className="row" style={{ justifyContent: 'center' }}>
                      <button className="btn ghost" onClick={() => void retryPreview(photo.entryId)}><RefreshCw size={16} /> Пересобрать</button>
                      <a className="btn ghost" href={api.fileUrl(photo.entryId)} download><ArrowDownToLine size={16} /> Скачать оригинал</a>
                    </div>
                  </>
                ) : view2.hopeless ? (
                  <div style={{ display: 'grid', placeItems: 'center', gap: 10 }}>
                    <div className="copy">
                      {view2.impossible && view2.jobError ? `Превью не собрать: ${view2.jobError}` : 'Превью для этого файла собрать нельзя'}
                    </div>
                    <div className="row" style={{ justifyContent: 'center' }}>
                      <button className="btn ghost" onClick={() => void retryPreview(photo.entryId)}><RefreshCw size={16} /> Поставить задачу</button>
                      <a className="btn ghost" href={api.fileUrl(photo.entryId)} download><ArrowDownToLine size={16} /> Скачать оригинал</a>
                    </div>
                  </div>
                ) : (
                  <div style={{ display: 'grid', placeItems: 'center', gap: 10 }}>
                    <span className="spin" />
                    <div className="copy empty"><LoaderCircle size={14} /> <span>Готовлю превью…</span></div>
                  </div>
                )}
              </div>
            )}
          </div>
          <div className="tbar">
            <button className="iconbtn" title="Назад в календарь" onClick={() => setWin({ items: [], idx: -1 })}><ChevronLeft /></button>
            {/* Просмотр держит один кадр — в шапке его дата съёмки (та самая «деталка»), а если
                даты нет, имя файла */}
            <span className="calday">
              {photo.capturedAt ? fmtExifDate(photo.capturedAt) ?? dayTitle(photo.capturedAt.slice(0, 10)) : photo.name}
            </span>
            <button className="iconbtn" title="Инфо и действия" onClick={() => setDetailId(photo.entryId)}><Info /></button>
            {/* Скачивание живёт только в деталке («Инфо») — из превью его убрали */}
            <button
              className="iconbtn"
              title="Удалить (в корзину)"
              onClick={async () => {
                if (!confirm(`Удалить «${photo.name}» в корзину?`)) return;
                try {
                  // соседа запоминаем до удаления: после него записи уже нет
                  const next = await api.neighborPhoto(photo.entryId, 'next').catch(() => null);
                  await api.deleteFile(photo.entryId);
                  forgetEntry(photo.entryId, next);
                } catch (e) {
                  alert((e as Error).message);
                }
              }}
            ><Trash /></button>
            {/* Стрелки не гаснут: кадр берётся из уже загруженного окна, ждать сеть не нужно. */}
            <button className="iconbtn" title="Предыдущий снимок" onClick={() => stepPhoto('prev')}><ArrowLeft /></button>
            <button className="iconbtn" title="Следующий снимок" onClick={() => stepPhoto('next')}><ArrowRight /></button>
          </div>

          {/* Деталка кадра — карточка в потоке просмотра: остров между шапкой и нижним
              островом-навигацией, теми же зазорами и границами. Свой скролл — у карточки. */}
          {detailId && (
            <div className="ovl" key={detailId}>
              <FileDetail entryId={detailId} onBack={() => setDetailId(null)} onDeleted={forgetEntry} inOverlay />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// Зум только для фото (щипок/дабл-тап/пан); страница при этом не зуммится
function PhotoZoom({ src }: { src: string }) {
  const box = useRef<HTMLDivElement>(null);
  const nat = useRef({ w: 0, h: 0 });
  const [g, setG] = useState({ ox: 0, oy: 0, bw: 1, bh: 1, z: 1, tx: 0, ty: 0 });
  const gcur = useRef(g);
  const pts = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef({ d0: 0, z0: 1, ix: 0, iy: 0 });
  const pan0 = useRef({ tx: 0, ty: 0, px: 0, py: 0 });
  const lastTap = useRef(0);
  const [state, setState] = useState<'loading' | 'ready' | 'failed'>('loading');
  /** Когда кадр открыли: от этого считаем минимальное время лоадера. */
  const shownAt = useRef(Date.now());

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

  // Кадр грузит сам <img> (см. разметку ниже): никакого прогрева и никакого второго запроса.
  // Размер нужен до показа — поэтому ждём onLoad. Лоадер при этом держим минимум LOADER_MIN_MS:
  // иначе на кадре, который браузер уже держит в памяти, спиннер мигал бы на одно мгновение.
  const onLoaded = (img: HTMLImageElement) => {
    nat.current = { w: img.naturalWidth, h: img.naturalHeight };
    const left = Math.max(0, LOADER_MIN_MS - (Date.now() - shownAt.current));
    window.setTimeout(() => {
      setState('ready');
      commit(1, 0, 0);
    }, left);
  };

  return (
    <div
      ref={box}
      style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden', touchAction: 'none', background: 'var(--media)' }}
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
    >
      {/* Миниатюра из сетки под кадром: пока 1080 грузится, видно хоть что-то осмысленное —
          переключение стрелками не выглядит пустым экраном. */}
      {state === 'loading' && (
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center' }}>
          <span className="spin" />
        </div>
      )}
      {state === 'failed' && (
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', padding: 16 }}>
          <div className="copy">Превью не открылось — файл мог быть удалён, попробуйте обновить ленту</div>
        </div>
      )}
      {state !== 'failed' && (
        <img
          src={src}
          alt=""
          draggable={false}
          onLoad={(e) => onLoaded(e.currentTarget)}
          onError={() => setState('failed')}
          style={state === 'ready' ? {
            position: 'absolute',
            left: g.ox + g.tx,
            top: g.oy + g.ty,
            width: g.bw * g.z,
            height: g.bh * g.z,
            maxWidth: 'none',
            maxHeight: 'none',
            userSelect: 'none', WebkitUserSelect: 'none',
            touchAction: 'none',
          } : { display: 'none' }}
        />
      )}
    </div>
  );
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
      <div className="row"><span style={{ flex: 1 }} /><button className="btn" title="Создать ссылку" onClick={create}><Link2 size={16} /></button></div>
      {notice && <div className="notice">{notice}</div>}
      {err && <div className="err">{err}</div>}
      {items.map((s) => (
        <div className="item" key={s.token}>
          <span className="icon"><Link2 /></span>
          <span className="fname">{s.kind} · {s.capability}{s.hasPassword ? <> · <Lock size={13} /></> : ''}{s.expiresAt ? ` · до ${new Date(s.expiresAt).toLocaleDateString()}` : ''}</span>
          <button className="btn ghost" onClick={() => { navigator.clipboard.writeText(s.url); setNotice('Скопировано'); }}><Copy size={16} /></button>
          <button className="btn ghost" onClick={async () => { await api.revokeShare(s.token); await load(); }}><Ban size={16} /></button>
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
      <div className="row"><span style={{ flex: 1 }} /><button className="btn" title="Новый альбом" onClick={create}><Images size={16} /></button></div>
      {err && <div className="err">{err}</div>}
      {albums.map((a) => (
        <div className="item" key={a.id}>
          <span className="icon"><Images /></span>
          <span className="fname" onClick={() => setOpenId(a.id)}>{a.name}</span>
          <span className="meta">{a.count}</span>
          <button className="btn ghost" onClick={async () => { if (confirm('Удалить альбом?')) { await api.deleteAlbum(a.id); if (openId === a.id) setOpenId(null); await load(); } }}><Trash size={16} /></button>
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
                  <img src={api.fileInlineUrl(it.entryId)} alt={it.name} loading="lazy" style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', borderRadius: 6, background: 'var(--surface-3)' }} />
                ) : (
                  <div style={{ width: '100%', aspectRatio: '1', borderRadius: 6, background: 'var(--surface-3)', color: 'var(--fg-3)', display: 'grid', placeItems: 'center' }}><FileText size={28} /></div>
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
  // Ошибки очереди — отдельная страница настроек: список упавших задач не должен мешать
  // основному экрану очереди, где только цифры.
  const [view, setView] = useState<'main' | 'queue-errors'>('main');
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
  if (view === 'queue-errors') return <QueueErrorsPanel onBack={() => setView('main')} />;
  return (
    <div>
      <div className="panel">
        <div className="row"><span className="icon"><UserRound /></span><strong>{login}</strong></div>
        <div className="row">
          <a className="fname" href={location.origin}>{location.origin}</a>
          <button className="btn danger" onClick={async () => { await api.logout().catch(() => undefined); onLogout(); }}>Выйти</button>
        </div>
      </div>
      <div className="panel">
        <div className="row"><strong>Приложения (WebDAV/Finder)</strong><button className="btn" onClick={addToken}><KeyRound size={16} /> токен</button></div>
        {fresh && (
          <div className="panel" style={{ background: 'var(--accent-soft)' }}>
            <div className="copy">Токен (один раз): <b>{fresh}</b></div>
            <div className="copy">WebDAV: https://files.iq-factura.com/api/v1/dav · логин: {login}</div>
          </div>
        )}
        {err && <div className="err">{err}</div>}
        {tokens.map((t) => (
          <div className="item" key={t.id}>
            <span className="icon"><KeyRound /></span>
            <span className="fname">{t.label}</span>
            <span className="meta">{t.lastUsedAt ? new Date(t.lastUsedAt).toLocaleString() : 'не использовался'}</span>
            <button className="btn ghost" onClick={async () => { await api.revokeToken(t.id); await loadTokens(); }}><Ban size={16} /></button>
          </div>
        ))}
        {!tokens.length && <div className="copy">Токенов нет — нужен для Finder/WebDAV</div>}
      </div>
      <QueuePanel onErrors={() => setView('queue-errors')} />
    </div>
  );
}

// ================= Очередь превью =================

const JOB_KIND: Record<string, LucideIcon> = { photo: ImageIcon, video: Film, pdf: FileText };

/** Значок типа задачи в списке ошибок: у неизвестного типа — общий знак предупреждения. */
function JobKindIcon({ kind }: { kind: string }) {
  const Icon = JOB_KIND[kind] ?? CircleAlert;
  return <Icon />;
}

/**
 * Очередь превью: сколько осталось, пауза и пересчёт. Больше на этом экране ничего нет —
 * прогресс, скорости и остаток времени убраны: очередь либо разбирается, либо стоит.
 * Упавшие задачи живут на отдельной странице (иначе их нечем повторить).
 */
function QueuePanel({ onErrors }: { onErrors: () => void }) {
  const [q, setQ] = useState<api.QueueStatus | null>(null);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);

  const load = async () => {
    try {
      setQ(await api.queueStatus());
      setErr('');
    } catch (e) { setErr((e as Error).message); }
  };
  // Пока очередь разбирается — раз в 2 с, на простое — раз в 10 с.
  const working = Boolean(q?.processing);
  useEffect(() => {
    void load();
    const t = setInterval(() => { void load(); }, working ? 2000 : 10000);
    return () => clearInterval(t);
  }, [working]);

  // Пауза мягкая: новые задачи не берутся, текущая докачивается (для видео это важно —
  // прерванный AV1-энкод означает часы работы заново), PDF встаёт между страницами.
  const togglePause = async () => {
    try { await api.setQueuePaused(!q?.paused); await load(); } catch (e) { setErr((e as Error).message); }
  };

  // Пересчёт: найти файлы без превью и поставить им задачи. Ходит только по БД, ничего
  // не пересобирает заново, повторное нажатие не создаёт вторых задач.
  const rebuild = async () => {
    setBusy(true);
    setNotice('');
    try {
      const r = await api.rebuildPreviews();
      // Дубли (лишние строки на один файл) пересчёт схлопывает сам — если такие были, говорим.
      const dupes = r.deduped ? ` · схлопнуто дублей: ${r.deduped.toLocaleString('ru-RU')}` : '';
      setNotice(
        r.queued
          ? `Поставлено задач: ${r.queued.toLocaleString('ru-RU')}${r.impossible ? ` · собрать нельзя: ${r.impossible.toLocaleString('ru-RU')}` : ''}${dupes}`
          : `Новых задач нет — всё, что можно собрать, уже в очереди${r.impossible ? ` · собрать нельзя: ${r.impossible.toLocaleString('ru-RU')}` : ''}${dupes}`,
      );
      await load();
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };

  // Очистка: удалить все строки очереди, включая упавшие. Собранные превью остаются, поэтому
  // очередь пуста ровно до «Пересчитать» — оно и поставит задачи тем файлам, где превью нет.
  const clear = async () => {
    const parts: string[] = [];
    if (remaining) parts.push(`в остатке ${remaining.toLocaleString('ru-RU')}`);
    if (q?.errors) parts.push(`упавших ${q.errors.toLocaleString('ru-RU')}`);
    const ok = confirm(
      `Удалить все строки очереди${parts.length ? ` (${parts.join(', ')})` : ''}?\n\n` +
        'Собранные превью останутся на месте. Задача, которая считается сейчас, не прервётся.\n' +
        'Чтобы вернуть недостающие превью в очередь — нажмите «Пересчитать».',
    );
    if (!ok) return;
    setBusy(true);
    setNotice('');
    try {
      const r = await api.clearQueue();
      setNotice(
        `Очередь очищена — удалено строк: ${r.removed.toLocaleString('ru-RU')}.` +
          (r.resumed ? ` PDF с недорисованными страницами: ${r.resumed.toLocaleString('ru-RU')} — их вернёт пересчёт.` : '') +
          ' Нажмите «Пересчитать», чтобы поставить задачи файлам без превью.',
      );
      await load();
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };

  const remaining = q?.remaining ?? 0;

  return (
    <div className="panel">
      <div className="row">
        <strong>Очередь превью</strong>
        <span style={{ flex: 1 }} />
        <button className={q?.paused ? 'btn' : 'btn ghost'} disabled={!q} onClick={togglePause} title="Пауза мягкая: текущая задача докачивается, новые не берутся">
          {q?.paused ? <><Play size={16} /> Продолжить</> : <><Pause size={16} /> Пауза</>}
        </button>
        <button className="btn ghost" disabled={busy || !q} onClick={clear} title="Удалить все строки очереди. Собранные превью остаются — вернуть недостающие можно кнопкой «Пересчитать»">
          <Eraser size={16} /> Очистить
        </button>
        <button className="btn ghost" disabled={busy || !q} onClick={rebuild} title="Найти файлы без превью и поставить им задачи">
          {busy ? '…' : <><RefreshCw size={16} /> Пересчитать</>}
        </button>
      </div>
      {err && <div className="err">{err}</div>}
      {notice && <div className="notice">{notice}</div>}
      {!q && !err && <div className="copy">Загрузка…</div>}
      {q && (
        <>
          <div className="row" style={{ alignItems: 'baseline' }}>
            <span className="fname">Осталось: {remaining.toLocaleString('ru-RU')}</span>
            {q.processing > 0 && <span className="meta">в работе {q.processing}</span>}
          </div>
          {/* Разбивка остатка по типам: фото уходят пачкой, видео идёт по одному и часами —
              без неё «осталось 500» ничего не говорит о том, сколько это займёт.
              PDF показываем, только когда они есть: обычно их нет вовсе. */}
          {!!remaining && (
            <div className="copy">
              фото: {(q.remainingByKind?.photo ?? 0).toLocaleString('ru-RU')}
              {' · '}видео: {(q.remainingByKind?.video ?? 0).toLocaleString('ru-RU')}
              {q.remainingByKind?.pdf ? ` · PDF: ${q.remainingByKind.pdf.toLocaleString('ru-RU')}` : ''}
            </div>
          )}
          <div className={q.paused ? 'copy empty' : 'copy'}>
            {q.paused ? <><Pause size={14} /> <span>пауза — задачи ждут в очереди</span></> : remaining ? 'очередь разбирается' : 'очередь пуста'}
          </div>
          {/* Место на диске сервера: если оно кончится, ляжет весь сервис, поэтому показываем
              его всегда — и отдельно предупреждаем, когда конвертация из-за него встала. */}
          {q.diskFree != null && (
            <div className={q.diskLow ? 'err' : 'copy'}>
              {q.diskLow
                ? <><CircleAlert size={13} /> <span>{`на диске сервера мало места (${fmt(q.diskFree)} свободно) — конвертация стоит, пока не освободится`}</span></>
                : `диск сервера: ${fmt(q.diskFree)} свободно`}
            </div>
          )}
        </>
      )}
      <div className="row">
        <button className="btn ghost" disabled={!q} onClick={onErrors} title="Задачи, которые упали при конвертации">
          <CircleAlert size={16} /> Ошибки{q?.errors ? `: ${q.errors.toLocaleString('ru-RU')}` : ''}
        </button>
      </div>
    </div>
  );
}

/** Ошибки очереди отдельной страницей: файл, текст ошибки, попытки и «повторить». */
function QueueErrorsPanel({ onBack }: { onBack: () => void }) {
  const LIMIT = 50;
  const [data, setData] = useState<{ total: number; items: api.QueueErrorRow[] } | null>(null);
  const [offset, setOffset] = useState(0);
  const [err, setErr] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);

  const load = async () => {
    try {
      setData(await api.queueErrors({ limit: LIMIT, offset }));
      setErr('');
    } catch (e) { setErr((e as Error).message); }
  };
  useEffect(() => { void load(); }, [offset]);

  const retryOne = async (entryId: string | null) => {
    if (!entryId) return;
    try {
      await api.retryPreview(entryId);
      setNotice('Файл снова в очереди');
      await load();
    } catch (e) { setErr((e as Error).message); }
  };

  const retryAll = async () => {
    setBusy(true);
    setNotice('');
    try {
      const r = await api.retryQueueErrors();
      setNotice(`Возвращено в очередь: ${r.retried}`);
      setOffset(0);
      await load();
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  };

  const total = data?.total ?? 0;
  const shown = data?.items.length ?? 0;

  return (
    <div className="panel">
      <div className="row">
        <button className="iconbtn" onClick={onBack} title="Назад к очереди"><ChevronLeft /></button>
        <strong>Ошибки очереди</strong>
        <span className="meta">{total.toLocaleString('ru-RU')}</span>
        <span style={{ flex: 1 }} />
        <button className="btn" disabled={busy || !total} onClick={retryAll}><RefreshCw size={16} /> Повторить все</button>
      </div>
      {err && <div className="err">{err}</div>}
      {notice && <div className="notice">{notice}</div>}
      {!data && !err && <div className="copy">Загрузка…</div>}
      {data && !shown && <div className="copy">Ошибок нет — очередь разбирается без падений</div>}
      {data?.items.map((j) => (
        <div className="item" key={j.id} style={{ alignItems: 'flex-start' }}>
          <span className="icon" title={j.kind}><JobKindIcon kind={j.kind} /></span>
          <span className="fname" style={{ whiteSpace: 'normal' }}>
            {j.entryId ? <a href={api.fileUrl(j.entryId)}>{j.name ?? 'файл'}</a> : (j.name ?? 'файл удалён')}
            <div className="err" style={{ fontWeight: 400 }}>{j.error}</div>
            <div className="meta">
              попыток: {j.attempts}
              {j.finishedAt ? ` · ${new Date(j.finishedAt).toLocaleString()}` : ''}
            </div>
          </span>
          <button className="btn ghost" disabled={!j.entryId} onClick={() => void retryOne(j.entryId)} title="Поставить задачу в очередь заново"><RefreshCw size={16} /></button>
        </div>
      ))}
      {total > LIMIT && (
        <div className="row">
          <button className="btn ghost" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - LIMIT))}><ChevronLeft size={16} /> назад</button>
          <span className="meta">{offset + 1}–{offset + shown} из {total.toLocaleString('ru-RU')}</span>
          <button className="btn ghost" disabled={offset + shown >= total} onClick={() => setOffset(offset + LIMIT)}>вперёд <ChevronRight size={16} /></button>
        </div>
      )}
    </div>
  );
}

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
        <button className="btn danger" title="Очистить корзину" onClick={purge}><Eraser size={16} /></button>
      </div>
      {err && <div className="err">{err}</div>}
      <div className="panel">
        {items.map((t) => (
          <div className="item" key={t.kind + t.id}>
            <span className="icon">{t.kind === 'folder' ? <Folder /> : <FileText />}</span>
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
