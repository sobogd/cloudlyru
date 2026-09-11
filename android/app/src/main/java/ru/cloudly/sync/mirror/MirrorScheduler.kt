package ru.cloudly.sync.mirror

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context

/**
 * Когда зеркало работает.
 *
 * Системный `JobScheduler`, а не ручной таймер и не WorkManager: он один умеет будить приложение
 * после перезагрузки, ждать появления сети и не тратить батарею, и при этом не тянет в сборку
 * новую зависимость ради одной задачи.
 *
 * Это страховка, а не основной путь: мгновенную реакцию даёт `MirrorLive`, пока жив процесс
 * приложения. Здесь — редкий проход на случай, когда процесса нет: целиком выгружен из памяти,
 * телефон перезагружали, система прибила приложение ради памяти. Меньше 15 минут система
 * не разрешает, и разбудить приложение чаще без постоянного уведомления всё равно нельзя.
 */
object MirrorScheduler {

    /** Периодический проход: минимум, который разрешает система. */
    const val PERIODIC_JOB = 4201

    /** Раз в 15 минут — нижняя граница `JobInfo`. */
    private const val PERIOD_MS = 15 * 60_000L

    fun schedulePeriodic(context: Context) {
        val job = JobInfo.Builder(PERIODIC_JOB, component(context))
            .setPeriodic(PERIOD_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            // переживает перезагрузку: иначе зеркало молчало бы до первого запуска приложения
            .setPersisted(true)
            .build()
        runCatching { scheduler(context).schedule(job) }
    }

    fun cancel(context: Context) {
        runCatching {
            scheduler(context).cancel(PERIODIC_JOB)
        }
    }

    fun isScheduled(context: Context): Boolean =
        runCatching { scheduler(context).allPendingJobs.any { it.id == PERIODIC_JOB } }.getOrDefault(false)

    private fun scheduler(context: Context): JobScheduler = context.getSystemService(JobScheduler::class.java)

    private fun component(context: Context) = ComponentName(context, MirrorJobService::class.java)
}
