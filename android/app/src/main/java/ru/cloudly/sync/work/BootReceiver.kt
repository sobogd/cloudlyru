package ru.cloudly.sync.work

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * После перезагрузки телефона сервис нужно поднять заново: система его не восстанавливает
 * сама, а без него телефон перестаёт отвечать вебу и наполнять очередь.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            runCatching { SyncService.start(context) }
        }
    }
}
