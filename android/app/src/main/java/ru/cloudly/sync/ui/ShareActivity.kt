package ru.cloudly.sync.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.sync.Hasher
import ru.cloudly.sync.sync.LocalFile
import ru.cloudly.sync.sync.Uploader
import java.io.File

/**
 * Приём файлов из «Поделиться»: пользователь выбирает папку в облаке и файлы уезжают сразу,
 * не дожидаясь фонового прохода и не требуя перекладывать их в синхронизируемую папку.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = extractUris(intent)
        if (uris.isEmpty()) {
            finish()
            return
        }
        setContent {
            MaterialTheme { Surface(modifier = Modifier.fillMaxSize()) { ShareScreen(uris) } }
        }
    }

    private fun extractUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        return when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.filterNotNull().orEmpty()
            else -> emptyList()
        }
    }
}

private data class RemoteFolder(val id: String, val name: String)

@Composable
private fun ShareScreen(uris: List<Uri>) {
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val scope = rememberCoroutineScope()

    var currentFolderId by remember { mutableStateOf(app.db.kv("share_folder_id").orEmpty()) }
    var currentPath by remember { mutableStateOf(app.db.kv("share_folder_path").orEmpty().ifEmpty { "Главная" }) }
    var folderNameField by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var cancelRequested by remember { mutableStateOf(false) }
    var lastError by remember { mutableStateOf("") }
    var progress by remember { mutableStateOf(0f) }
    val folders = remember { mutableStateListOf<RemoteFolder>() }

    fun loadFolders() {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val parent = if (currentFolderId.isBlank()) app.api.rootFolderId() else currentFolderId
                    if (currentFolderId.isBlank()) currentFolderId = parent
                    app.api.subfolders(parent).map { (name, id) -> RemoteFolder(id, name) }
                }
            }
            folders.clear()
            result.getOrNull()?.let { folders.addAll(it) }
            result.exceptionOrNull()?.let { status = "не прочитал папки: ${it.message}" }
        }
    }

    LaunchedEffect(currentFolderId) { loadFolders() }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Загрузить в облако", fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text("Файлов: ${uris.size} · папка: $currentPath", fontSize = 13.sp)
        Spacer(Modifier.height(10.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(enabled = !busy, onClick = {
                currentPath = "Главная"
                currentFolderId = ""
                app.db.putKv("share_folder_path", currentPath)
                app.db.putKv("share_folder_id", "")
            }) { Text("В корень") }
            OutlinedButton(enabled = !busy, onClick = { loadFolders() }) { Text("Обновить") }
        }
        Spacer(Modifier.height(8.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = folderNameField,
                onValueChange = { folderNameField = it },
                label = { Text("Новая папка здесь") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(0.7f),
            )
            OutlinedButton(enabled = !busy && folderNameField.isNotBlank(), onClick = {
                scope.launch {
                    val created = withContext(Dispatchers.IO) {
                        runCatching {
                            val id = app.api.ensurePath(folderNameField.trim(), currentFolderId)
                            currentFolderId = id
                            currentPath = "$currentPath/${folderNameField.trim()}"
                            app.db.putKv("share_folder_id", currentFolderId)
                            app.db.putKv("share_folder_path", currentPath)
                            folderNameField = ""
                        }
                    }
                    created.exceptionOrNull()?.let { status = "не создал папку: ${it.message}" }
                    loadFolders()
                }
            }) { Text("Создать") }
        }
        Spacer(Modifier.height(8.dp))

        LazyColumn(modifier = Modifier.fillMaxWidth().height(240.dp)) {
            items(folders, key = { it.id }) { folder ->
                Card(modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
                    Row(Modifier.padding(10.dp)) {
                        Text("📁 ${folder.name}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.fillMaxWidth(0.06f))
                        OutlinedButton(onClick = {
                            currentFolderId = folder.id
                            currentPath = "$currentPath/${folder.name}"
                            app.db.putKv("share_folder_id", currentFolderId)
                            app.db.putKv("share_folder_path", currentPath)
                        }) { Text("Войти", fontSize = 12.sp) }
                    }
                }
            }
        }

        Spacer(Modifier.height(10.dp))
        if (busy) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
        if (status.isNotEmpty()) Text(status, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy, onClick = {
                busy = true
                cancelRequested = false
                status = ""
                lastError = ""
                scope.launch {
                    val result = withContext(Dispatchers.IO) {
                        uploadShared(app, currentFolderId, uris, { cancelRequested }) { p -> progress = p }
                    }
                    busy = false
                    status = result.text
                    lastError = result.failed.joinToString("; ")
                    // закрываемся сами только если всё уехало: иначе пользователю нужен «Повторить»
                    if (result.failed.isEmpty() && !result.cancelled) {
                        kotlinx.coroutines.delay(1200)
                        (context as? ComponentActivity)?.finish()
                    }
                }
            }) { Text(if (lastError.isEmpty()) "Загрузить сюда" else "Повторить неудавшиеся") }
            OutlinedButton(
                onClick = {
                    if (busy) cancelRequested = true else (context as? ComponentActivity)?.finish()
                },
            ) { Text(if (busy) "Стоп" else "Закрыть") }
            if (lastError.isNotEmpty()) {
                Text("не уехало: $lastError", fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

private data class ShareResult(val text: String, val failed: List<String>, val cancelled: Boolean)

/** Копирование content:// в кэш, хэш, заливка, удаление временного файла. */
private fun uploadShared(
    app: App,
    folderId: String,
    uris: List<Uri>,
    isCancelled: () -> Boolean,
    onProgress: (Float) -> Unit,
): ShareResult {
    val cacheDir = File(app.cacheDir, "share").apply { mkdirs() }
    // остатки прошлых неудачных попыток не должны копиться
    cacheDir.listFiles()?.forEach { it.delete() }
    var done = 0
    val errors = ArrayList<String>()
    for ((index, uri) in uris.withIndex()) {
        if (isCancelled()) return ShareResult("остановлено: загружено $done из ${uris.size}", errors, true)
        val name = safeName(displayName(app, uri) ?: "shared-${System.currentTimeMillis()}")
        val tmp = File(cacheDir, name)
        // Имя приходит от чужого приложения: без проверки канонического пути «../../databases/…»
        // записал бы или удалил файл вне кэша.
        val canonicalCache = cacheDir.canonicalPath + File.separator
        if (!tmp.canonicalPath.startsWith(canonicalCache)) {
            errors.add("$name: недопустимое имя файла")
            continue
        }
        try {
            app.contentResolver.openInputStream(uri)?.use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, bufferSize = 1 shl 20) }
            } ?: throw IllegalStateException("не прочитал файл")
            val sha = Hasher.sha256(tmp)
            // имя могло быть занято (например, делишься тем же снимком второй раз) — тогда
            // добавляем суффикс: молча перезаписывать чужое нельзя, а падать с ошибкой глупо
            var attemptName = name
            var uploaded = false
            var lastError: Exception? = null
            for (attempt in 0 until 3) {
                val file = LocalFile(attemptName, tmp.absolutePath, attemptName, tmp.length(), tmp.lastModified())
                try {
                    Uploader(app.api).upload(
                        folderId = folderId,
                        file = file,
                        sha256 = sha,
                        replace = false,
                        expectedSha256 = null,
                        uploadIdFromQueue = null,
                        onSession = {},
                        onProgress = { sent, total ->
                            val part = if (total > 0) sent.toFloat() / total else 1f
                            onProgress((index + part) / uris.size)
                        },
                    )
                    uploaded = true
                    break
                } catch (e: ru.cloudly.sync.net.ApiException) {
                    lastError = e
                    if (!(e.message ?: "").contains("already exists") && e.code != "conflict") throw e
                    val dot = name.lastIndexOf('.')
                    attemptName = if (dot > 0) {
                        "${name.substring(0, dot)} (${attempt + 2})${name.substring(dot)}"
                    } else {
                        "$name (${attempt + 2})"
                    }
                }
            }
            if (!uploaded) throw lastError ?: IllegalStateException("не загрузилось")
            done += 1
        } catch (e: Exception) {
            errors.add("$name: ${e.message}")
        } finally {
            tmp.delete()
        }
    }
    onProgress(1f)
    return ShareResult(
        text = if (errors.isEmpty()) "загружено: $done из ${uris.size}" else "загружено: $done из ${uris.size}",
        failed = errors,
        cancelled = false,
    )
}

/**
 * Имя файла от чужого приложения: только базовое имя, без разделителей и «..»,
 * с ограничением длины — иначе получился бы выход за пределы каталога кэша.
 */
private fun safeName(raw: String): String {
    val base = raw.substringAfterLast('/').substringAfterLast('\\').trim().trimStart('.')
    val cleaned = base.replace(Regex("[\\u0000-\\u001f]"), "_")
    return when {
        cleaned.isEmpty() -> "shared-${System.currentTimeMillis()}"
        cleaned.length > 200 -> cleaned.take(200)
        else -> cleaned
    }
}

private fun displayName(app: App, uri: Uri): String? = runCatching {
    app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    }
}.getOrNull()
