package ru.cloudly.sync

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import ru.cloudly.sync.data.Prefs
import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.data.Selection
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
     * Выгрузка живёт в области приложения, а не экрана: ушёл с раздела «Очередь» —
     * файл всё равно доедет. Запуск при этом ручной, по кнопке на строке.
     */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Что нашёл последний проход по папкам. Снимок для сервера собирается из этого, а не из
     * нового обхода диска: иначе каждое обновление состояния стоило бы полного сканирования,
     * и статусы в вебе отставали бы на минуты.
     */
    @Volatile
    var lastCandidates: List<ru.cloudly.sync.queue.Candidate> = emptyList()

    /** Скелет папок последнего прохода: раздел, относительный путь, имя. */
    @Volatile
    var lastDirs: List<Triple<String, String, String>> = emptyList()

    /** Когда проход был: по этому снимок понимает, можно ли ему доверять. */
    @Volatile
    var lastScanAt: Long = 0L
    lateinit var uploads: UploadRunner
        private set

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        api = Api(prefs)
        selection = Selection(this)
        queueStore = QueueStore(this)
        uploads = UploadRunner(api, queueStore, appScope)
    }

    companion object {
        fun of(context: Context): App = context.applicationContext as App
    }
}
