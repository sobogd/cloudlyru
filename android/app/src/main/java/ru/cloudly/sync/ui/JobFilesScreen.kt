package ru.cloudly.sync.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.work.SyncService

/**
 * Экран файлов задачи: что выгружено, что вытеснено и что закреплено.
 * Отсюда же можно вернуть файл на телефон и закрепить его — «офлайн» без веба.
 */
@Composable
fun JobFilesScreen(job: Db.Job, app: App, onBack: () -> Unit) {
    var filter by remember { mutableStateOf("all") }
    var version by remember { mutableStateOf(0) }
    var error by remember { mutableStateOf("") }
    // чтение из SQLite — только вне главного потока: на большой библиотеке это подвисания UI
    val all = remember(job.id, version) {
        runBlocking(Dispatchers.IO) { app.db.itemsOf(job.id) }
    }
    val items = remember(job.id, version, filter) {
        when (filter) {
            "evicted" -> all.filter { it.state == Db.STATE_EVICTED }
            "pinned" -> all.filter { it.keepOffline }
            "new" -> all.filter { it.state == Db.STATE_NEW }
            else -> all
        }
    }
    val evicted = all.count { it.state == Db.STATE_EVICTED }
    val pinned = all.count { it.keepOffline }
    val pending = all.count { it.state == Db.STATE_NEW }

    val scope = rememberCoroutineScope()
    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("⬅️ Назад") }
            Spacer(Modifier.height(0.dp))
            Text("  ${job.targetPath}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(8.dp))
        val summary = remember(job.id, version) { runBlocking(Dispatchers.IO) { app.db.opSummary(job.id) } }
        val progress = remember(job.id, version) { app.db.kv("job_progress:${job.id}").orEmpty() }
        if (progress.isNotEmpty()) Text(progress, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "всего ${all.size} · не выгружено $pending · в очереди ${summary.ready}" +
                if (summary.waiting > 0) " · ждут повтора ${summary.waiting}" else "",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (summary.waiting > 0) {
            val wait = (summary.soonestAt - System.currentTimeMillis()).coerceAtLeast(0)
            Text(
                "ближайшая попытка через ${minutes(wait)} — или нажмите «Повторить сейчас»",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.error,
            )
        }
        OutlinedButton(onClick = {
            app.db.resetOps(job.id)
            SyncService.start(app)
            version += 1
        }) { Text("Повторить всё сейчас", fontSize = 12.sp) }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(
                "all" to "все ${all.size}",
                "new" to "не выгружены $pending",
                "evicted" to "вытеснены $evicted",
                "pinned" to "закреплены $pinned",
            ).forEach { (key, label) ->
                OutlinedButton(onClick = { filter = key }) {
                    Text(if (filter == key) "• $label" else label, fontSize = 12.sp)
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        if (error.isNotEmpty()) Text(error, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
        if (items.isEmpty()) {
            Text(
                when (filter) {
                    "all" -> "Файлов пока нет: нажмите «Синхронизировать сейчас» или подождите фонового прохода"
                    "new" -> "Всё выгружено"
                    "evicted" -> "Ничего не вытеснено"
                    else -> "Ничего не закреплено"
                },
                fontSize = 13.sp,
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth()) {
            items(items.take(500), key = { it.relPath }) { item ->
                Card(modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
                    Column(Modifier.padding(10.dp)) {
                        Text(item.name, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            "${item.relPath}  ·  ${stateLabel(item.state)}" +
                                if (item.keepOffline) "  ·  закреплён" else "",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        // состояние операции: без него «ждёт выгрузки» выглядит как «ничего не происходит»
                        val op = remember(item.relPath, version) {
                            runBlocking(Dispatchers.IO) { app.db.opFor(job.id, item.relPath) }
                        }
                        if (op != null) {
                            val waitingMs = (op.nextAttemptAt - System.currentTimeMillis()).coerceAtLeast(0)
                            Text(
                                buildString {
                                    append(opKindLabel(op.kind))
                                    if (op.attempts > 0) append(" · попыток ${op.attempts}")
                                    if (op.lastError != null) append(" · ${op.lastError}")
                                    if (waitingMs > 0) append(" · следующая через ${minutes(waitingMs)}")
                                },
                                fontSize = 11.sp,
                                color = if (op.lastError != null) MaterialTheme.colorScheme.error
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (item.state == Db.STATE_EVICTED) {
                                Button(onClick = {
                                    app.engine().restoreToPhone(job.id, item.relPath)
                                    SyncService.start(app)
                                    version += 1
                                }) { Text("Вернуть на телефон", fontSize = 12.sp) }
                            }
                            if (op != null) {
                                OutlinedButton(onClick = {
                                    // снять паузу и попробовать прямо сейчас
                                    app.db.resetOp(job.id, item.relPath)
                                    SyncService.start(app)
                                    version += 1
                                }) { Text("Повторить сейчас", fontSize = 12.sp) }
                            }
                            if (!item.remoteEntryId.isNullOrBlank()) {
                                OutlinedButton(onClick = {
                                    scope.launch {
                                        // сеть и диск — не в главном потоке: иначе запрос молча падает
                                        val failure = withContext(Dispatchers.IO) {
                                            runCatching {
                                                app.engine().setFileKeepOffline(
                                                    job.id,
                                                    item.relPath,
                                                    item.remoteEntryId!!,
                                                    !item.keepOffline,
                                                )
                                            }.exceptionOrNull()
                                        }
                                        error = failure?.let { "не получилось: ${it.message}" } ?: ""
                                        version += 1
                                    }
                                }) {
                                    Text(if (item.keepOffline) "Снять закрепление" else "Держать офлайн", fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun opKindLabel(kind: String): String = when (kind) {
    Db.OP_UPLOAD -> "выгрузка"
    Db.OP_DOWNLOAD -> "скачивание"
    Db.OP_DELETE -> "удаление"
    else -> kind
}

private fun minutes(ms: Long): String {
    val totalMinutes = ms / 60_000
    return when {
        totalMinutes < 1 -> "минуту"
        totalMinutes < 60 -> "$totalMinutes мин"
        else -> "${totalMinutes / 60} ч ${totalMinutes % 60} мин"
    }
}

private fun stateLabel(state: String): String = when (state) {
    Db.STATE_SYNCED -> "в облаке"
    Db.STATE_EVICTED -> "вытеснен (только в облаке)"
    Db.STATE_NEW -> "ждёт выгрузки"
    else -> state
}
