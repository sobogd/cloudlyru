import { Body, Controller, Get, HttpStatus, Logger, Post, Query } from '@nestjs/common';
import { ApiError } from '../common/errors';
import { MacError, MacService } from './mac.service';

/** Машинный код ошибки по HTTP-коду панели — приложение по нему выбирает ветку поведения. */
function codeFor(status: number): string {
  if (status === 503) return 'mac_unconfigured';
  if (status === 504) return 'mac_timeout';
  if (status === 502) return 'mac_unreachable';
  return 'mac_error';
}

/**
 * Раздел «Mac»: статус и управление домашним маком.
 *
 * Панель, модель и все данные живут на маке, но запросы делает сервер. Клиент приложения ходит
 * только в ручки `/mac/*`, поэтому адреса туннеля, порта и ключей в сборке нет; доступ закрыт
 * той же сессией, что и остальные разделы (`AuthGuard` в `app.module`).
 *
 * Плата за это — доверие к маку: ручки панели не имеют собственной аутентификации (доверие
 * loopback туннеля), а `/mac/envs/*` отдаёт содержимое `.env` и `/mac/term/*` — полный shell.
 * Их вынос в приложение обсуждается отдельно (см. AGENTS.md), пока они проксируются как есть.
 */
@Controller('mac')
export class MacController {
  private readonly logger = new Logger(MacController.name);

  constructor(private readonly mac: MacService) {}

  /** Доступна ли панель: по этому ответу раздел решает «показать данные» или «мак спит». */
  @Get('health')
  async health() {
    await this.wrap(() => this.mac.call('GET', '/api/status'));
    return { ok: true };
  }

  /** Снимок состояния: CPU/RAM/диски/батарея/IP/uptime, WARP, службы, безопасность. */
  @Get('status')
  async status() {
    return this.wrap(() => this.mac.call('GET', '/api/status'));
  }

  /** История CPU/RAM за ~100 минут (семпл каждые 15 с) для графика. */
  @Get('history')
  async history() {
    return this.wrap(() => this.mac.call('GET', '/api/history'));
  }

  /** Действие над маком из белого списка панели (reboot, sleep, firewall-on, …). */
  @Post('action')
  async action(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.mac.call('POST', '/api/action', { body: { action: str(body.action) } }),
    );
  }

  /** WARP: connect | disconnect | reconnect | status. */
  @Post('warp')
  async warp(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() => this.mac.call('POST', '/api/warp', { body: { op: str(body.op) } }));
  }

  /** Состояние Claude (tangem): запущен ли агент, авторизован ли. */
  @Get('claude')
  async claude() {
    return this.wrap(() => this.mac.call('GET', '/api/claude'));
  }

  /** Начинает вход в Claude: возвращает authorize URL, который человек открывает сам. */
  @Post('claude/login')
  async claudeLogin() {
    return this.wrap(() => this.mac.call('POST', '/api/claude/login'));
  }

  /** Завершает вход в Claude кодом, который человек скопировал после авторизации. */
  @Post('claude/code')
  async claudeCode(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.mac.call('POST', '/api/claude/code', { body: { code: str(body.code) } }),
    );
  }

  /** Дашборд GitHub Actions: настроенные workflow с последним запуском и средней длительностью. */
  @Get('github-actions')
  async githubActions(@Query('refresh') refresh?: string) {
    const q = refresh ? `?refresh=${encodeURIComponent(refresh)}` : '';
    return this.wrap(() => this.mac.call('GET', `/api/github-actions${q}`));
  }

  /** Ветки и теги репозитория для формы запуска workflow. */
  @Get('github-actions/refs')
  async githubRefs(@Query('repo') repo?: string) {
    const q = repo ? `?repo=${encodeURIComponent(repo)}` : '';
    return this.wrap(() => this.mac.call('GET', `/api/github-actions/refs${q}`));
  }

  /** Запуск настроенного workflow с веткой/тегом и inputs. */
  @Post('github-actions/run')
  async githubRun(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() => this.mac.call('POST', '/api/github-actions/run', { body }));
  }

  /** Перезапуск уже существующего запуска по run_id. */
  @Post('github-actions/rerun')
  async githubRerun(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() => this.mac.call('POST', '/api/github-actions/rerun', { body }));
  }

  /** Правка списка workflow в `github-actions.json` на маке. */
  @Post('github-actions/config')
  async githubConfig(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() => this.mac.call('POST', '/api/github-actions/config', { body }));
  }

  /**
   * Список `.env`-файлов под `~/work` на маке.
   *
   * ВНИМАНИЕ: чтение `.env` отдаёт значения секретов наружу. Ручка включена для полноты раздела
   * и должна быть закрыта дополнительно, если раздел «Mac» пойдёт в прод (см. AGENTS.md).
   */
  @Get('envs')
  async envs() {
    return this.wrap(() => this.mac.call('GET', '/api/envs'));
  }

  /** Содержимое одного `.env`-файла. */
  @Get('envs/read')
  async envRead(@Query('path') path?: string) {
    const q = path ? `?path=${encodeURIComponent(path)}` : '';
    return this.wrap(() => this.mac.call('GET', `/api/envs/read${q}`));
  }

  /** Атомарная запись `.env`-файла (бэкап панель делает сама). */
  @Post('envs/write')
  async envWrite(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() => this.mac.call('POST', '/api/envs/write', { body }));
  }

  /** Текущий хвост консоли мака (poll по смещению). */
  @Get('term/poll')
  async termPoll(@Query('after') after?: string) {
    const q = after ? `?after=${encodeURIComponent(after)}` : '';
    return this.wrap(() => this.mac.call('GET', `/api/term/poll${q}`));
  }

  /** История последних команд консоли. */
  @Get('term/history')
  async termHistory() {
    return this.wrap(() => this.mac.call('GET', '/api/term/history'));
  }

  /** Открывает (или переиспользует) постоянную сессию `bash` на маке. */
  @Post('term/open')
  async termOpen() {
    return this.wrap(() => this.mac.call('POST', '/api/term/open'));
  }

  /** Отправляет строку ввода в консоль. */
  @Post('term/input')
  async termInput(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.mac.call('POST', '/api/term/input', { body: { data: str(body.data) } }),
    );
  }

  /** Повторяет предыдущую команду по индексу (0 — последняя). */
  @Post('term/again')
  async termAgain(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.mac.call('POST', '/api/term/again', { body: { idx: toNum(body.idx) ?? 0 } }),
    );
  }

  /** Сбрасывает сессию консоли, начиная новую. */
  @Post('term/reset')
  async termReset() {
    return this.wrap(() => this.mac.call('POST', '/api/term/reset'));
  }

  /** Переводит сбой панели в HTTP-ответ; 5xx логируются, чтобы причина осталась в pm2-логе. */
  private async wrap<T>(run: () => Promise<T>): Promise<T> {
    try {
      return await run();
    } catch (e) {
      if (!(e instanceof MacError)) throw e;
      const status = e.status;
      if (status >= 500) this.logger.warn(`mac: ${status} ${e.message}`);
      throw new ApiError(status as HttpStatus, e.message, codeFor(status));
    }
  }
}

/** Строковое поле из тела запроса: не-строки дают пустую строку, а не падение. */
function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

/** Число из тела запроса; не-число даёт `null`, чтобы вызывающий подставил дефолт. */
function toNum(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}
