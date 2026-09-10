package ru.cloudly.sync.work

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.sync.Hasher
import java.io.File

/**
 * Недельная сверка: перепроверяем хэши части выгруженного и спрашиваем сервер, всё ли ещё у него есть.
 *
 * Зачем: диск и файловая система молча портят файлы, приложения правят их в обход, а объект на
 * сервере мог исчезнуть (сбой, ручная чистка бакета). Без такой сверки расхождение обнаружится
 * только тогда, когда файл понадобится.
 *
 * Проверяем порциями и по кругу (курсор в kv), поэтому большая библиотека перепроверяется
 * за несколько недель, а не одним тяжёлым проходом.
 */
class VerifyWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val app = App.of(applicationContext)
        if (!app.prefs.configured) return@withContext Result.success()
        val stats = verify(app)
        app.db.putKv("last_verify_at", System.currentTimeMillis().toString())
        app.db.putKv(
            "last_verify_stats",
            "проверено ${stats.checked}, изменилось ${stats.changed}, нет на сервере ${stats.missing}, ошибок ${stats.errors}",
        )
        if (stats.changed > 0 || stats.missing > 0) {
            Notifications.notifyProblems(
                applicationContext,
                "Сверка: изменилось ${stats.changed}, нет на сервере ${stats.missing}",
            )
        }
        Result.success()
    }

    data class Stats(var checked: Int = 0, var changed: Int = 0, var missing: Int = 0, var errors: Int = 0)

    companion object {
        const val PERIODIC = "cloudly-sync-verify"
        const val ONE_OFF = "cloudly-sync-verify-now"
        private const val BATCH = 100

        /** Сверка по всем задачам: хэш локальных файлов + наличие содержимого на сервере. */
        fun verify(app: App): Stats {
            val stats = Stats()
            val from = (app.db.kv(KV_VERIFY_CURSOR) ?: "0").toLongOrNull() ?: 0L
            var index = 0L
            for (job in app.db.jobs(enabledOnly = true)) {
                val items = app.db.itemsOf(job.id)
                for (item in items) {
                    if (index++ < from) continue
                    if (stats.checked >= BATCH) {
                        app.db.putKv(KV_VERIFY_CURSOR, index.toString())
                        return stats
                    }
                    if (item.state != Db.STATE_SYNCED) continue
                    val file = File(item.localPath)
                    if (!file.isFile) continue
                    stats.checked += 1
                    val sha = runCatching { Hasher.sha256(file) }.getOrNull()
                    if (sha == null) {
                        stats.errors += 1
                        continue
                    }
                    if (item.sha256 != null && sha != item.sha256) {
                        // файл изменился в обход синхронизации — вернём его в очередь на выгрузку
                        app.db.updateItem(
                            job.id,
                            item.relPath,
                            mapOf("sha256" to sha, "state" to Db.STATE_NEW, "local_size" to file.length(), "local_mtime" to file.lastModified()),
                        )
                        app.db.enqueueOp(job.id, item.relPath, Db.OP_UPLOAD)
                        stats.changed += 1
                    }
                }
            }
            app.db.putKv(KV_VERIFY_CURSOR, "0")
            // Спрашиваем сервер, что из выгруженного он всё ещё считает своим. Идём по кругу
            // порциями: иначе проверялись бы всегда одни и те же первые 500 хэшей.
            val tracked = app.db.jobs(enabledOnly = true).flatMap { job ->
                app.db.itemsOf(job.id)
                    .filter { it.state == Db.STATE_SYNCED && it.sha256 != null }
                    .map { job.id to it }
            }
            if (tracked.isNotEmpty()) {
                val from = (app.db.kv(KV_REMOTE_CURSOR) ?: "0").toIntOrNull() ?: 0
                val slice = ArrayList<Pair<Long, Db.Item>>(500)
                var i = from
                while (slice.size < 500 && i < tracked.size) {
                    slice.add(tracked[i])
                    i += 1
                }
                app.db.putKv(KV_REMOTE_CURSOR, (if (i >= tracked.size) 0 else i).toString())
                val shas = slice.mapNotNull { it.second.sha256 }.distinct()
                val present = runCatching { app.api.have(shas) }.getOrElse {
                    stats.errors += 1
                    emptySet()
                }
                for ((jobId, item) in slice) {
                    val sha = item.sha256 ?: continue
                    if (sha in present) continue
                    stats.missing += 1
                    // содержимого на сервере больше нет — вернём файл в очередь на выгрузку
                    app.db.updateItem(jobId, item.relPath, mapOf("state" to Db.STATE_NEW, "remote_sha256" to null))
                    app.db.enqueueOp(jobId, item.relPath, Db.OP_UPLOAD)
                }
            }
            return stats
        }

        private const val KV_VERIFY_CURSOR = "verify_cursor"
        private const val KV_REMOTE_CURSOR = "verify_remote_cursor"
    }
}
