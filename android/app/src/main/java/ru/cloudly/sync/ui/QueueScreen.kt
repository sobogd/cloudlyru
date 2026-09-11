package ru.cloudly.sync.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.QueueItem
import ru.cloudly.sync.data.QueueState
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.device.MediaRules
import ru.cloudly.sync.queue.QueueRefresher
import ru.cloudly.sync.queue.UploadRunner

/**
 * Раздел «Очередь»: что нашлось нового и ждёт выгрузки. Очередь только формируется —
 * запуск файлов ручной и появится следующим шагом, кнопкой на строке.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QueueScreen() {
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val scope = rememberCoroutineScope()

    val runner = remember { app.uploads }
    val progress by runner.progress.collectAsState()
    var items by remember { mutableStateOf<List<QueueItem>>(emptyList()) }
    var waiting by remember { mutableStateOf(0) }
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        val loaded = withContext(Dispatchers.IO) { app.queueStore.items() }
        items = loaded
        waiting = withContext(Dispatchers.IO) { app.queueStore.waitingCount() }
    }

    suspend fun rebuild() {
        busy = true
        note = "прохожу папки…"
        val result = withContext(Dispatchers.IO) {
            runCatching { QueueRefresher.refresh(context) { line -> } }
        }
        busy = false
        result.fold(
            onSuccess = {
                note = it.text()
                problem = it.problem
            },
            onFailure = {
                note = "не удалось пройти папки: ${hint(it)}"
                problem = null
            },
        )
        reload()
    }

    LaunchedEffect(Unit) { rebuild() }

    // выгрузка закончилась — показываем новое состояние строк
    LaunchedEffect(progress) {
        if (progress == null) reload()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Очередь", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            if (waiting == 0) "нечего выгружать" else "ждут запуска: $waiting",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            scope.launch {
                                withContext(Dispatchers.IO) { app.queueStore.clearFinished() }
                                reload()
                            }
                        },
                    ) { Text("Очистить готовые") }
                    IconButton(enabled = !busy, onClick = { scope.launch { rebuild() } }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Обновить очередь")
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Column(Modifier.fillMaxSize()) {
                if (note.isNotEmpty()) {
                    Text(
                        note,
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                    )
                }
                problem?.let {
                    Text(
                        it,
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                    )
                }
                if (items.isEmpty() && !busy) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(24.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text("Очередь пуста", fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Новое и изменённое в выбранных папках появится здесь само. " +
                                "Папки выбираются в «Настройках».",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                LazyColumn(Modifier.fillMaxSize()) {
                    items(items, key = { it.id }) { item ->
                        QueueRow(
                            item = item,
                            progress = progress?.takeIf { it.id == item.id },
                            canStart = progress == null &&
                                (item.state == QueueState.PENDING || item.state == QueueState.FAILED),
                            onStart = { runner.start(item.id) },
                        )
                    }
                }
            }
            if (busy) {
                LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter))
            }
        }
    }
}

@Composable
private fun QueueRow(
    item: QueueItem,
    progress: UploadRunner.Progress?,
    canStart: Boolean,
    onStart: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = when {
                MediaRules.isVideo(item.name) -> Icons.Filled.VideoLibrary
                MediaRules.isImage(item.name) -> Icons.Filled.Image
                else -> Icons.AutoMirrored.Filled.InsertDriveFile
            },
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(item.name, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                if (progress != null) {
                    "выгрузка: ${progress.percent}% из ${MediaRules.formatSize(progress.total)}"
                } else {
                    subtitle(item)
                },
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (item.state == QueueState.FAILED && !item.lastError.isNullOrBlank()) {
                Text(
                    item.lastError.orEmpty(),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.error,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        // Запуск ручной и по одному файлу: пока идёт выгрузка, остальные кнопки неактивны
        IconButton(enabled = canStart, onClick = onStart) {
            Icon(Icons.Filled.PlayArrow, contentDescription = "Выгрузить файл")
        }
    }
    HorizontalDivider()
}

private fun subtitle(item: QueueItem): String {
    val where = if (item.section == Section.PHOTOS) "Фото" else "Файлы"
    val place = item.relDir.ifBlank { "плоско" }
    return "$where · $place · ${MediaRules.formatSize(item.size)} · ${stateText(item.state)}"
}

private fun stateText(state: QueueState): String = when (state) {
    QueueState.PENDING -> "ждёт запуска"
    QueueState.RUNNING -> "грузится"
    QueueState.DONE -> "выгружен"
    QueueState.SKIPPED -> "уже в облаке"
    QueueState.FAILED -> "ошибка"
}
