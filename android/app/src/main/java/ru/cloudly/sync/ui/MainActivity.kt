package ru.cloudly.sync.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.work.SyncService
import ru.cloudly.sync.work.VerifyWorker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) { Screen() }
            }
        }
    }
}

/** Полный доступ к файлам — то, ради чего приложение ставится APK-ом, а не из Play. */
private fun hasAllFilesAccess(): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

@Composable
private fun Screen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val app = remember { App.of(context) }
    val scope = rememberCoroutineScope()

    var serverUrl by remember { mutableStateOf(app.prefs.serverUrl) }
    var token by remember { mutableStateOf(app.prefs.token) }
    var login by remember { mutableStateOf("admin") }
    var password by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var checkResult by remember { mutableStateOf("") }
    var lastRun by remember { mutableStateOf(app.db.kv("last_run_stats").orEmpty()) }
    var lastError by remember { mutableStateOf(app.db.kv("last_run_error").orEmpty()) }
    var lastVerify by remember { mutableStateOf(app.db.kv("last_verify_stats").orEmpty()) }
    var pending by remember { mutableStateOf(app.db.ops().size) }
    var allFiles by remember { mutableStateOf(hasAllFilesAccess()) }
    var showAdd by remember { mutableStateOf(false) }
    var openJob by remember { mutableStateOf<Long?>(null) }
    val jobs = remember { mutableStateListOf<Db.Job>() }

    fun reload() {
        jobs.clear()
        jobs.addAll(app.db.jobs())
        lastRun = app.db.kv("last_run_stats").orEmpty()
        lastError = app.db.kv("last_run_error").orEmpty()
        lastVerify = app.db.kv("last_verify_stats").orEmpty()
        pending = app.db.ops().size
        allFiles = hasAllFilesAccess()
    }

    LaunchedEffect(Unit) { reload() }
    LaunchedEffect(Unit) {
        while (true) {
            delay(2000)
            lastRun = app.db.kv("last_run_stats").orEmpty()
            lastError = app.db.kv("last_run_error").orEmpty()
            lastVerify = app.db.kv("last_verify_stats").orEmpty()
            pending = app.db.ops().size
        }
    }

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }

    val open = openJob?.let { id -> jobs.firstOrNull { it.id == id } }
    if (open != null) {
        JobFilesScreen(job = open, app = app, onBack = { openJob = null })
        return
    }

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .padding(16.dp)
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            Text("CloudlyRu Sync", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(
                "Служебное приложение: держит выбранные папки телефона в облаке",
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))

            if (!allFiles) {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Нужен доступ ко всем файлам", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Без него не видно корень Download и произвольные папки. Приложение личное, поставляется APK-ом.",
                            fontSize = 12.sp,
                        )
                        Spacer(Modifier.height(8.dp))
                        Button(onClick = {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                context.startActivity(
                                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                        .setData(Uri.parse("package:${context.packageName}")),
                                )
                            }
                        }) { Text("Открыть настройки") }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }) { Text("Уведомления") }
                OutlinedButton(onClick = {
                    // просим не убивать приложение: на агрессивных прошивках фоновые задачи иначе не идут
                    context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }) { Text("Батарея") }
            }
            Spacer(Modifier.height(12.dp))

            Text("Сервер", fontWeight = FontWeight.SemiBold)
            OutlinedTextField(
                value = serverUrl,
                onValueChange = { serverUrl = it },
                label = { Text("Адрес") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("Токен устройства (ApiToken)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = login,
                onValueChange = { login = it },
                label = { Text("Логин владельца") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = { Text("Пароль (не сохраняется)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    app.prefs.serverUrl = serverUrl
                    checkResult = "вхожу…"
                    scope.launch {
                        checkResult = withContext(Dispatchers.IO) {
                            runCatching {
                                val fresh = app.api.loginAndCreateToken(
                                    login.trim(),
                                    password,
                                    "android-${android.os.Build.MODEL}",
                                )
                                app.prefs.token = fresh
                                token = fresh
                                password = ""
                                "токен выпущен и сохранён"
                            }.getOrElse { "ошибка: ${it.message}" }
                        }
                    }
                }) { Text("Войти и создать токен") }
                OutlinedButton(onClick = { showAdd = true }) { Text("Добавить папку") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    app.prefs.serverUrl = serverUrl
                    app.prefs.token = token
                    checkResult = "проверяю…"
                    scope.launch {
                        checkResult = withContext(Dispatchers.IO) {
                            runCatching { "подключено: ${app.api.me()}" }.getOrElse { "ошибка: ${it.message}" }
                        }
                    }
                }) { Text("Проверить токен") }
            }
            if (checkResult.isNotEmpty()) Text(checkResult, fontSize = 12.sp)

            Spacer(Modifier.height(16.dp))
            Text("Папки", fontWeight = FontWeight.SemiBold)
            LazyColumn(modifier = Modifier.height(if (jobs.isEmpty()) 1.dp else 240.dp)) {
                items(jobs, key = { it.id }) { job ->
                    JobCard(job, app, onChange = { reload() }, onOpenFiles = { openJob = job.id })
                }
            }

            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { SyncService.start(context) }) { Text("Синхронизировать сейчас") }
                OutlinedButton(onClick = { SyncService.stop(context) }) { Text("Стоп") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    scope.launch {
                        status = "сверяю…"
                        val text = withContext(Dispatchers.IO) {
                            runCatching {
                                val st = VerifyWorker.verify(app)
                                "сверка: проверено ${st.checked}, изменилось ${st.changed}, нет на сервере ${st.missing}, ошибок ${st.errors}"
                            }.getOrElse { "сверка не прошла: ${it.message}" }
                        }
                        status = text
                        lastVerify = app.db.kv("last_verify_stats").orEmpty()
                    }
                }) { Text("Проверить сейчас") }
            }
            Spacer(Modifier.height(12.dp))
            Text("В очереди: $pending", fontSize = 13.sp)
            val failed = remember(pending) { app.db.failedOps().take(5) }
            if (failed.isNotEmpty()) {
                Text("Не прошло:", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                failed.forEach { op ->
                    Text("• ${op.relPath}: ${op.lastError}", fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
                }
            }
            if (lastRun.isNotEmpty()) Text("Прошлый проход: $lastRun", fontSize = 13.sp)
            if (lastVerify.isNotEmpty()) Text("Сверка: $lastVerify", fontSize = 13.sp)
            if (lastError.isNotEmpty()) Text("Ошибка: $lastError", fontSize = 13.sp, color = MaterialTheme.colorScheme.error)
            status.takeIf { it.isNotEmpty() }?.let { Text(it, fontSize = 12.sp, fontFamily = FontFamily.Monospace) }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showAdd) {
        AddJobDialog(
            app = app,
            onDismiss = { showAdd = false },
            onCreated = { message ->
                status = message
                showAdd = false
                reload()
            },
        )
    }
}

@Composable
private fun JobCard(job: Db.Job, app: App, onChange: () -> Unit, onOpenFiles: () -> Unit) {
    val scope = rememberCoroutineScope()
    var pinned by remember(job.id) { mutableStateOf(false) }
    LaunchedEffect(job.id) {
        pinned = withContext(Dispatchers.IO) { app.engine().folderPinned(job.targetFolderId) }
    }
    Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Column(Modifier.padding(12.dp)) {
            Text(job.sourceDir, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text("→ ${job.targetPath}  ·  ${if (job.zone == "PHOTOS") "Фото" else "Файлы"}", fontSize = 12.sp)
            val counts = app.db.stateCounts(job.id)
            Text(
                "файлов: ${counts.values.sum()}  ·  выгружено ${counts["synced"] ?: 0}  ·  " +
                    "вытеснено ${counts["evicted"] ?: 0}  ·  новых ${counts["new"] ?: 0}",
                fontSize = 12.sp,
            )
            Text(
                if (job.keepDays < 0) "хранение: не удалять (зеркало)"
                else if (job.keepDays == 0) "хранение: удалять сразу после выгрузки"
                else "хранение: ${job.keepDays} дн.",
                fontSize = 12.sp,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(
                    checked = job.enabled,
                    onCheckedChange = {
                        app.db.updateJob(job.id, mapOf("enabled" to if (it) 1 else 0))
                        onChange()
                    },
                )
                Text("включена", fontSize = 12.sp)
                Spacer(Modifier.width(12.dp))
                Switch(
                    checked = job.wifiOnly,
                    onCheckedChange = {
                        app.db.updateJob(job.id, mapOf("wifi_only" to if (it) 1 else 0))
                        onChange()
                    },
                )
                Text("только Wi-Fi", fontSize = 12.sp)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onOpenFiles) { Text("Файлы") }
                OutlinedButton(onClick = {
                    val next = !pinned
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) {
                            runCatching {
                                app.engine().setFolderKeepOffline(job.targetFolderId, next)
                                if (next) SyncService.start(app)
                                true
                            }.getOrDefault(false)
                        }
                        if (ok) pinned = next
                    }
                }) { Text(if (pinned) "● Держать офлайн" else "Держать офлайн") }
                OutlinedButton(onClick = {
                    app.db.deleteJob(job.id)
                    onChange()
                }) { Text("Удалить") }
            }
        }
    }
}

@Composable
private fun AddJobDialog(app: App, onDismiss: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var dir by remember { mutableStateOf("/storage/emulated/0/DCIM/Camera") }
    var zone by remember { mutableStateOf("PHOTOS") }
    var remote by remember { mutableStateOf("Фото/Камера") }
    var keepDays by remember { mutableStateOf(-1) }
    var wifiOnly by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Новая папка") },
        text = {
            Column {
                OutlinedTextField(
                    value = dir,
                    onValueChange = { dir = it },
                    label = { Text("Папка на телефоне") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    if (File(dir).isDirectory) "папка найдена" else "папки нет — проверьте путь",
                    fontSize = 12.sp,
                    color = if (File(dir).isDirectory) MaterialTheme.colorScheme.onSurfaceVariant
                    else MaterialTheme.colorScheme.error,
                )
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = zone == "PHOTOS", onCheckedChange = { zone = if (it) "PHOTOS" else "FILES" })
                    Text(if (zone == "PHOTOS") "Фото (превью и таймлайн)" else "Файлы (как есть)", fontSize = 13.sp)
                }
                OutlinedTextField(
                    value = remote,
                    onValueChange = { remote = it },
                    label = { Text("Папка в облаке") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("Хранить на телефоне", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(-1 to "всегда", 0 to "сразу", 7 to "7 дн", 30 to "30 дн").forEach { (days, label) ->
                        OutlinedButton(onClick = { keepDays = days }) {
                            Text(if (keepDays == days) "• $label" else label, fontSize = 12.sp)
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = wifiOnly, onCheckedChange = { wifiOnly = it })
                    Text("только Wi-Fi", fontSize = 13.sp)
                }
                if (error.isNotEmpty()) Text(error, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(enabled = !busy, onClick = {
                busy = true
                error = ""
                scope.launch {
                    val message = withContext(Dispatchers.IO) {
                        runCatching {
                            val folderId = app.api.ensurePath(remote)
                            app.db.addJob(dir.trimEnd('/'), folderId, remote, zone, keepDays, wifiOnly)
                            "добавлено: $dir → $remote"
                        }.getOrElse { "не получилось: ${it.message}" }
                    }
                    busy = false
                    if (message.startsWith("добавлено")) onCreated(message) else error = message
                }
            }) { Text(if (busy) "…" else "Добавить") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )
}
