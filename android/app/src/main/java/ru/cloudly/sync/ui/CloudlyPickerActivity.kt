package ru.cloudly.sync.ui

import android.content.ClipData
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.device.MediaRules
import ru.cloudly.sync.docs.CloudlyDocumentsProvider
import ru.cloudly.sync.net.FolderChildren
import ru.cloudly.sync.net.RemoteEntry

/**
 * «Выбрать файл из облака» — своё окно выбора для чужих приложений: приложение отвечает
 * на системный запрос файла (`ACTION_GET_CONTENT`) собственным экраном, без прослойки
 * системного выборщика.
 *
 * Файл уходит получателю обычной content-ссылкой на провайдера документов
 * (`content://ru.cloudly.sync.documents/document/f:<id>`), поэтому он открывается и читается
 * так же, как из системных «Файлов», и ничего копировать в другое место не нужно.
 */
class CloudlyPickerActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // приложение может просить конкретный тип: «image/*», «application/pdf», список типов
        // или ничего (`*/*`) — в выборе это учитываем, иначе получатель откажется от файла
        val requests = intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)?.toList()
            ?: listOfNotNull(intent.type)

        setContent {
            // Схема по системной теме: раньше приложение всегда было светлым
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    PickerScreen(
                        requests = requests,
                        onPick = { entry -> returnFile(entry) },
                        onCancel = { finish() },
                    )
                }
            }
        }
    }

    /** Отдать получателю выбранный файл: ссылка на провайдера и право её прочитать. */
    private fun returnFile(entry: RemoteEntry) {
        val uri = CloudlyDocumentsProvider.fileUri(entry.id)
        val result = Intent().apply {
            data = uri
            type = entry.mime.ifBlank { "*/*" }
            clipData = ClipData.newUri(contentResolver, entry.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        setResult(RESULT_OK, result)
        finish()
    }
}

/** Хлебная крошка пути: в облаке адресуем папки по id, имя нужно только для шапки. */
private data class Crumb(val id: String, val name: String)

private data class Loaded(val folderId: String, val children: FolderChildren)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerScreen(
    requests: List<String>,
    onPick: (RemoteEntry) -> Unit,
    onCancel: () -> Unit,
) {
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val token = remember { app.prefs.token }

    var stack by remember { mutableStateOf(emptyList<Crumb>()) }
    var folders by remember { mutableStateOf(emptyList<Pair<String, String>>()) }
    var entries by remember { mutableStateOf(emptyList<RemoteEntry>()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf("") }

    val currentId = stack.lastOrNull()?.id

    LaunchedEffect(currentId, token) {
        if (token.isBlank()) {
            error = "вход не выполнен: откройте Cloudly и войдите в аккаунт"
            loading = false
            return@LaunchedEffect
        }
        loading = true
        error = ""
        val outcome = withContext(Dispatchers.IO) {
            runCatching {
                val folderId = currentId ?: app.api.rootFolderId()
                Loaded(folderId, app.api.children(folderId))
            }
        }
        loading = false
        outcome.fold(
            onSuccess = { loaded ->
                if (currentId == null) stack = listOf(Crumb(loaded.folderId, "Облако"))
                folders = loaded.children.folderIds.entries
                    .sortedBy { it.key.lowercase() }
                    .map { it.key to it.value }
                entries = loaded.children.entries
                    .filter { entry -> requests.isEmpty() || requests.any { MediaRules.matchesRequest(it, entry.mime) } }
                    .sortedBy { it.name.lowercase() }
            },
            onFailure = { error = hint(it) },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Облако Cloudly", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            stack.lastOrNull()?.name ?: "корень",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = { if (stack.size > 1) stack = stack.dropLast(1) else onCancel() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Назад")
                    }
                },
                actions = { TextButton(onClick = onCancel) { Text("Отмена") } },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            when {
                loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                error.isNotEmpty() -> Message(error, isError = true)
                folders.isEmpty() && entries.isEmpty() -> Message("В этой папке ничего нет")
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(folders, key = { it.second }) { (name, id) ->
                        PickerRow(
                            icon = Icons.Filled.Folder,
                            title = name,
                            subtitle = "папка",
                            onClick = { stack = stack + Crumb(id, name) },
                        )
                    }
                    items(entries, key = { it.id }) { entry ->
                        PickerRow(
                            icon = when {
                                entry.mime.startsWith("video/") -> Icons.Filled.VideoLibrary
                                entry.mime.startsWith("image/") -> Icons.Filled.Image
                                else -> Icons.AutoMirrored.Filled.InsertDriveFile
                            },
                            title = entry.name,
                            subtitle = "${MediaRules.formatSize(entry.size)} · ${entry.mime.ifBlank { "файл" }}",
                            onClick = { onPick(entry) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PickerRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                subtitle,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
    HorizontalDivider()
}

@Composable
private fun Message(text: String, isError: Boolean = false) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text,
            fontSize = 13.sp,
            color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(6.dp))
    }
}
