package ru.cloudly.sync.work

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.R
import ru.cloudly.sync.queue.ChangeApplier
import ru.cloudly.sync.queue.QueueRefresher
import ru.cloudly.sync.ui.MainActivity

/**
 * Вечный сервис синхронизации: пока он жив, телефон сам сообщает серверу своё состояние,
 * забирает команды веба и выполняет их, а в уведомлении видно, что происходит.
 *
 * Почему сервис, а не периодические задачи: Android душит фоновую периодику (минимум 15 минут
 * у WorkManager), а «новый файл — сразу в очередь» и «кнопка в вебе — сразу на телефоне» так
 * не работают. Соединение наружу телефону нужно в любом случае: своего адреса у него нет.
 *
 * Команды забираются коротким опросом — протокол тот же, что был бы у вебсокета, поэтому
 * транспорт можно поменять, ничего не переделывая в модели команд.
 */
class SyncService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var started = false
    private var lastText = ""

    /** Что-то изменилось в медиатеке — значит и на диске: пересоберём очередь. */
    @Volatile
    private var dirty = true

    private var observer: ContentObserver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        registerMediaObserver()
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification("запускаюсь…"))
        if (!started) {
            started = true
            scope.launch { loop() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        observer?.let { runCatching { contentResolver.unregisterContentObserver(it) } }
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun loop() {
        val app = App.of(this)
        var lastScan = 0L
        var lastReport = 0L
        var lastApply = 0L
        var needReport = true

        while (scope.isActive) {
            try {
                if (app.prefs.token.isBlank()) {
                    updateNotification("нет входа в аккаунт — откройте «Настройки»")
                    delay(IDLE_TICK)
                    continue
                }
                ensureDevice(app)
                if (app.prefs.deviceId.isBlank()) {
                    delay(IDLE_TICK)
                    continue
                }

                // 1. команды веба
                val commands = app.api.deviceCommands(app.prefs.deviceId)
                for (command in commands) {
                    val error = execute(app, command.kind, command.payload)
                    runCatching { app.api.deviceAck(app.prefs.deviceId, command.id, error) }
                    if (error == null) needReport = true
                }

                // 2. проход по папкам: по сигналу «что-то появилось» или по расписанию
                val now = System.currentTimeMillis()
                if (dirty || now - lastScan > SCAN_PERIOD_MS) {
                    dirty = false
                    lastScan = now
                    QueueRefresher.refresh(this)
                    needReport = true
                }

                // 3. изменения облака: переименования и новые версии доезжают до телефона
                if (now - lastApply > APPLY_PERIOD_MS) {
                    lastApply = now
                    val applied = ChangeApplier(this, app.api, app.queueStore).apply()
                    if (applied.applied > 0) {
                        needReport = true
                        Log.i(TAG, applied.text())
                    }
                }

                // 4. снимок состояния для веба
                if (needReport || now - lastReport > REPORT_PERIOD_MS) {
                    val entries = SyncState.build(this)
                    val after = app.api.deviceState(app.prefs.deviceId, entries)
                    for (command in after) {
                        val error = execute(app, command.kind, command.payload)
                        runCatching { app.api.deviceAck(app.prefs.deviceId, command.id, error) }
                    }
                    lastReport = System.currentTimeMillis()
                    needReport = false
                }

                updateNotification(statusText(app))
            } catch (e: Exception) {
                Log.w(TAG, "цикл сервиса: ${e.message}")
                updateNotification("нет связи с сервером: ${e.message?.take(60) ?: "ошибка"}")
            }
            delay(TICK_MS)
        }
    }

    /** Телефон представляется серверу один раз: id устройства живёт в настройках. */
    private suspend fun ensureDevice(app: App) {
        if (app.prefs.deviceId.isNotBlank()) return
        val (deviceId, _) = withContext(Dispatchers.IO) {
            app.api.deviceHello("android-${Build.MODEL}")
        }
        if (deviceId.isNotBlank()) {
            app.prefs.deviceId = deviceId
            Log.i(TAG, "представился серверу: $deviceId")
        }
    }

    /** Выполнить команду веба. Возвращает текст ошибки или null, если всё прошло. */
    private suspend fun execute(app: App, kind: String, payload: org.json.JSONObject?): String? = try {
        when (kind) {
            "SYNC_NOW" -> {
                QueueRefresher.refresh(this)
                null
            }
            "PAUSE" -> {
                app.uploads.pause()
                updateNotification("пауза: ${SyncState.summary(this)}")
                null
            }
            "RESUME" -> {
                app.uploads.resume()
                null
            }
            "UPLOAD_PATH" -> {
                val path = payload?.optString("path").orEmpty()
                if (path.isBlank()) {
                    "не указан путь"
                } else {
                    var item = withContext(Dispatchers.IO) { app.queueStore.itemByPath(path) }
                    if (item == null) {
                        // файл мог появиться только что: обновим очередь и поищем снова
                        QueueRefresher.refresh(this)
                        item = withContext(Dispatchers.IO) { app.queueStore.itemByPath(path) }
                    }
                    if (item == null) {
                        "в очереди нет файла $path"
                    } else {
                        app.uploads.resume()
                        app.uploads.start(item.id)
                        null
                    }
                }
            }
            "APPLY_CHANGES" -> {
                val result = ChangeApplier(this, app.api, app.queueStore).apply()
                updateNotification(result.text())
                if (result.problem == null) null else result.problem
            }
            else -> "неизвестная команда: $kind"
        }
    } catch (e: Exception) {
        Log.w(TAG, "команда $kind: ${e.message}")
        e.message ?: "ошибка выполнения"
    }

    private fun statusText(app: App): String {
        if (app.uploads.isPaused()) return "пауза · ${SyncState.summary(this)}"
        val progress = app.uploads.progress.value
        return if (progress != null) {
            "выгрузка: ${progress.name} — ${progress.percent}%"
        } else {
            SyncState.summary(this)
        }
    }

    private fun updateNotification(text: String) {
        if (text == lastText) return
        lastText = text
        runCatching {
            (getSystemService(NotificationManager::class.java)).notify(NOTIFICATION_ID, notification(text))
        }
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Cloudly — синхронизация")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Синхронизация", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Состояние очереди и выгрузки" },
        )
    }

    /**
     * Медиатека меняется, когда на телефоне появляется или правится файл. Это дешёвый сигнал
     * «пора пройти папки»: держать наблюдателей на каждом каталоге дороже и ненадёжнее.
     */
    private fun registerMediaObserver() {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                dirty = true
            }
        }
        runCatching {
            contentResolver.registerContentObserver(MediaStore.Files.getContentUri("external"), true, observer)
            this.observer = observer
        }
    }

    companion object {
        private const val TAG = "cloudly-sync"
        private const val CHANNEL_ID = "sync-status"
        private const val NOTIFICATION_ID = 1
        private const val TICK_MS = 5_000L
        private const val IDLE_TICK = 30_000L
        private const val SCAN_PERIOD_MS = 3 * 60_000L
        private const val REPORT_PERIOD_MS = 60_000L

        /** Как часто телефон приглядывается к журналу изменений облака. */
        private const val APPLY_PERIOD_MS = 60_000L

        @Volatile
        var running = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, SyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SyncService::class.java))
        }
    }
}
