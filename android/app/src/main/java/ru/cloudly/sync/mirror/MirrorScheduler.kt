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
 * Периодический проход — раз в 15 минут (меньше система не разрешает). События файловой системы
 * дают только быстрый путь: они теряются при перезапуске процесса, после перезагрузки и в Doze,
 * поэтому периодический проход обязателен, а наблюдатель — лишь ускоритель.
 */
object MirrorScheduler {

    /** Периодический проход: минимум, который разрешает система. */
    const val PERIODIC_JOB = 4201

    /** Проход «по событию»: один раз и почти сразу. */
    const val SOON_JOB = 4202

    /** Раз в 15 минут — нижняя граница `JobInfo`. */
    private const val PERIOD_MS = 15 * 60_000L

    /** Задержка после события: файл ещё дописывается, спешить некуда. */
    private const val SOON_DELAY_MS = 5_000L

    fun schedulePeriodic(context: Context) {
        val job = JobInfo.Builder(PERIODIC_JOB, component(context))
            .setPeriodic(PERIOD_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            // переживает перезагрузку: иначе зеркало молчало бы до первого запуска приложения
            .setPersisted(true)
            .build()
        runCatching { scheduler(context).schedule(job) }
    }

    /** Быстрый путь после изменения файлов: один проход в ближайшие секунды. */
    fun scheduleSoon(context: Context) {
        val job = JobInfo.Builder(SOON_JOB, component(context))
            .setMinimumLatency(SOON_DELAY_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .build()
        runCatching { scheduler(context).schedule(job) }
    }

    fun cancel(context: Context) {
        runCatching {
            scheduler(context).cancel(PERIODIC_JOB)
            scheduler(context).cancel(SOON_JOB)
        }
    }

    fun isScheduled(context: Context): Boolean =
        runCatching { scheduler(context).allPendingJobs.any { it.id == PERIODIC_JOB } }.getOrDefault(false)

    private fun scheduler(context: Context): JobScheduler = context.getSystemService(JobScheduler::class.java)

    private fun component(context: Context) = ComponentName(context, MirrorJobService::class.java)
}
