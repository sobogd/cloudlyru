package ru.cloudly.sync.ui

import android.os.Environment
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File

/**
 * Выбор папки на телефоне: обычный файловый браузер вместо ручного ввода пути.
 * Работает с реальными путями (у приложения есть доступ ко всем файлам), поэтому выбранная
 * папка сразу пригодна для обхода — никаких преобразований из SAF-URI.
 */
@Composable
fun LocalFolderPicker(
    initial: String,
    onDismiss: () -> Unit,
    onPicked: (String) -> Unit,
) {
    val root = remember {
        File(Environment.getExternalStorageDirectory().absolutePath)
            .takeIf { it.isDirectory } ?: File("/storage/emulated/0")
    }
    var current by remember {
        mutableStateOf(File(initial).takeIf { it.isDirectory } ?: root)
    }
    var showHidden by remember { mutableStateOf(false) }
    val dirs = remember(current, showHidden) {
        (current.listFiles() ?: emptyArray())
            .filter { it.isDirectory }
            .filter { showHidden || !it.name.startsWith(".") }
            .sortedBy { it.name.lowercase() }
    }
    val shortcuts = remember {
        listOf("DCIM", "Pictures", "Download", "Documents", "Movies", "Music", "Android/media")
            .map { File(root, it) }
            .filter { it.isDirectory }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Папка на телефоне") },
        text = {
            Column {
                Text(
                    current.absolutePath,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(6.dp),
                )
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = { current = root }) { Text("В начало", fontSize = 12.sp) }
                    OutlinedButton(
                        enabled = current.parentFile != null && current.absolutePath != root.absolutePath,
                        onClick = { current.parentFile?.let { current = it } },
                    ) { Text("⬆️ Вверх", fontSize = 12.sp) }
                    OutlinedButton(onClick = { showHidden = !showHidden }) {
                        Text(if (showHidden) "Скрытые: да" else "Скрытые: нет", fontSize = 12.sp)
                    }
                }
                if (shortcuts.isNotEmpty() && current.absolutePath == root.absolutePath) {
                    Spacer(Modifier.height(4.dp))
                    Text("Частые папки", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        shortcuts.take(4).forEach { dir ->
                            OutlinedButton(onClick = { current = dir }) {
                                Text(dir.name, fontSize = 12.sp)
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        shortcuts.drop(4).forEach { dir ->
                            OutlinedButton(onClick = { current = dir }) {
                                Text(dir.name, fontSize = 12.sp)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = showHidden, onCheckedChange = { showHidden = it })
                    Text("показывать скрытые", fontSize = 12.sp)
                }
                Spacer(Modifier.height(6.dp))
                if (dirs.isEmpty()) {
                    Text("Вложенных папок нет", fontSize = 12.sp)
                }
                LazyColumn(modifier = Modifier.height(220.dp)) {
                    items(dirs, key = { it.absolutePath }) { dir ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { current = dir }
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("📁 ${dir.name}", fontSize = 14.sp)
                            Spacer(Modifier.width(8.dp))
                            val count = remember(dir.absolutePath) { dir.listFiles()?.size ?: 0 }
                            Text("$count", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onPicked(current.absolutePath) }) { Text("Выбрать эту папку") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )
}
