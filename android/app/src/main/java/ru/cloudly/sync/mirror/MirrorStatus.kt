package ru.cloudly.sync.mirror

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Что зеркало делает прямо сейчас и сколько уже лежит в облаке.
 *
 * Живёт в области приложения: пишут сюда движок (каждый шаг прохода), мгновенный режим
 * (когда он проверял журнал) и настройки (когда пользователь включил или выключил зеркало).
 * Читает интерфейс — и раздел «Файлы», и настройки, — поэтому состояние одно на всё приложение,
 * а не по копии на каждый экран: иначе две копии показывали бы разное.
 */
data class MirrorStatus(
    val phase: Phase = Phase.IDLE,
    /** Имя файла, который выгружается прямо сейчас. */
    val currentName: String? = null,
    val currentSent: Long = 0,
    val currentTotal: Long = 0,
    /** Сколько сделано за текущий проход. */
    val passUploadedFiles: Int = 0,
    val passUploadedBytes: Long = 0,
    val passDownloaded: Int = 0,
    val passFailed: Int = 0,
    /** Что уже лежит в облаке по данным зеркала. */
    val inCloudFiles: Int = 0,
    val inCloudBytes: Long = 0,
    /** Сколько всего нашлось в выбранных папках на последнем обходе. */
    val localFiles: Int = 0,
    val localBytes: Long = 0,
    /** Сколько ждало выгрузки на момент последнего плана. */
    val waitingFiles: Int = 0,
    val waitingBytes: Long = 0,
    val startedAt: Long = 0,
    val finishedAt: Long = 0,
    /** Когда в последний раз спрашивали облако (мгновенный режим). */
    val checkedAt: Long = 0,
    val lastText: String = "",
    val error: String? = null,
    val blocked: Int = 0,
    /** Почему удаления приостановлены: «пропало слишком много» или «папка не читается». */
    val blockedReason: String? = null,
) {
    enum class Phase {
        IDLE,
        SCAN,
        CLOUD,
        UPLOAD,
        DELETE,
        PAUSED,
    }

    val busy: Boolean get() = phase == Phase.SCAN || phase == Phase.CLOUD || phase == Phase.UPLOAD || phase == Phase.DELETE

    /** Доля выгруженного: от того, что лежит в выбранных папках. */
    val percent: Int
        get() = when {
            localBytes <= 0 -> if (inCloudFiles > 0) 100 else 0
            else -> ((inCloudBytes.coerceAtMost(localBytes) * 100) / localBytes).toInt()
        }

    /** Сколько процентов уходит у текущего файла. */
    val currentPercent: Int
        get() = if (currentTotal <= 0) 0 else ((currentSent * 100) / currentTotal).toInt()
}

/**
 * Одна точка, куда все пишут состояние зеркала. Поток, а не просто поле: интерфейсу нужно
 * обновляться по ходу выгрузки, а не по таймеру — иначе цифры «отстают» и выглядят глюком.
 */
class MirrorStatusHolder {

    private val state = MutableStateFlow(MirrorStatus())

    val flow: StateFlow<MirrorStatus> = state

    fun current(): MirrorStatus = state.value

    fun update(block: MirrorStatus.() -> MirrorStatus) {
        state.value = state.value.block()
    }
}
