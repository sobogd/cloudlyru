import { AsyncLocalStorage } from 'node:async_hooks';

/** Контекст обработки одного запроса; сейчас — только источник изменения для журнала. */
export interface RequestContext {
  /** id ApiToken устройства, если запрос пришёл от клиента синхронизации. */
  deviceId?: string;
}

const storage = new AsyncLocalStorage<RequestContext>();

/**
 * Контекст запроса через AsyncLocalStorage: журнал изменений должен знать, какое устройство
 * сделало правку, но вызовов `changes.record` много (папки, файлы, загрузки, распаковка,
 * WebDAV), и протаскивать deviceId аргументом через все сервисы — шум в сигнатурах,
 * который к тому же легко забыть в новом вызове.
 */
export function runWithRequestContext<T>(ctx: RequestContext, fn: () => T): T {
  return storage.run(ctx, fn);
}

/** Заполняется гардом при аутентификации по ApiToken (Bearer); у веб-сессии не вызывается. */
export function setCurrentDeviceId(id: string): void {
  const ctx = storage.getStore();
  if (ctx) ctx.deviceId = id;
}

/** id устройства текущего запроса или null (веб-сессия, WebDAV, фоновые задачи). */
export function currentDeviceId(): string | null {
  return storage.getStore()?.deviceId ?? null;
}
