package ru.cloudly.sync.work

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import ru.cloudly.sync.App
import ru.cloudly.sync.R
import ru.cloudly.sync.ui.MainActivity

/**
 * Уведомления о проблемах фоновых проходов. Молчаливая синхронизация — плохая: пользователь
 * должен узнать, что что-то не уехало, не открывая приложение и не читая логи.
 * Одно постоянное уведомление на все проблемы (id фиксированный), чтобы не спамить.
 */
object Notifications {
    private const val PROBLEMS_ID = 43

    fun notifyProblems(context: Context, text: String) {
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, App.CHANNEL_PROBLEMS)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("CloudlyRu: нужна проверка")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(PROBLEMS_ID, notification) }
    }

    fun clearProblems(context: Context) {
        runCatching { NotificationManagerCompat.from(context).cancel(PROBLEMS_ID) }
    }
}
