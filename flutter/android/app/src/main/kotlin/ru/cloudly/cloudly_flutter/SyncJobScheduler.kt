package ru.cloudly.cloudly_flutter

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context

/**
 * Периодический проход зеркала: задание системы, как в нативном клиенте (`MirrorScheduler`).
 *
 * Задание, а не таймер в приложении: к моменту прохода движка приложения может уже не быть
 * вовсе — система поднимет процесс и запустит нашу службу. Период — ровно пятнадцать минут,
 * потому что меньше `JobScheduler` не разрешает: это ограничение записано в самом `JobInfo`,
 * и обойти его внутри задания нельзя.
 *
 * `setPersisted` — задание переживает перезагрузку. Одного этого мало (система возвращает
 * сохранённые задания только после того, как приложение хоть раз запускали), поэтому рядом
 * стоит получатель перезагрузки: он заводит задание заново.
 */
object SyncJobScheduler {

    /** Номер задания. Тот же, что был у нативного клиента, — чтобы не плодить дубли при обновлении. */
    const val JOB_ID = 4201

    private const val PERIOD_MS = 15 * 60_000L

    fun schedule(context: Context) {
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, SyncJobService::class.java))
            .setPeriodic(PERIOD_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .build()
        // Система может отказать (лимит заданий, запрет на persisted): это не повод падать —
        // останется мгновенный режим в приложении, как и до появления задания
        runCatching { scheduler(context).schedule(job) }
    }

    fun cancel(context: Context) {
        runCatching { scheduler(context).cancel(JOB_ID) }
    }

    fun isScheduled(context: Context): Boolean =
        runCatching { scheduler(context).allPendingJobs.any { it.id == JOB_ID } }.getOrDefault(false)

    private fun scheduler(context: Context): JobScheduler =
        context.getSystemService(JobScheduler::class.java)
}
