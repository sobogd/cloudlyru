package ru.cloudly.sync.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Db
import java.io.File

/**
 * Освобождение места. Единственное место в приложении, где что-то удаляется, и только по нажатию
 * пользователя: файл уходит с телефона, если он уже подтверждён в облаке и с момента выгрузки
 * не менялся. Файлы на сервере не трогаются никогда.
 */
@Composable
fun FreeSpaceScreen(app: App, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val groups = remember { mutableStateListOf<Pair<Db.Job, List<Db.Cached>>>() }
    val selected = remember { mutableStateListOf<String>() }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf(false) }
    // перечитываем список только по делу: обход кэша заново на каждом тике — лишние обращения к диску
    var reload by remember { mutableStateOf(0) }

    fun key(item: Db.Cached) = "${item.jobId}:${item.relPath}"

    LaunchedEffect(reload) {
        val loaded = withContext(Dispatchers.IO) {
            app.db.jobs().map { job ->
                // предлагаем только то, что реально лежит на диске и не менялось после выгрузки
                val freeable = app.db.cacheOf(job.id).filter { item ->
                    !item.entryId.isNullOrBlank() && run {
                        val f = File(item.localPath)
                        f.isFile && f.length() == item.localSize && f.lastModified() == item.localMtime
                    }
                }
                job to freeable
            }.filter { it.second.isNotEmpty() }
        }
        groups.clear()
        groups.addAll(loaded)
        val valid = loaded.flatMap { it.second }.map { key(it) }.toHashSet()
        selected.retainAll(valid)
    }

    val all = groups.flatMap { it.second }
    val chosen = all.filter { key(it) in selected }
    val chosenBytes = chosen.sumOf { it.localSize }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("Назад") }
        }
        Spacer(Modifier.height(8.dp))
        Text("Освободить место", fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(
            "Удаляем с телефона только то, что уже лежит в облаке и с тех пор не менялось. " +
                "В облаке файлы остаются.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))

        if (all.isEmpty()) {
            Text("Нечего удалять: всё, что выгружено, уже убрано или изменено после выгрузки.", fontSize = 13.sp)
            return@Column
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = {
                selected.clear()
                if (chosen.size != all.size) selected.addAll(all.map { key(it) })
            }) { Text("Выбрать всё", fontSize = 12.sp) }
            OutlinedButton(onClick = { selected.clear() }) { Text("Снять выбор", fontSize = 12.sp) }
            OutlinedButton(onClick = { reload += 1 }) { Text("Обновить", fontSize = 12.sp) }
        }
        Spacer(Modifier.height(8.dp))

        LazyColumn(modifier = Modifier.weight(1f)) {
            groups.forEach { (job, items) ->
                item(key = "job-${job.id}") {
                    val allChosen = items.all { key(it) in selected }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable {
                            if (allChosen) selected.removeAll(items.map { key(it) }.toSet())
                            else items.forEach { if (key(it) !in selected) selected.add(key(it)) }
                        },
                    ) {
                        Checkbox(checked = allChosen, onCheckedChange = null)
                        Column {
                            Text(job.sourceDir, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                            Text(
                                "${items.size} файлов · ${mb(items.sumOf { it.localSize })}",
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                items(items, key = { key(it) }) { entry ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable {
                            val k = key(entry)
                            if (k in selected) selected.remove(k) else selected.add(k)
                        },
                    ) {
                        Checkbox(checked = key(entry) in selected, onCheckedChange = null)
                        Column {
                            Text(entry.relPath, fontSize = 12.sp)
                            Text(mb(entry.localSize), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        Text("Выбрано: ${chosen.size} файлов · ${mb(chosenBytes)}", fontSize = 13.sp)
        if (result.isNotEmpty()) Text(result, fontSize = 12.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                enabled = !busy && chosen.isNotEmpty(),
                onClick = { confirm = true },
            ) { Text(if (busy) "…" else "Удалить с телефона") }
            OutlinedButton(onClick = onBack) { Text("Готово") }
        }
        Spacer(Modifier.height(8.dp))

        Card(Modifier.fillMaxWidth()) {
            Text(
                "Удаление необратимо на телефоне. Если файла ещё нет в облаке (или он не догрузился), " +
                    "он останется нетронутым.",
                fontSize = 11.sp,
                modifier = Modifier.padding(10.dp),
            )
        }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Удалить ${chosen.size} файлов?") },
            text = { Text("С телефона будет удалено ${mb(chosenBytes)}. В облаке копии останутся.") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = false
                    busy = true
                    result = ""
                    scope.launch {
                        val text = withContext(Dispatchers.IO) {
                            val (count, freed) = app.engine().deleteUploadedLocally(chosen)
                            val skipped = chosen.size - count
                            "удалено $count файлов, освобождено ${mb(freed)}" +
                                if (skipped > 0) ", пропущено $skipped (изменились после выгрузки)" else ""
                        }
                        busy = false
                        result = text
                        selected.clear()
                        reload += 1
                    }
                }) { Text("Удалить") }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Отмена") } },
        )
    }
}

private fun mb(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f ГБ".format(bytes.toDouble() / (1L shl 30))
    bytes >= 1L shl 20 -> "%.1f МБ".format(bytes.toDouble() / (1L shl 20))
    bytes >= 1024 -> "%.0f КБ".format(bytes.toDouble() / 1024)
    else -> "$bytes Б"
}
