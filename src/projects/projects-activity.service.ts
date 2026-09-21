import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ProjectsService } from './projects.service';

/** Сессия, которая считается прямо сейчас. */
export interface RunningSession {
  /** Идентификатор (`харнесс--id`) — тот же, что в списке сессий приложения. */
  id: string;
  /** Харнесс: pi или claude. */
  harness: string;
  /** Папка проекта, в которой идёт работа. */
  path: string;
}

/** Разговор, который закончился недавно: по нему приложение говорит «готово». */
export interface FinishedSession extends RunningSession {
  /** Когда прогон завершился (ISO). */
  at: string;
}

/** Снимок работы на маке. */
export interface ActivitySnapshot {
  running: RunningSession[];
  finished: FinishedSession[];
  /** Когда снимок обновлялся — приложение по этому видит, что связь жива. */
  updatedAt: string | null;
}

/** Как часто спрашивать мост о том, что считается. */
const POLL_MS = 5_000;
/** Сколько держать в памяти завершённые прогоны: дольше — уже не «только что готово». */
const KEEP_FINISHED_MS = 30 * 60_000;

/**
 * Кто на маке работает прямо сейчас и что закончилось.
 *
 * Зачем это на сервере, если мост и так отдаёт занятость: приложению нужно знать не только
 * «сейчас занято», но и «пока меня не было, ответ дописался» — а для этого состояние должно
 * жить там, где оно есть всегда. Мак и приложение могут быть закрыты, сервер работает.
 *
 * Push-канала у приложения нет, поэтому «уведомление» здесь — факт в снимке: приложение, когда
 * открыто, спрашивает снимок и показывает, что уже готово. Настоящие уведомления в фоне — это
 * отдельная работа (FCM/APNs), и без неё честнее показывать готовность при следующем открытии.
 */
@Injectable()
export class ProjectsActivityService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(ProjectsActivityService.name);
  private timer: NodeJS.Timeout | null = null;

  /** Что считалось на прошлом проходе: по разнице и находятся завершения. */
  private running = new Map<string, RunningSession>();
  /** Завершённые прогоны за последние полчаса. */
  private finished = new Map<string, FinishedSession>();
  private updatedAt: string | null = null;

  constructor(private readonly projects: ProjectsService) {}

  onModuleInit(): void {
    // Опрос вместо подписки: мост — простой HTTP-сервис без событий, а пять секунд ожидания
    // заметны только тому, кто смотрит на экран списка
    this.timer = setInterval(() => void this.tick(), POLL_MS);
    // Первый проход сразу: иначе до первого тика снимок пустой и экран не покажет ничего
    void this.tick();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Снимок работы: кто считается и что закончилось недавно. */
  snapshot(): ActivitySnapshot {
    const now = Date.now();
    // Чистим по времени показа, а не по таймеру: иначе старые записи висели бы до следующего тика
    for (const [id, item] of this.finished) {
      if (now - Date.parse(item.at) > KEEP_FINISHED_MS) this.finished.delete(id);
    }
    return {
      running: [...this.running.values()],
      finished: [...this.finished.values()],
      updatedAt: this.updatedAt,
    };
  }

  /** Один проход: спрашивает мост и обновляет снимок. */
  private async tick(): Promise<void> {
    if (!this.projects.configured) return;
    let sessions: Array<{ id?: unknown; harness?: unknown; cwd?: unknown; busy?: unknown }>;
    try {
      const health = await this.projects.call<{ sessions?: unknown }>('GET', '/health', {
        timeoutMs: 15_000,
      });
      sessions = Array.isArray(health.sessions)
        ? (health.sessions as Array<Record<string, unknown>>)
        : [];
    } catch (e) {
      // Мост недоступен (мак спит, туннель отключился) — это не ошибка сервера: снимок просто
      // перестаёт обновляться, и приложение видит это по времени обновления
      this.logger.debug(`мост недоступен, снимок работы не обновлён: ${String(e)}`);
      return;
    }

    const now = new Date().toISOString();
    const current = new Map<string, RunningSession>();
    for (const session of sessions) {
      const id = typeof session.id === 'string' ? session.id : '';
      if (!id || session.busy !== true) continue;
      current.set(id, {
        id,
        harness: typeof session.harness === 'string' ? session.harness : 'pi',
        path: typeof session.cwd === 'string' ? session.cwd : '',
      });
    }

    // Всё, что считалось и перестало — завершилось (или процесс погас по простою)
    for (const [id, item] of this.running) {
      if (!current.has(id)) this.finished.set(id, { ...item, at: now });
    }
    // Начавшееся заново снимает пометку «готово»: разговор снова в работе
    for (const id of current.keys()) this.finished.delete(id);

    this.running = current;
    this.updatedAt = now;
  }
}
