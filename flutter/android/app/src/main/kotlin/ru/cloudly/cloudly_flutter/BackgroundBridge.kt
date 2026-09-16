package ru.cloudly.cloudly_flutter

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Канал фонового прохода (`ru.cloudly.sync/background`).
 *
 * Одним каналом пользуются обе стороны: из приложения по нему заводят и снимают задание,
 * а из фонового изолята спрашивают, не на экране ли приложение, узнают бюджет задания,
 * сообщают об итоге и принимают просьбу остановиться.
 *
 * Канал ставится дважды и это правильно: свой экземпляр — на движке приложения (главная
 * активность), свой — на движке фонового задания. У каждого движка свой мессенджер.
 *
 * ## Просьба остановиться живёт не здесь
 *
 * Флаг остановки — свойство **задания**, а не моста: система может отобрать задание раньше,
 * чем движок и мост вообще появятся (`onStopJob` до конца `ensureInitializationCompleteAsync`).
 * Поэтому владелец флага — служба, и мост читает его через [stopRequestedProvider]: тогда
 * изолят, поднявшийся после остановки, всё равно получит «да» на свой вопрос `stopRequested`,
 * а не начнёт семиминутный проход, который система уже прервала.
 */
class BackgroundBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    /**
     * Флаг остановки, которым владеет служба задания (`SyncJobService`). У экземпляра
     * приложения его нет: там мост никто не останавливает, и по умолчанию флаг всегда `false`.
     */
    private val stopRequestedProvider: () -> Boolean = { false },
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    /** Служба подписана на итог: по нему она закрывает движок и докладывает системе. */
    var onFinished: ((Boolean, String?) -> Unit)? = null

    /**
     * Остановку просили у этого моста (`requestStop`). Второй источник — флаг службы
     * ([stopRequestedProvider]): событие могло не застать слушателя (изолят только поднимается),
     * поэтому просьба лежит ещё и флагом, который Dart спрашивает сам.
     */
    @Volatile
    private var stopRequested: Boolean = false

    init {
        channel.setMethodCallHandler(this)
    }

    /** Просили ли остановиться: ответ для Dart собирается из обоих источников. */
    private fun isStopRequested(): Boolean = stopRequested || stopRequestedProvider()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Итог приходит из Dart, когда проход закончился. Ответ отдаём до вызова
            // `onFinished`: тот закрывает движок, и отвечать из уже закрытого движка было бы
            // нельзя. `ok` по умолчанию false — не разобравшись в аргументах, безопаснее
            // попросить систему повторить задание, чем считать проход удачным
            "finished" -> {
                val ok = call.argument<Boolean>("ok") ?: false
                val note = call.argument<String>("note")
                result.success(true)
                onFinished?.invoke(ok, note)
            }

            // Ответ берётся у объекта AppPresence, а не у этой службы: «на экране ли
            // приложение» — свойство процесса, и оно одно для обоих движков
            "appInForeground" -> result.success(AppPresence.foreground)

            "stopRequested" -> result.success(isStopRequested())

            // Бюджеты задания: сколько отведено зеркалу и до какого момента наполнять очередь.
            // Числа живут в службе (`SyncJobService.PASS_BUDGET_MS`, `QUEUE_DEADLINE_MS`), а не
            // в изоляте: они связаны с её предохранителем (`JOB_TIMEOUT_MS`) и с таймаутом
            // системы, и копия в Dart разъезжалась бы с ними при первой же правке
            "budgets" -> result.success(
                mapOf(
                    "pass" to SyncJobService.PASS_BUDGET_MS,
                    "queue" to SyncJobService.QUEUE_DEADLINE_MS,
                ),
            )

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

    /**
     * Система отобрала задание: просим Dart закончить на ближайшей проверке.
     *
     * Флаг ставится до вызова: событие может не застать слушателя (изолят только поднимается),
     * и тогда Dart всё равно прочитает просьбу сам через `stopRequested`. Ошибку доставки
     * глушим — изолята может уже не быть, а падать службе из-за этого незачем.
     */
    fun requestStop() {
        stopRequested = true
        runCatching { channel.invokeMethod("cancel", null) }
    }

    private companion object {
        const val CHANNEL = "ru.cloudly.sync/background"
    }
}
