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
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.data.SelectionRules
import ru.cloudly.sync.device.DeviceFile
import ru.cloudly.sync.device.DeviceFiles
import ru.cloudly.sync.device.MediaRules
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference

/** Сколько файлов показываем в списке: больше в ручном листании всё равно не нужно. */
private const val LIST_LIMIT = 2000

/**
 * Раздел со списком файлов выбранных папок, свежие — сверху. Ни статусов, ни прогресса
 * загрузки здесь нет: раздел только показывает, что лежит на телефоне.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileListScreen(section: Section, onOpenFolders: () -> Unit) {
    val context = LocalContext.current
    val device = remember { DeviceFiles(context) }
    val selection = remember { Selection(context) }
    val roots = remember { SelectionRules.scanRoots(selection.paths(section)) }
    val access = remember { hasAllFilesAccess() }

    var files by remember { mutableStateOf<List<DeviceFile>>(emptyList()) }
    var scanning by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var reload by remember { mutableStateOf(0) }
    val progress = remember { AtomicReference("") }

    LaunchedEffect(roots, reload) {
        if (roots.isEmpty()) {
            files = emptyList()
            note = ""
            return@LaunchedEffect
        }
        scanning = true
        val effect = this
        val result = withContext(Dispatchers.IO) {
            device.scan(
                paths = roots,
                section = section,
                limit = LIST_LIMIT,
                onProgress = { progress.set(it) },
                isCancelled = { !effect.isActive },
            )
        }
        files = result.files
        note = buildString {
            append("файлов: ${result.total}")
            if (result.total > result.files.size) append(", показаны первые ${result.files.size}")
            if (result.unreadable > 0) append(", папок без доступа: ${result.unreadable}")
        }
        scanning = false
    }

    LaunchedEffect(scanning) {
        // прогресс приходит из фонового потока, поэтому переносим его в состояние здесь
        while (scanning) {
            note = progress.get()
            delay(120)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            if (section == Section.PHOTOS) "Фото и видео" else "Файлы",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        val subtitle = when {
                            roots.isEmpty() -> "папки не выбраны"
                            scanning -> note.ifBlank { "сканирую…" }
                            else -> note
                        }
                        Text(
                            subtitle,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { reload += 1 }, enabled = roots.isNotEmpty() && !scanning) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Обновить")
                    }
                    IconButton(onClick = onOpenFolders) {
                        Icon(Icons.Filled.FolderOpen, contentDescription = "Папки раздела")
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
            when {
                !access -> NoAccess()
                roots.isEmpty() -> NothingChosen(section, onOpenFolders)
                files.isEmpty() && !scanning -> Centered("Ничего не найдено в выбранных папках")
                else -> Column(Modifier.fillMaxSize()) {
                    Text(
                        roots.joinToString("\n"),
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(files, key = { it.path }) { file -> FileRow(file) }
                    }
                }
            }
            if (scanning) {
                LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter))
            }
        }
    }
}

@Composable
private fun FileRow(file: DeviceFile) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = when {
                !file.media -> Icons.AutoMirrored.Filled.InsertDriveFile
                MediaRules.isVideo(file.name) -> Icons.Filled.VideoLibrary
                else -> Icons.Filled.Image
            },
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(file.name, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "${file.dir} · ${MediaRules.formatSize(file.size)} · ${dateText(file.mtime)}",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
    HorizontalDivider()
}

private val dateFormat = SimpleDateFormat("d MMM yyyy, HH:mm", Locale.getDefault())

private fun dateText(mtime: Long): String =
    if (mtime <= 0) "дата неизвестна" else dateFormat.format(Date(mtime))

@Composable
private fun NoAccess() {
    val context = LocalContext.current
    Card(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Нужен доступ ко всем файлам", fontWeight = FontWeight.SemiBold)
            Text(
                "Без него не видно ни дерева папок, ни файлов. Приложение личное, ставится APK-ом.",
                fontSize = 12.sp,
            )
            Button(onClick = { openAllFilesSettings(context) }) { Text("Открыть настройки") }
        }
    }
}

@Composable
private fun NothingChosen(section: Section, onOpenFolders: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            if (section == Section.PHOTOS) "Папки для фото и видео не выбраны" else "Папки для файлов не выбраны",
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Отметьте галочками папки телефона — их содержимое появится здесь, свежие файлы сверху.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))
        Button(onClick = onOpenFolders) { Text("Выбрать папки") }
    }
}

@Composable
private fun Centered(text: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
