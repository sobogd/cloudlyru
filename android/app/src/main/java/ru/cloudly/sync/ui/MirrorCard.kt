package ru.cloudly.sync.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ru.cloudly.sync.device.MediaRules
import ru.cloudly.sync.mirror.MirrorStatus

/**
 * Прогресс зеркала: сколько реально лежит в облаке, сколько ждёт и что происходит прямо сейчас.
 *
 * Считать «сколько в облаке» по базе зеркала, а не по завершённым проходам, важно: проход
 * ограничен по времени и может закончиться на середине, а выгруженное — уже выгружено.
 * Поэтому цифры не сбрасываются и не «отстают»: обновляет их движок по ходу дела, а интерфейс
 * просто читает поток состояния.
 */
@Composable
fun MirrorCard(status: MirrorStatus, modifier: Modifier = Modifier) {
    Card(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Text("Зеркало", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    phaseTitle(status),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 8.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            if (status.localBytes > 0) {
                LinearProgressIndicator(
                    progress = { status.percent / 100f },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Text(
                buildString {
                    append("в облаке: ${status.inCloudFiles} файлов · ${MediaRules.formatSize(status.inCloudBytes)}")
                    if (status.localBytes > 0) {
                        append(" из ${status.localFiles} · ${MediaRules.formatSize(status.localBytes)}")
                    }
                },
                fontSize = 12.sp,
            )

            status.currentName?.let { name ->
                Text(
                    "сейчас: $name — ${status.currentPercent}% " +
                        "(${MediaRules.formatSize(status.currentSent)} из ${MediaRules.formatSize(status.currentTotal)})",
                    fontSize = 12.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            if (status.waitingFiles > 0 && status.currentName == null) {
                Text(
                    "ждёт выгрузки: ${status.waitingFiles} файлов · ${MediaRules.formatSize(status.waitingBytes)}",
                    fontSize = 12.sp,
                )
            }

            if (status.passUploadedFiles > 0 || status.passDownloaded > 0 || status.passFailed > 0) {
                Text(
                    buildString {
                        append("за проход: выгружено ${status.passUploadedFiles}")
                        if (status.passDownloaded > 0) append(", скачано ${status.passDownloaded}")
                        if (status.passFailed > 0) append(", ошибок ${status.passFailed}")
                    },
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            status.error?.let { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.error) }
            if (status.blocked > 0) {
                Text(
                    "удаления приостановлены: ${status.blocked} — подтверждение в настройках",
                    fontSize = 11.sp,
                )
            }
        }
    }
}

/** Что зеркало делает прямо сейчас — короткой строкой. */
fun phaseTitle(status: MirrorStatus): String = when (status.phase) {
    MirrorStatus.Phase.SCAN -> "обхожу папки"
    MirrorStatus.Phase.CLOUD -> "сверяюсь с облаком"
    MirrorStatus.Phase.UPLOAD -> "выгружаю"
    MirrorStatus.Phase.DELETE -> "убираю удалённое"
    MirrorStatus.Phase.PAUSED -> "выключено"
    MirrorStatus.Phase.IDLE -> when {
        status.checkedAt > 0 -> "проверено ${ago(status.checkedAt)}"
        status.lastText.isNotBlank() -> "готово"
        else -> "ещё не запускалось"
    }
}

/** «5 с назад», «3 мин назад» — понятнее, чем время последней проверки. */
fun ago(at: Long): String {
    val seconds = ((System.currentTimeMillis() - at) / 1000).coerceAtLeast(0)
    return when {
        seconds < 10 -> "только что"
        seconds < 60 -> "$seconds с назад"
        seconds < 3600 -> "${seconds / 60} мин назад"
        else -> "${seconds / 3600} ч назад"
    }
}
