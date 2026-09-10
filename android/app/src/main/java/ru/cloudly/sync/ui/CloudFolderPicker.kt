package ru.cloudly.sync.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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

/**
 * Многоуровневый выбор папки в облаке: ходим по дереву (на сервере оно может быть большим,
 * поэтому страницы подгружаются через `/folders/:id/children`), можно создать папку на месте
 * и выбрать текущую. Тот же компонент используется при «Поделиться».
 */
@Composable
fun CloudFolderPicker(
    title: String = "Папка в облаке",
    initialFolderId: String?,
    initialPath: List<Pair<String, String>> = emptyList(),
    allowCreate: Boolean = true,
    onDismiss: () -> Unit,
    onPicked: (id: String, path: String, breadcrumbs: List<Pair<String, String>>) -> Unit,
) {
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val scope = rememberCoroutineScope()
    // стек «id → имя»: он же хлебные крошки и путь на сервере
    val crumbs = remember { mutableStateListOf<Pair<String, String>>() }
    val folders = remember { mutableStateListOf<Pair<String, String>>() }
    var newName by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var currentId by remember { mutableStateOf(initialFolderId.orEmpty()) }

    fun path(): String = crumbs.joinToString("/") { it.second }
    fun resolvedPath(): String = if (crumbs.isEmpty()) "Главная" else path()

    fun load(folderId: String?) {
        loading = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val id = folderId ?: app.api.rootFolderId()
                    id to app.api.subfolders(id)
                }
            }
            loading = false
            result.exceptionOrNull()?.let { error = "не прочитал папки: ${it.message}" }
            result.getOrNull()?.let { (id, list) ->
                currentId = id
                error = ""
                folders.clear()
                folders.addAll(list.sortedBy { it.first.lowercase() })
            }
        }
    }

    LaunchedEffect(Unit) {
        crumbs.clear()
        crumbs.addAll(initialPath)
        load(initialFolderId ?: initialPath.lastOrNull()?.first)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                Text(
                    "Главная" + if (crumbs.isEmpty()) "" else " / " + resolvedPath(),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(6.dp),
                )
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(
                        enabled = crumbs.isNotEmpty(),
                        onClick = {
                            if (crumbs.isNotEmpty()) {
                                crumbs.removeAt(crumbs.size - 1)
                                load(crumbs.lastOrNull()?.first)
                            }
                        },
                    ) { Text("⬆️ Вверх", fontSize = 12.sp) }
                    OutlinedButton(onClick = {
                        crumbs.clear()
                        load(null)
                    }) { Text("В корень", fontSize = 12.sp) }
                }
                if (allowCreate) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = newName,
                            onValueChange = { newName = it },
                            label = { Text("Новая папка здесь") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(0.66f),
                        )
                        Spacer(Modifier.height(0.dp))
                        TextButton(
                            enabled = newName.isNotBlank(),
                            onClick = {
                                scope.launch {
                                    val created = withContext(Dispatchers.IO) {
                                        runCatching { app.api.ensurePath(newName.trim(), currentId) }
                                    }
                                    created.exceptionOrNull()?.let { error = "не создал папку: ${it.message}" }
                                    created.getOrNull()?.let { id ->
                                        crumbs.add(id to newName.trim())
                                        newName = ""
                                        load(id)
                                    }
                                }
                            },
                        ) { Text("Создать", fontSize = 12.sp) }
                    }
                }
                Spacer(Modifier.height(6.dp))
                if (error.isNotEmpty()) Text(error, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
                if (loading) Text("Загрузка…", fontSize = 12.sp)
                if (!loading && folders.isEmpty()) Text("Вложенных папок нет", fontSize = 12.sp)
                LazyColumn(modifier = Modifier.height(220.dp)) {
                    items(folders, key = { it.second }) { (name, id) ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    crumbs.add(id to name)
                                    load(id)
                                }
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("📁 $name", fontSize = 14.sp)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onPicked(currentId, resolvedPath(), crumbs.toList()) }) {
                Text("Выбрать эту папку")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )
}
