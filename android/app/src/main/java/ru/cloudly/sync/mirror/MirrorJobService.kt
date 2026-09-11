package ru.cloudly.sync.mirror

import android.app.job.JobParameters
import android.app.job.JobService
import android.util.Log
import ru.cloudly.sync.App
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Проход зеркала по требованию системы: периодически и по событию файловой системы.
 *
 * Работа идёт в отдельном потоке, `jobFinished` вызывается всегда — иначе система держала бы
 * задание вечно. Если система останавливает задание (появились другие дела поважнее), проход
 * прерывается на середине: недоделанное доедет следующим — сверка идемпотентна.
 *
 * Отдельного foreground-сервиса нет намеренно: запуск уведомления из фона на Android 12+
 * ограничен, а проход и так ограничен по времени (бюджет в движке меньше лимита задания).
 */
class MirrorJobService : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        if (!running.compareAndSet(false, true)) {
            // проход уже идёт: второй не нужен, сверка всё равно увидит то же состояние
            return false
        }
        cancelled.set(false)
        val app = App.of(this)
        if (app.mirrorStore.meta(MirrorStore.KEY_PAUSED) == "1") {
            // автоматика выключена пользователем: ручная сверка при этом работает
            running.set(false)
            return false
        }
        Thread {
            try {
                val report = app.mirror.pass(isCancelled = { cancelled.get() })
                Log.i(TAG, "проход зеркала: ${report.text()}")
            } catch (e: Exception) {
                Log.w(TAG, "проход зеркала упал: ${e.message}")
            } finally {
                running.set(false)
                jobFinished(params, false)
            }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        cancelled.set(true)
        // вернуть true: систему просят повторить задание — проход не закончен
        return true
    }

    companion object {
        private const val TAG = "cloudly-mirror"

        private val running = AtomicBoolean(false)
        private val cancelled = AtomicBoolean(false)
    }
}
