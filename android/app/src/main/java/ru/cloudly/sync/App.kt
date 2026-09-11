package ru.cloudly.sync

import android.app.Application
import android.content.Context
import ru.cloudly.sync.data.Prefs
import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.net.Api

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

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        api = Api(prefs)
        selection = Selection(this)
        queueStore = QueueStore(this)
    }

    companion object {
        fun of(context: Context): App = context.applicationContext as App
    }
}
