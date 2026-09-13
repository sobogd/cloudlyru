// Единое хранилище UI-состояния.
//
// localStorage, а не sessionStorage: позиция, открытая деталка и вкладка должны переживать
// закрытие веб-приложения, чтобы при возврате не искать заново, на чём остановился.

/** Вкладки нижнего острова. `albums` остался в типе: экран «Альбомы» живёт в коде и может
    вернуться в навигацию одной строкой, а сохранённая вкладка не должна теряться. */
export type Tab = 'files' | 'media' | 'map' | 'albums' | 'trash' | 'settings';

export type UiState = {
  tab?: Tab;
  files?: { stack?: Array<{ id?: string; name: string }>; openFile?: string | null; folderMeta?: boolean };
  albums?: { openId?: string | null };
  /** Последний вид карты: центр и зум, чтобы вкладка открывалась там же, где её закрыли. */
  map?: { lat: number; lon: number; zoom: number };
  media?: {
    /** Индекс первого видимого элемента ленты «Медиа» (надёжнее, чем сырой scrollTop). */
    index?: number;
    scrollTop?: number;
    /** Открытый кадр в модалке «Медиа» (null/отсутствует — модалка закрыта). */
    openIdx?: number | null;
  };
};

const UI_KEY = 'cloudlyru:ui';

export function readUi(): UiState {
  try {
    return JSON.parse(localStorage.getItem(UI_KEY) || '{}') as UiState;
  } catch {
    return {};
  }
}

export function patchUi(patch: Partial<UiState>): void {
  try {
    localStorage.setItem(UI_KEY, JSON.stringify({ ...readUi(), ...patch }));
  } catch {
    /* приватный режим — состояние просто не сохраняется */
  }
}

export function clearUi(): void {
  try {
    localStorage.removeItem(UI_KEY);
  } catch {
    /* приватный режим */
  }
}
