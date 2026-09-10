package ru.cloudly.sync.work

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App

/**
 * Фоновый проход. Именно WorkManager, а не постоянный foreground-сервис: на Android 15
 * сервис типа dataSync ограничен шестью часами за сутки, и вечное уведомление не нужно —
 * периодическая задача и событийные запуски дают тот же эффект без борьбы с системой.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val app = App.of(applicationContext)
        if (!app.prefs.configured) return Result.success()
        if (!app.tryEnterSync()) return Result.success() // проход уже идёт
        // сеть и диск — на IO: воркер по умолчанию крутится на Dispatchers.Default
        val stats = withContext(Dispatchers.IO) {
            try {
                app.engine().syncAll()
            } finally {
                app.leaveSync()
            }
        }
        app.db.kv("auth_error")?.let { Notifications.notifyProblems(applicationContext, "нет доступа: $it") }
        app.db.putKv("last_run_at", System.currentTimeMillis().toString())
        app.db.putKv(
            "last_run_stats",
            "загружено ${stats.uploaded}, дедуп ${stats.deduped}, пропущено ${stats.skipped}, " +
                "удалено ${stats.deleted}, конфликтов ${stats.conflicts}, ошибок ${stats.errors}",
        )
        stats.fatal?.let { app.db.putKv("last_run_error", it) }
        // молчаливая синхронизация — плохая: об ошибках и конфликтах сообщаем уведомлением
        val problems = stats.errors + stats.conflicts
        if (stats.fatal != null || problems > 0) {
            val detail = buildString {
                append("ошибок ${stats.errors}, конфликтов ${stats.conflicts}")
                stats.fatal?.let { append("; $it") }
                val first = app.db.failedOps().firstOrNull()
                first?.let { append("; например: ${it.relPath} — ${it.lastError}") }
            }
            Notifications.notifyProblems(applicationContext, detail)
        } else {
            Notifications.clearProblems(applicationContext)
        }
        return if (stats.fatal != null) Result.retry() else Result.success()
    }

    companion object {
        const val PERIODIC = "cloudly-sync-periodic"
        const val ONE_OFF = "cloudly-sync-now"
    }
}
