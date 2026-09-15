package ru.cloudly.cloudly_flutter

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.atomic.AtomicBoolean

/**
 * На экране ли приложение.
 *
 * Нужно ровно для одного решения: делать ли проход из фона. Пока приложение видно, работает
 * мгновенный режим в его собственном движке — он замечает изменения за секунды. Проход,
 * запущенный параллельно из фонового изолята, не добавил бы ничего, зато полез бы в те же
 * базы вторым соединением: замок «один проход за раз» в движке живёт внутри своего изолята
 * и о соседе не знает.
 *
 * Считаем started-активности, а не «процесс жив»: приложение может быть выгружено в фон,
 * и тогда именно фоновое задание и остаётся единственным, кто ходит в облако. Перезагрузку
 * и убийство процесса флаг переживает неправильно (он живёт в памяти процесса), но и не
 * должен: новый процесс начинается без активностей, значит «на экране нет» — верно.
 */
object AppPresence {

    @Volatile
    var foreground: Boolean = false
        private set

    private val registered = AtomicBoolean(false)

    /** Активностей в состоянии started: их может быть больше одной (наши экраны в стеке). */
    private var started: Int = 0

    /** Ставится один раз, из главной активности: получатель событий живёт на приложении. */
    fun register(application: Application) {
        if (!registered.compareAndSet(false, true)) return
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityStarted(activity: Activity) {
                    started += 1
                    foreground = started > 0
                }

                override fun onActivityStopped(activity: Activity) {
                    started = (started - 1).coerceAtLeast(0)
                    foreground = started > 0
                }

                override fun onActivityCreated(activity: Activity, state: Bundle?) {}
                override fun onActivityResumed(activity: Activity) {}
                override fun onActivityPaused(activity: Activity) {}
                override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
                override fun onActivityDestroyed(activity: Activity) {}
            },
        )
    }
}
