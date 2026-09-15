package ru.cloudly.cloudly_flutter

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Канал фонового прохода (`ru.cloudly.sync/background`).
 *
 * Одним каналом пользуются обе стороны: из приложения по нему заводят и снимают задание,
 * а из фонового изолята спрашивают, не на экране ли приложение, сообщают об итоге и
 * принимают просьбу остановиться.
 *
 * Канал ставится дважды и это правильно: свой экземпляр — на движке приложения (главная
 * активность), свой — на движке фонового задания. У каждого движка свой мессенджер.
 */
class BackgroundBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    /** Служба подписана на итог: по нему она закрывает движок и докладывает системе. */
    var onFinished: ((Boolean, String?) -> Unit)? = null

    /**
     * Остановку просили. Событие на той стороне могло не застать слушателя (изолят только
     * поднимается), поэтому просьба лежит ещё и флагом — его Dart спрашивает сам.
     */
    @Volatile
    var stopRequested: Boolean = false
        private set

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "finished" -> {
                val ok = call.argument<Boolean>("ok") ?: false
                val note = call.argument<String>("note")
                result.success(true)
                onFinished?.invoke(ok, note)
            }

            "appInForeground" -> result.success(AppPresence.foreground)

            "stopRequested" -> result.success(stopRequested)

            // Задание заводится и снимается из приложения: жить оно должно в системе,
            // а не в движке, который к моменту запуска может быть уже закрыт
            "ensureJob" -> {
                SyncJobScheduler.schedule(context)
                result.success(SyncJobScheduler.isScheduled(context))
            }

            "cancelJob" -> {
                SyncJobScheduler.cancel(context)
                result.success(!SyncJobScheduler.isScheduled(context))
            }

            else -> result.notImplemented()
        }
    }

    /** Система отобрала задание: просим Dart закончить на ближайшей проверке. */
    fun requestStop() {
        stopRequested = true
        runCatching { channel.invokeMethod("cancel", null) }
    }

    private companion object {
        const val CHANNEL = "ru.cloudly.sync/background"
    }
}
