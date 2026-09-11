package ru.cloudly.sync.mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import ru.cloudly.sync.App
import ru.cloudly.sync.R
import ru.cloudly.sync.ui.MainActivity

/**
 * Постоянный сервис зеркала: пока он работает, процесс приложения жив, а значит живы и
 * мгновенный режим (`MirrorLive` — опрос журнала раз в 3 секунды), и наблюдение за папками.
 *
 * Почему сервис, а не задания: Android не даёт будить приложение чаще, чем раз в 15 минут
 * (ограничение самого `JobScheduler`), и не разрешает долгоживущий фоновый процесс без
 * видимого уведомления. Уведомление — это и есть цена мгновенности, и она выбрана осознанно.
 *
 * Сервис ничего не считает сам: он держит процесс и показывает состояние. Работу делает
 * мгновенный режим в области приложения.
 */
class MirrorService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // «Выключить» в уведомлении должно выключать режим целиком, а не только сервис:
            // иначе переключатель врал бы, а сервис поднимался бы снова при следующем запуске
            Log.i(TAG, "мгновенный режим выключен пользователем")
            setEnabled(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        // Тип сервиса обязателен с Android 14: без него система не примет foreground-сервис.
        // Запуск из фона на новых версиях Android может быть запрещён — тогда сервис просто
        // не поднимается, а не роняет приложение: мгновенный режим останется только пока
        // приложение открыто, а страховочный проход продолжит работать заданием.
        val started = runCatching {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else {
                    0
                },
            )
        }.onFailure { Log.w(TAG, "foreground не разрешён системой: ${it.message}") }
        if (started.isFailure) {
            stopSelf()
            return START_NOT_STICKY
        }
        // набор папок мог измениться, пока сервис не работал
        runCatching { App.of(this).refreshMirrorWatch() }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "сервис остановлен системой")
        super.onDestroy()
    }

    /**
     * Android 15 ограничивает суммарное время работы сервиса типа `dataSync` за сутки.
     * Когда лимит исчерпан, система требует остановиться: выключаем режим честно, чтобы
     * переключатель не врал и владелец понимал, почему мгновенности больше нет.
     */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "система остановила сервис по лимиту времени — выключаю мгновенный режим")
        setEnabled(this, false)
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        onTimeout(startId)
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, MirrorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Зеркало работает: изменения уезжают сразу")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(0, "Выключить", stop)
            .build()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Зеркало папок",
            // низкая важность: уведомление висит, но не пищит и не всплывает
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Постоянное уведомление мгновенного режима зеркала"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_STOP = "ru.cloudly.sync.mirror.STOP"

        private const val TAG = "cloudly-mirror"
        private const val CHANNEL_ID = "cloudly-mirror-live"
        private const val NOTIFICATION_ID = 4210

        /** Запуск сервиса: из интерфейса или после перезагрузки. */
        fun start(context: Context) {
            val intent = Intent(context, MirrorService::class.java)
            runCatching { context.startForegroundService(intent) }
                .onFailure { Log.w(TAG, "сервис не запустился: ${it.message}") }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, MirrorService::class.java)) }
        }

        /**
         * База зеркала одна на приложение. Открывать её заново на каждый вызов нельзя:
         * каждое открытие — лишнее соединение, которое никто не закрывает.
         */
        private fun store(context: Context): MirrorStore = App.of(context).mirrorStore

        /** Включён ли мгновенный режим по выбору пользователя. */
        fun isEnabled(context: Context): Boolean = store(context).meta(MirrorStore.KEY_LIVE) == "1"

        /** Включить/выключить режим и запустить или остановить сервис. */
        fun setEnabled(context: Context, enabled: Boolean) {
            val store = store(context)
            if (enabled) {
                store.setMeta(MirrorStore.KEY_LIVE, "1")
                start(context)
            } else {
                store.clearMeta(MirrorStore.KEY_LIVE)
                stop(context)
            }
        }
    }
}
