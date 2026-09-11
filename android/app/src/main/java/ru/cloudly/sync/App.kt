package ru.cloudly.sync

import android.app.Application
import android.content.Context
import ru.cloudly.sync.data.Prefs
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

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        api = Api(prefs)
    }

    companion object {
        fun of(context: Context): App = context.applicationContext as App
    }
}
