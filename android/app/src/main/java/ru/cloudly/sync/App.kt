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
import ru.cloudly.sync.mirror.MirrorScheduler
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
        mirror = MirrorEngine(api, mirrorStore, selection)
        mirrorWatcher = MirrorWatcher { MirrorScheduler.scheduleSoon(this) }
        // периодический проход: наблюдатель за файлами только ускоряет, но не заменяет его
        MirrorScheduler.schedulePeriodic(this)
        runCatching { mirrorWatcher.watch(selection.paths(Section.FILES)) }
    }

    /** После изменения выбора папок наблюдение пересобирается: набор папок изменился. */
    fun refreshMirrorWatch() {
        runCatching { mirrorWatcher.watch(selection.paths(Section.FILES)) }
    }

    companion object {
        fun of(context: Context): App = context.applicationContext as App
    }
}
