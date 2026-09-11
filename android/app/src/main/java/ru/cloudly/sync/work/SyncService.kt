package ru.cloudly.sync.work

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import ru.cloudly.sync.App
import ru.cloudly.sync.R
import ru.cloudly.sync.ui.MainActivity

/**
 * Короткоживущий dataSync-сервис на время активной передачи: пользователь видит прогресс
 * и может остановить, а система знает, чем занята батарея. Android 15 даёт такому сервису
 * шесть часов за сутки, поэтому он включается только на «синхронизировать сейчас»,
 * а фоновый режим живёт на WorkManager.
 */
class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            job?.cancel()
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat(getString(R.string.app_name))
        if (job?.isActive == true) return START_NOT_STICKY
        val app = App.of(this)
        if (!app.tryEnterSync()) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        job = scope.launch {
            try {
                val stats = app.engine().syncAll { line -> notifyProgress(line) }
                app.db.putKv("last_run_at", System.currentTimeMillis().toString())
                app.db.putKv("last_run_stats", stats.text())
                stats.fatal?.let { app.db.putKv("last_run_error", it) }
            } finally {
                app.leaveSync()
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15 ограничивает такие сервисы шестью часами за сутки и вызывает onTimeout:
     * не остановиться самим — значит получить ANR. Продолжим следующим проходом WorkManager.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w("cloudly-sync", "лимит foreground-сервиса исчерпан — останавливаюсь")
        job?.cancel()
        App.of(this).leaveSync()
        stopForegroundCompat()
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundCompat(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun notifyProgress(text: String) {
        val notification = buildNotification(text)
        runCatching { NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification) }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, SyncService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, App.CHANNEL_SYNC)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Стоп", stop)
            .build()
    }

    companion object {
        private const val NOTIFICATION_ID = 42
        const val ACTION_STOP = "ru.cloudly.sync.STOP"

        fun start(context: Context) {
            val intent = Intent(context, SyncService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, SyncService::class.java).setAction(ACTION_STOP))
        }
    }
}
