package ru.cloudly.sync.mirror

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Возврат зеркала к жизни после перезагрузки и после обновления приложения.
 *
 * Ни задания, ни сервис перезагрузку не переживают (задание переживает только если помечено
 * `setPersisted`, и всё равно требует, чтобы приложение хоть раз запустили) — поэтому здесь
 * они ставятся и запускаются заново. Если система откажет в запуске сервиса из получателя
 * (такое ограничение есть на новых версиях Android), останется периодическое задание:
 * значит зеркало вернётся к редкому проходу, а не сломается.
 */
class MirrorBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val store = MirrorStore(context)
        if (store.meta(MirrorStore.KEY_PAUSED) == "1") return
        MirrorScheduler.schedulePeriodic(context)
        if (MirrorService.isEnabled(context)) {
            runCatching { MirrorService.start(context) }
                .onFailure { Log.w(TAG, "после $action сервис не поднялся: ${it.message}") }
        }
    }

    private companion object {
        const val TAG = "cloudly-mirror"
    }
}
