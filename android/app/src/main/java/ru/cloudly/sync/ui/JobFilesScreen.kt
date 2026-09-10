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
    var filter by remember { mutableStateOf("evicted") }
    var version by remember { mutableStateOf(0) }
    val items = remember(job.id, version, filter) {
        val all = app.db.itemsOf(job.id)
        when (filter) {
            "evicted" -> all.filter { it.state == Db.STATE_EVICTED }
            "pinned" -> all.filter { it.keepOffline }
            "new" -> all.filter { it.state == Db.STATE_NEW }
            else -> all
        }
    }
    val all = remember(job.id, version) { app.db.itemsOf(job.id) }
    val evicted = all.count { it.state == Db.STATE_EVICTED }
    val pinned = all.count { it.keepOffline }
    val pending = all.count { it.state == Db.STATE_NEW }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("⬅️ Назад") }
            Spacer(Modifier.height(0.dp))
            Text("  ${job.targetPath}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "всего ${all.size} · вытеснено $evicted · закреплено $pinned · не выгружено $pending",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("evicted" to "вытесненные", "pinned" to "закреплённые", "new" to "не выгружены", "all" to "все")
                .forEach { (key, label) ->
                    OutlinedButton(onClick = { filter = key }) {
                        Text(if (filter == key) "• $label" else label, fontSize = 12.sp)
                    }
                }
        }
        Spacer(Modifier.height(8.dp))
        if (items.isEmpty()) {
            Text("Пусто", fontSize = 13.sp)
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
                        Spacer(Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (item.state == Db.STATE_EVICTED) {
                                Button(onClick = {
                                    app.engine().restoreToPhone(job.id, item.relPath)
                                    SyncService.start(app)
                                    version += 1
                                }) { Text("Вернуть на телефон", fontSize = 12.sp) }
                            }
                            if (item.remoteEntryId != null) {
                                OutlinedButton(onClick = {
                                    runCatching {
                                        app.engine().setFileKeepOffline(
                                            job.id,
                                            item.relPath,
                                            item.remoteEntryId!!,
                                            !item.keepOffline,
                                        )
                                    }
                                    version += 1
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

private fun stateLabel(state: String): String = when (state) {
    Db.STATE_SYNCED -> "в облаке"
    Db.STATE_EVICTED -> "вытеснен (только в облаке)"
    Db.STATE_NEW -> "ждёт выгрузки"
    else -> state
}
