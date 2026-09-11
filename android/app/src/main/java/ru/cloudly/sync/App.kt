package ru.cloudly.sync

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import ru.cloudly.sync.data.Prefs
import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.mirror.MirrorEngine
import ru.cloudly.sync.mirror.MirrorLive
import ru.cloudly.sync.mirror.MirrorScheduler
import ru.cloudly.sync.mirror.MirrorService
import ru.cloudly.sync.mirror.MirrorStatus
import ru.cloudly.sync.mirror.MirrorStatusHolder
import ru.cloudly.sync.mirror.MirrorStore
import ru.cloudly.sync.mirror.MirrorWatcher
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.queue.UploadRunner

/**
 * Ручная сборка зависимостей без DI-фреймворка: приложение маленькое, а лишний кодогенератор
 * в сборке — лишние версии, которые надо синхронизировать.
 */
class App : Application() {
    lateinit var prefs: Prefs
        private set
    lateinit var api: Api
        private set

    /** Выбранные папки разделов и очередь загрузки — общее состояние интерфейса и сервиса. */
    lateinit var selection: Selection
        private set
    lateinit var queueStore: QueueStore
        private set

    /**
     * Двустороннее зеркало выбранных папок раздела «Файлы»: состояние живёт в области
     * приложения, потому что проходы запускает и система (периодическое задание), и интерфейс.
     */
    lateinit var mirrorStore: MirrorStore
        private set
    lateinit var mirror: MirrorEngine
        private set

    /** Прогресс зеркала: одна точка для интерфейса (раздел «Файлы» и настройки). */
    val mirrorStatus = MirrorStatusHolder()

    /**
     * Приложение на экране. Нужно живому режиму: на переднем плане журнал спрашивается
     * каждые 3 секунды, в фоне — раз в 30, иначе радио не даёт устройству спать.
     */
    val isForeground = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Мгновенный режим: опрос журнала облака и реакция на изменения файлов, пока жив процесс
     * приложения. Резидентного сервиса нет — когда система выгрузит процесс, останется
     * страховочный периодический проход.
     */
    lateinit var mirrorLive: MirrorLive
        private set

    /** Быстрый путь: изменение файла — повод не ждать пятнадцати минут. */
    lateinit var mirrorWatcher: MirrorWatcher
        private set

    /**
     * Выгрузка живёт в области приложения, а не экрана: ушёл с раздела «Очередь» —
     * файл всё равно доедет. Запуск при этом ручной, по кнопке на строке.
     */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    lateinit var uploads: UploadRunner
        private set

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        api = Api(prefs)
        selection = Selection(this)
        queueStore = QueueStore(this)
        // после перезапуска в очереди не может быть «в работе»: снимаем зависшие строки,
        // иначе строка навсегда осталась бы в состоянии «грузится»
        runCatching { queueStore.resetRunning() }
        uploads = UploadRunner(api, queueStore, appScope)

        mirrorStore = MirrorStore(this)
        mirror = MirrorEngine(api, mirrorStore, selection, mirrorStatus)
        mirrorLive = MirrorLive(
            api = api,
            store = mirrorStore,
            engine = mirror,
            status = mirrorStatus,
            scope = appScope,
            hasToken = { prefs.token.isNotBlank() },
            paused = { mirrorStore.meta(MirrorStore.KEY_PAUSED) == "1" },
            foreground = { isForeground.get() },
        )
        seedMirrorStatus()
        mirrorWatcher = MirrorWatcher { mirrorLive.onLocalChange() }
        // периодический проход: наблюдатель за файлами только ускоряет, но не заменяет его —
        // после выгрузки процесса наблюдать некому
        MirrorScheduler.schedulePeriodic(this)
        // мгновенный режим: постоянный сервис держит процесс живым, пока приложение выгружено
        if (MirrorService.isEnabled(this)) MirrorService.start(this)
        runCatching { mirrorWatcher.watch(selection.paths(Section.FILES)) }
        mirrorLive.start()
    }

    /**
     * Заполнить состояние зеркала из базы при старте. Без этого после каждого перезапуска
     * карточка показывала «в облаке: 0 файлов», хотя всё выгружено — база-то помнит.
     */
    private fun seedMirrorStatus() {
        val inCloud = runCatching { mirrorStore.inCloud() }.getOrNull() ?: return
        val local = mirrorStore.localTotals()
        val waiting = mirrorStore.waitingTotals()
        val blockedMeta = mirrorStore.meta(MirrorStore.KEY_BLOCKED)
        val blocked = blockedMeta?.substringBefore('|')?.toIntOrNull() ?: 0
        val blockedReason = blockedMeta?.substringAfter('|', "")?.takeIf { it.isNotBlank() }
        val phase = if (mirrorStore.meta(MirrorStore.KEY_PAUSED) == "1") {
            MirrorStatus.Phase.PAUSED
        } else {
            MirrorStatus.Phase.IDLE
        }
        mirrorStatus.update {
            copy(
                phase = phase,
                inCloudFiles = inCloud.files,
                inCloudBytes = inCloud.bytes,
                localFiles = local.files,
                localBytes = local.bytes,
                waitingFiles = waiting.files,
                waitingBytes = waiting.bytes,
                blocked = blocked,
                blockedReason = blockedReason,
                lastText = mirrorStore.meta(MirrorStore.KEY_REPORT).orEmpty(),
            )
        }
    }

    /** После изменения выбора папок наблюдение пересобирается: набор папок изменился. */
    fun refreshMirrorWatch() {
        runCatching { mirrorWatcher.watch(selection.paths(Section.FILES)) }
    }

    companion object {
        fun of(context: Context): App = context.applicationContext as App
    }
}
