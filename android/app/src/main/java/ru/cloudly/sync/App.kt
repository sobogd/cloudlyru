package ru.cloudly.sync

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.data.Prefs
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.sync.UploadEngine
import ru.cloudly.sync.work.SyncWorker
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Ручная сборка зависимостей без DI-фреймворка: приложение маленькое, а лишний кодогенератор
 * в сборке — лишние версии, которые надо синхронизировать.
 */
class App : Application() {
    lateinit var prefs: Prefs
        private set
    lateinit var db: Db
        private set
    lateinit var api: Api
        private set

    /** Движок создаётся по требованию: он лёгкий, но держать его в Application незачем. */
    fun engine(): UploadEngine = UploadEngine(this, db, api)

    /**
     * Один проход синхронизации за раз. Периодическая задача WorkManager и «Синхронизировать
     * сейчас» — разные исполнители: без этого лока два движка одновременно заливали бы одни
     * и те же файлы и качали в один временный файл, портя содержимое.
     */
    fun tryEnterSync(): Boolean = syncRunning.compareAndSet(false, true)

    fun leaveSync() {
        syncRunning.set(false)
    }

    private val syncRunning = AtomicBoolean(false)

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        db = Db(this)
        api = Api(prefs)
        createChannels()
        schedulePeriodic()
    }

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SYNC, getString(R.string.channel_sync), NotificationManager.IMPORTANCE_LOW)
                .apply { description = getString(R.string.channel_sync_desc) },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_PROBLEMS, getString(R.string.channel_problems), NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = getString(R.string.channel_problems_desc) },
        )
    }

    /**
     * Фон держится на WorkManager: короткий dataSync-сервис система ограничивает 6 часами
     * за сутки, а периодическая задача живёт и после перезагрузки телефона.
     */
    private fun schedulePeriodic() {
        val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(this)
            .enqueueUniquePeriodicWork(SyncWorker.PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    companion object {
        const val CHANNEL_SYNC = "sync"
        const val CHANNEL_PROBLEMS = "problems"
        fun of(context: Context): App = context.applicationContext as App
    }
}
