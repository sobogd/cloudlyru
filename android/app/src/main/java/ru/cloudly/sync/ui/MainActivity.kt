package ru.cloudly.sync.ui

import android.Manifest
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.AppRelease
import ru.cloudly.sync.update.Updater
import ru.cloudly.sync.work.SyncService
import java.io.File

/** Снимок состояния для интерфейса: читается одним заходом в базу, вне главного потока. */
private data class Snapshot(
    val lastRun: String = "",
    val lastError: String = "",
    val pending: Int = 0,
    val failed: List<Db.Op> = emptyList(),
)

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
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val scope = rememberCoroutineScope()

    var serverUrl by remember { mutableStateOf(app.prefs.serverUrl) }
    var token by remember { mutableStateOf(app.prefs.token) }
    var login by remember { mutableStateOf("admin") }
    var password by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var checkResult by remember { mutableStateOf("") }
    var allFiles by remember { mutableStateOf(hasAllFilesAccess()) }
    var showAdd by remember { mutableStateOf(false) }
    var showFree by remember { mutableStateOf(false) }
    var relay by remember { mutableStateOf(app.engine().relayMode()) }
    var showToken by remember { mutableStateOf(false) }
    // обновление приложения: что нашлось на сервере и что с этим происходит прямо сейчас
    var update by remember { mutableStateOf<AppRelease?>(null) }
    var updateNote by remember { mutableStateOf("") }
    var updating by remember { mutableStateOf(false) }
    val myVersion = remember { Updater.currentVersionCode(context) }
    val myVersionName = remember { Updater.currentVersionName(context) }
    // тик обновления: карточки пересчитывают счётчики по нему, иначе цифры «залипают»
    var tick by remember { mutableStateOf(0) }
    var snap by remember { mutableStateOf(Snapshot()) }
    val jobs = remember { mutableStateListOf<Db.Job>() }

    suspend fun readJobs() = withContext(Dispatchers.IO) { app.db.jobs() }

    fun readSnapshot(): Snapshot = Snapshot(
        lastRun = app.db.kv("last_run_stats").orEmpty(),
        lastError = app.db.kv("last_run_error").orEmpty() + app.db.kv("auth_error").orEmpty(),
        pending = app.db.opCount(),
        failed = app.db.failedOps(5),
    )

    LaunchedEffect(Unit) {
        // база читается вне главного потока: на большой библиотеке иначе подвисает интерфейс
        jobs.clear()
        jobs.addAll(readJobs())
        snap = withContext(Dispatchers.IO) { readSnapshot() }
    }
    LaunchedEffect(Unit) {
        while (true) {
            delay(3000)
            snap = withContext(Dispatchers.IO) { readSnapshot() }
            relay = withContext(Dispatchers.IO) { app.engine().relayMode() }
            tick += 1
        }
    }

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }

    LaunchedEffect(Unit) {
        // без этого разрешения единственный канал сообщить о проблемах молчит
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    /**
     * Проверка версии на сервере. Экран ничего не качает сам: адрес сборки приходит
     * с сервера (постоянная ссылка /apk), поэтому отдельный «файл для скачивания»
     * искать и обновлять не нужно.
     */
    fun checkForUpdate(explicit: Boolean) {
        if (explicit) updateNote = "проверяю версию…"
        scope.launch {
            val found = withContext(Dispatchers.IO) { runCatching { app.api.latestApp() } }
            found.fold(
                onSuccess = { release ->
                    update = release.takeIf { it.versionCode > myVersion }
                    if (explicit) {
                        updateNote = if (update == null) {
                            "установлена последняя версия: $myVersionName ($myVersion)"
                        } else {
                            ""
                        }
                    }
                },
                onFailure = { if (explicit) updateNote = "не удалось проверить обновление: ${hint(it)}" },
            )
        }
    }

    // На старте проверяем молча: вышла новая сборка — о ней видно на экране, обновиться
    // можно одной кнопкой вместо похода в браузер и ручной установки файла.
    LaunchedEffect(Unit) { checkForUpdate(explicit = false) }

    if (showFree) {
        FreeSpaceScreen(app = app, onBack = { showFree = false })
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
                "Автозагрузка папок телефона в облако. Файлы только добавляются: приложение ничего " +
                    "не удаляет и не перезаписывает ни на телефоне, ни в облаке.",
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))

            if (!app.prefs.secure) {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Токен хранится без шифрования", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Системное хранилище ключей недоступно, поэтому токен лежит в обычных настройках " +
                                "приложения. Полный доступ к облаку в этом случае защищён только правами Android " +
                                "на файлы приложения.",
                            fontSize = 12.sp,
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
            if (!allFiles) {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Нужен доступ ко всем файлам", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Без него не видно корень Download и произвольные папки. Приложение личное, " +
                                "поставляется APK-ом.",
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
                // токен даёт полный доступ к облаку: не показываем его на экране без спроса
                visualTransformation = if (showToken) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    TextButton(onClick = { showToken = !showToken }) {
                        Text(if (showToken) "скрыть" else "показать", fontSize = 12.sp)
                    }
                },
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
                visualTransformation = PasswordVisualTransformation(),
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
                                    "android-${Build.MODEL}",
                                )
                                app.prefs.token = fresh
                                token = fresh
                                password = ""
                                "токен выпущен и сохранён"
                            }.getOrElse { hint(it) }
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
                            runCatching { "подключено: ${app.api.me()}" }.getOrElse { hint(it) }
                        }
                    }
                }) { Text("Проверить токен") }
                OutlinedButton(onClick = {
                    app.prefs.serverUrl = serverUrl
                    app.prefs.token = token
                    checkResult = "диагностика…"
                    scope.launch {
                        checkResult = withContext(Dispatchers.IO) {
                            app.api.diagnose() + "\n" + app.api.storageHostReachable()
                        }
                    }
                }) { Text("Диагностика сети") }
            }
            if (checkResult.isNotEmpty()) Text(checkResult, fontSize = 12.sp)

            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = !updating, onClick = { checkForUpdate(explicit = true) }) {
                    Text(if (updating) "…" else "Проверить обновление")
                }
                Text("версия $myVersionName", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (updateNote.isNotEmpty()) Text(updateNote, fontSize = 12.sp)
            update?.let { release ->
                Spacer(Modifier.height(8.dp))
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Доступна версия ${release.versionName}", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Установлена $myVersionName. Сборка скачается сама, дальше система спросит " +
                                "подтверждение установки — это единственное нажатие, которое остаётся.",
                            fontSize = 12.sp,
                        )
                        Spacer(Modifier.height(8.dp))
                        Button(
                            enabled = !updating,
                            onClick = {
                                if (!Updater.canInstall(context)) {
                                    updateNote = "разрешите установку приложений из этого источника " +
                                        "и нажмите «Обновить» ещё раз"
                                    Updater.openInstallSettings(context)
                                    return@Button
                                }
                                updating = true
                                updateNote = "скачиваю ${release.versionName}…"
                                scope.launch {
                                    val result = withContext(Dispatchers.IO) {
                                        runCatching { Updater.download(context, release) }
                                    }
                                    updating = false
                                    result.fold(
                                        onSuccess = { apk ->
                                            updateNote = "скачано — подтвердите установку"
                                            runCatching { Updater.install(context, apk) }
                                                .onFailure { updateNote = "установщик не открылся: ${hint(it)}" }
                                        },
                                        onFailure = { updateNote = "не удалось скачать сборку: ${hint(it)}" },
                                    )
                                }
                            },
                        ) { Text(if (updating) "обновляю…" else "Обновить") }
                    }
                }
            }

            if (relay) {
                Spacer(Modifier.height(6.dp))
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Загрузка идёт через сервер", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Хранилище напрямую с телефона недоступно (DNS, блокировщик или VPN), поэтому " +
                                "файлы идут через сервер. Это медленнее, но работает.",
                            fontSize = 12.sp,
                        )
                        Spacer(Modifier.height(6.dp))
                        OutlinedButton(onClick = {
                            app.engine().resetRelayMode()
                            relay = false
                            checkResult = "попробую прямое подключение к хранилищу"
                        }) { Text("Вернуть прямую загрузку", fontSize = 12.sp) }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            Text("Папки", fontWeight = FontWeight.SemiBold)
            if (jobs.isEmpty()) {
                Text(
                    "Пока ни одной папки. «Добавить папку» — выберите папку на телефоне и папку в облаке.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            LazyColumn(modifier = Modifier.height(if (jobs.isEmpty()) 1.dp else 260.dp)) {
                items(jobs, key = { it.id }) { job ->
                    JobCard(
                        job = job,
                        app = app,
                        tick = tick,
                        onChange = { scope.launch { jobs.clear(); jobs.addAll(readJobs()) } },
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { SyncService.start(context) }) { Text("Синхронизировать сейчас") }
                OutlinedButton(onClick = { SyncService.stop(context) }) { Text("Стоп") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { showFree = true }) { Text("Освободить место") }
            }
            Spacer(Modifier.height(12.dp))
            Text("В очереди: ${snap.pending}", fontSize = 13.sp)
            if (snap.failed.isNotEmpty()) {
                Text("Не прошло:", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                snap.failed.forEach { op ->
                    Text(
                        "• ${op.relPath}: ${op.lastError}",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                OutlinedButton(onClick = {
                    app.db.resetOps()
                    SyncService.start(context)
                }) { Text("Повторить очередь", fontSize = 12.sp) }
            }
            if (snap.lastRun.isNotEmpty()) Text("Прошлый проход: ${snap.lastRun}", fontSize = 13.sp)
            if (snap.lastError.isNotEmpty()) {
                Text("Ошибка: ${snap.lastError}", fontSize = 13.sp, color = MaterialTheme.colorScheme.error)
            }
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
                scope.launch { jobs.clear(); jobs.addAll(readJobs()) }
                // задача добавлена — сразу запускаем проход, иначе пользователь видит пустой список
                // и думает, что приложение ничего не нашло
                SyncService.start(context)
            },
        )
    }
}

/** Понятная подсказка вместо «cleartext not permitted» и прочих технических текстов. */
private fun hint(e: Throwable): String {
    val text = e.message.orEmpty()
    return when {
        text.contains("cleartext", ignoreCase = true) ->
            "ошибка: сервер по http — нужен https-адрес"
        text.contains("Unable to resolve host", ignoreCase = true) ->
            "сеть недоступна: имя хоста не разрешается. Проверьте мобильные данные для приложения " +
                "и «Экономию трафика», либо включите Wi-Fi"
        text.contains("Failed to connect", ignoreCase = true) || text.contains("timeout", ignoreCase = true) ->
            "сервер не ответил: проверьте адрес и сеть"
        else -> "ошибка: $text"
    }
}

/** Счётчики задачи: читаются из базы отдельным заходом, чтобы не трогать диск в главном потоке. */
private data class JobInfo(
    val uploaded: Int = 0,
    val note: String = "",
    val progress: String = "",
    val stat: String = "",
    val lastAt: Long = 0,
    val queued: Int = 0,
)

@Composable
private fun JobCard(job: Db.Job, app: App, tick: Int, onChange: () -> Unit) {
    var info by remember(job.id) { mutableStateOf(JobInfo()) }
    LaunchedEffect(job.id, tick) {
        info = withContext(Dispatchers.IO) {
            JobInfo(
                uploaded = app.db.uploadedCount(job.id),
                note = app.db.kv("job_note:${job.id}").orEmpty(),
                progress = app.db.kv("job_progress:${job.id}").orEmpty(),
                stat = app.db.kv("job_stat:${job.id}").orEmpty(),
                lastAt = (app.db.kv("job_at:${job.id}") ?: "0").toLongOrNull() ?: 0L,
                queued = app.db.opSummary().ready,
            )
        }
    }

    Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Column(Modifier.padding(12.dp)) {
            Text(job.sourceDir, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(
                "→ ${job.targetPath}  ·  ${if (job.zone == "PHOTOS") "Фото" else "Файлы"}" +
                    if (job.includeSubfolders) "  ·  с подпапками" else "",
                fontSize = 12.sp,
            )
            Text("выгружено файлов: ${info.uploaded}", fontSize = 12.sp)
            if (info.progress.isNotEmpty()) Text(info.progress, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            if (info.lastAt > 0) {
                val mins = (System.currentTimeMillis() - info.lastAt) / 60_000
                Text(
                    if (mins < 1) "проход был только что" else "проход был $mins мин назад",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (info.stat.isNotEmpty()) {
                Text("проход: ${info.stat}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (info.queued > 0) {
                Text("в очереди ${info.queued}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (info.note.isNotEmpty()) {
                Text(info.note, fontSize = 11.sp, color = MaterialTheme.colorScheme.error)
            }
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
                OutlinedButton(onClick = {
                    app.db.deleteJob(job.id)
                    onChange()
                }) { Text("Убрать из списка", fontSize = 12.sp) }
            }
        }
    }
}

@Composable
private fun AddJobDialog(app: App, onDismiss: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var dir by remember { mutableStateOf("") }
    var zone by remember { mutableStateOf("PHOTOS") }
    var remoteId by remember { mutableStateOf("") }
    var remoteCrumbs by remember { mutableStateOf(listOf<Pair<String, String>>()) }
    var remotePath by remember { mutableStateOf("") }
    var includeSubfolders by remember { mutableStateOf(true) }
    var wifiOnly by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var pickLocal by remember { mutableStateOf(false) }
    var pickRemote by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Новая папка") },
        text = {
            Column {
                Text("Что загружать", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                OutlinedButton(
                    onClick = { pickLocal = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (dir.isBlank()) "Выбрать папку на телефоне" else dir, fontSize = 13.sp)
                }
                if (dir.isNotBlank()) {
                    val exists = File(dir).isDirectory
                    val fileCount = remember(dir) { File(dir).listFiles()?.count { it.isFile } ?: 0 }
                    Text(
                        if (exists) "файлов в папке: $fileCount" else "папки больше нет — выберите заново",
                        fontSize = 11.sp,
                        color = if (exists) MaterialTheme.colorScheme.onSurfaceVariant
                        else MaterialTheme.colorScheme.error,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = includeSubfolders, onCheckedChange = { includeSubfolders = it })
                    Text("включая подпапки", fontSize = 13.sp)
                }
                Spacer(Modifier.height(10.dp))

                Text("Куда в облаке", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                OutlinedButton(
                    onClick = { pickRemote = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        if (remoteId.isBlank()) "Выбрать папку в облаке" else "Главная / $remotePath",
                        fontSize = 13.sp,
                    )
                }
                Spacer(Modifier.height(10.dp))

                Text("Как хранить", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = { zone = "PHOTOS" }, modifier = Modifier.fillMaxWidth(0.5f)) {
                        Text(if (zone == "PHOTOS") "● Фото" else "Фото", fontSize = 13.sp)
                    }
                    OutlinedButton(onClick = { zone = "FILES" }, modifier = Modifier.fillMaxWidth()) {
                        Text(if (zone == "FILES") "● Файлы" else "Файлы", fontSize = 13.sp)
                    }
                }
                Text(
                    if (zone == "PHOTOS") "Фото и видео: сервер сделает превью и покажет в таймлайне. " +
                        "Файлы ложатся одной папкой, без структуры подпапок."
                    else "Как есть: обычное хранилище с подпапками",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = wifiOnly, onCheckedChange = { wifiOnly = it })
                    Text("загружать только по Wi-Fi", fontSize = 13.sp)
                }
                if (error.isNotEmpty()) Text(error, fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy && dir.isNotBlank() && remoteId.isNotBlank(),
                onClick = {
                    busy = true
                    error = ""
                    scope.launch {
                        val message = withContext(Dispatchers.IO) {
                            runCatching {
                                app.db.addJob(
                                    dir.trimEnd('/'),
                                    remoteId,
                                    remotePath.ifBlank { "Главная" },
                                    zone,
                                    wifiOnly,
                                    includeSubfolders,
                                )
                                "добавлено: $dir → $remotePath"
                            }.getOrElse { "не получилось: ${it.message}" }
                        }
                        busy = false
                        if (message.startsWith("добавлено")) onCreated(message) else error = message
                    }
                },
            ) { Text(if (busy) "…" else "Добавить") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )

    if (pickLocal) {
        LocalFolderPicker(
            initial = dir,
            onDismiss = { pickLocal = false },
            onPicked = { picked ->
                dir = picked
                pickLocal = false
            },
        )
    }
    if (pickRemote) {
        CloudFolderPicker(
            initialFolderId = remoteId.ifBlank { null },
            initialPath = remoteCrumbs,
            onDismiss = { pickRemote = false },
            onPicked = { id, path, crumbs ->
                remoteId = id
                remotePath = path
                remoteCrumbs = crumbs
                pickRemote = false
            },
        )
    }
}
