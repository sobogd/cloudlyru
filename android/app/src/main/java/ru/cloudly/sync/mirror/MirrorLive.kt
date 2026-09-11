package ru.cloudly.sync.mirror

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import ru.cloudly.sync.net.Api
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Мгновенная реакция, пока жив процесс приложения.
 *
 * Два канала:
 *   • облако → телефон: частый опрос головы журнала (`GET /sync/head` — крошечный запрос).
 *     Голова сдвинулась — сразу догоняем журнал, файлы приезжают за секунды;
 *   • телефон → облако: событие файловой системы ([MirrorWatcher]) запускает проход почти
 *     сразу, с короткой выдержкой на всплеск событий.
 *
 * Пока приложение выгружено из памяти, наблюдать некому — тогда работает только страховочный
 * периодический проход (раз в 15 минут, см. [MirrorScheduler]). Резидентного сервиса с
 * постоянным уведомлением здесь нет намеренно: это цена, которую пользователь не выбирал.
 *
 * Опрос прекращается, когда токена нет или сервер не отвечает: в Doze сеть всё равно спит,
 * и долбить её каждые три секунды смысла нет — после нескольких ошибок пауза становится длинной.
 */
class MirrorLive(
    private val api: Api,
    private val store: MirrorStore,
    private val engine: MirrorEngine,
    private val status: MirrorStatusHolder,
    private val scope: CoroutineScope,
    /** Есть ли токен: без него опрашивать нечего и незачем. */
    private val hasToken: () -> Boolean,
    /** Выключено ли зеркало пользователем: тогда ни опрос, ни проходы не запускаются. */
    private val paused: () -> Boolean,
    /** Приложение на экране: тогда спрашиваем журнал часто, в фоне — редко. */
    private val foreground: () -> Boolean,
) {

    private val polling = AtomicBoolean(false)
    private val pendingLocal = AtomicBoolean(false)

    /** Когда проходил последний проход по событию файлов: чаще, чем раз в полминуты, незачем. */
    private val lastLocalPassAt = AtomicLong(0)

    /** Запустить цикл опроса. Повторный вызов ничего не делает. */
    fun start() {
        if (!polling.compareAndSet(false, true)) return
        scope.launch {
            var failures = 0
            while (isActive) {
                // В фоне опрашивать раз в три секунды незачем: экран не горит, никто не ждёт,
                // а радио каждые три секунды не даёт устройству уйти в сон
                delay(
                    when {
                        failures > 0 -> FAIL_BACKOFF_MS
                        foreground() -> POLL_MS
                        else -> POLL_BACKGROUND_MS
                    },
                )
                // «выключено» значит выключено: ни догона журнала, ни удалений из облака
                if (paused()) continue
                if (!hasToken()) continue
                // файл, отложенный окном стабильности, ждёт своей минуты: возвращаемся к нему
                val retryAt = runCatching { store.meta(MirrorStore.KEY_RETRY_AT)?.toLongOrNull() }.getOrNull()
                if (retryAt != null && System.currentTimeMillis() >= retryAt) {
                    store.clearMeta(MirrorStore.KEY_RETRY_AT)
                    runCatching { engine.pass(onProgress = { Log.i(TAG, "догоняю: $it") }) }
                    continue
                }
                // курсора нет — зеркало ещё не сделало первый проход, догонять нечего
                val cursor = runCatching { store.cursor() }.getOrNull() ?: continue
                val head = try {
                    api.syncHead()
                } catch (e: Exception) {
                    failures += 1
                    if (failures == 1) Log.i(TAG, "опрос журнала не удался: ${e.message}")
                    continue
                }
                failures = 0
                status.update { copy(checkedAt = System.currentTimeMillis(), error = null) }
                if (head <= cursor) continue
                runCatching { engine.catchUpCloud(onProgress = { Log.i(TAG, "облако: $it") }) }
                    .onFailure { Log.w(TAG, "догон журнала: ${it.message}") }
            }
        }
        Log.i(TAG, "мгновенный режим: опрос журнала раз в ${POLL_MS / 1000} с")
    }

    /**
     * Изменение в папках телефона: проход почти сразу. Выдержка нужна, чтобы всплеск событий
     * (браузер качает файл частями, распаковка архива) не запускал десяток проходов подряд.
     */
    fun onLocalChange() {
        if (paused() || !hasToken()) return
        if (!pendingLocal.compareAndSet(false, true)) return
        scope.launch {
            try {
                delay(LOCAL_DEBOUNCE_MS)
                // Полный обход диска стоит дорого, а события при распаковке или активной загрузке
                // идут потоком: держим паузу между проходами и ждём её, если событие пришло раньше.
                val sinceLast = System.currentTimeMillis() - lastLocalPassAt.get()
                if (sinceLast < MIN_LOCAL_PASS_GAP_MS) delay(MIN_LOCAL_PASS_GAP_MS - sinceLast)
                lastLocalPassAt.set(System.currentTimeMillis())
                runCatching { engine.pass(onProgress = { Log.i(TAG, "по событию: $it") }) }
                    .onFailure { Log.w(TAG, "проход по событию: ${it.message}") }
            } finally {
                pendingLocal.set(false)
            }
        }
    }

    private companion object {
        const val TAG = "cloudly-mirror"

        /**
         * Как часто спрашивать голову журнала. Запрос крошечный (одна строка по индексу),
         * лимит сервера на эту ручку — 240 в минуту, так что 20 в минуту не мешают.
         */
        const val POLL_MS = 3_000L

        /** В фоне: экран погашен, мгновенность не нужна, а батарея нужна. */
        const val POLL_BACKGROUND_MS = 30_000L

        /** Сервер молчит или сети нет: ждём дольше, но не бросаем опрос совсем. */
        const val FAIL_BACKOFF_MS = 60_000L

        /** Выдержка после изменения файла: даём дописаться и склеиваем всплеск событий. */
        const val LOCAL_DEBOUNCE_MS = 1_500L

        /** Минимальный промежуток между проходами по событиям: обход диска не бесплатный. */
        const val MIN_LOCAL_PASS_GAP_MS = 30_000L
    }
}
