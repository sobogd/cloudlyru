package ru.cloudly.cloudly_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Возврат задания к жизни после перезагрузки и после обновления приложения.
 *
 * Само задание переживает перезагрузку (`setPersisted`), но система возвращает такие задания
 * только после того, как приложение запускали: пока владелец не откроет приложение, зеркало
 * молчало бы. Поэтому задание заводится заново — тем же кодом, что и при входе в аккаунт.
 *
 * Если задание снято (вышли из аккаунта), не заводим: признак лежит в настройках, его пишет
 * Dart при входе и выходе.
 */
class SyncBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        if (!BackgroundSettings.enabled(context)) {
            Log.i(TAG, "фоновая сверка не заведена: после $action ничего не возвращаю")
            return
        }
        SyncJobScheduler.schedule(context)
        Log.i(TAG, "фоновая сверка заведена после $action")
    }

    private companion object {
        const val TAG = "cloudly-sync"
    }
}
