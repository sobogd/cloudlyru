package ru.cloudly.sync.mirror

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context

/**
 * Страховочный проход, когда процесса приложения нет.
 *
 * Основной путь — мгновенный режим (`MirrorLive`) вместе с постоянным сервисом
 * (`MirrorService`): пока сервис держит процесс, изменения уезжают за пару секунд.
 * Здесь — то, что остаётся, если сервис выключен или система его всё-таки прибила:
 * периодическое задание системы.
 *
 * Период — ровно пятнадцать минут, потому что меньше `JobScheduler` не разрешает: это
 * ограничение записано в самом `JobInfo`, и обойти его внутри задания нельзя. Разбудить
 * приложение чаще можно только сервисом с постоянным уведомлением — он и есть основной путь.
 */
object MirrorScheduler {

    /** Периодический проход: нижняя граница, которую разрешает система. */
    const val PERIODIC_JOB = 4201

    /** Период `JobInfo` — ровно минимум системы, меньше она всё равно не даст. */
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
        runCatching { scheduler(context).cancel(PERIODIC_JOB) }
    }

    fun isScheduled(context: Context): Boolean =
        runCatching { scheduler(context).allPendingJobs.any { it.id == PERIODIC_JOB } }.getOrDefault(false)

    private fun scheduler(context: Context): JobScheduler = context.getSystemService(JobScheduler::class.java)

    private fun component(context: Context) = ComponentName(context, MirrorJobService::class.java)
}
