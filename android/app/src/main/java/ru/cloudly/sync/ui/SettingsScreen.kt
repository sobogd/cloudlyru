package ru.cloudly.sync.ui

import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.net.AppRelease
import ru.cloudly.sync.update.Updater

/**
 * Настройки: подключение к серверу, папки разделов и обновление приложения.
 * Форма входа показывается здесь сама, когда токена нет — отдельного пункта «войти» нет.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onOpenFolders: (Section) -> Unit) {
    val context = LocalContext.current
    val app = remember { App.of(context) }
    val selection = remember { Selection(context) }
    val scope = rememberCoroutineScope()

    var serverUrl by remember { mutableStateOf(app.prefs.serverUrl) }
    var login by remember { mutableStateOf("admin") }
    var password by remember { mutableStateOf("") }
    var token by remember { mutableStateOf(app.prefs.token) }
    var account by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var showToken by remember { mutableStateOf(false) }
    var tokenField by remember { mutableStateOf(false) }
    var addressField by remember { mutableStateOf(false) }
    var access by remember { mutableStateOf(hasAllFilesAccess()) }
    var update by remember { mutableStateOf<AppRelease?>(null) }
    var updateNote by remember { mutableStateOf("") }
    var updating by remember { mutableStateOf(false) }
    val versionName = remember { Updater.currentVersionName(context) }
    val versionCode = remember { Updater.currentVersionCode(context) }
    val fileFolders = remember { selection.paths(Section.FILES).size }
    val photoFolders = remember { selection.paths(Section.PHOTOS).size }

    // доступ выдаётся на системном экране: без опроса галочка не появилась бы после возврата
    LaunchedEffect(Unit) {
        while (true) {
            access = hasAllFilesAccess()
            delay(1500)
        }
    }

    LaunchedEffect(token) {
        if (token.isBlank()) {
            account = ""
            return@LaunchedEffect
        }
        account = withContext(Dispatchers.IO) { runCatching { app.api.me() }.getOrElse { "" } }
    }

    fun signIn() {
        app.prefs.serverUrl = serverUrl
        busy = true
        status = "вхожу…"
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { app.api.loginAndCreateToken(login.trim(), password, "android-${Build.MODEL}") }
            }
            busy = false
            result.fold(
                onSuccess = { fresh ->
                    app.prefs.token = fresh
                    token = fresh
                    password = ""
                    status = "вошли: токен сохранён на телефоне"
                },
                onFailure = { status = hint(it) },
            )
        }
    }

    fun checkConnection() {
        app.prefs.serverUrl = serverUrl
        status = "проверяю…"
        scope.launch {
            status = withContext(Dispatchers.IO) {
                runCatching { "подключено: ${app.api.me()}" }.getOrElse { hint(it) }
            }
        }
    }

    fun checkForUpdate() {
        updateNote = "проверяю версию…"
        scope.launch {
            val found = withContext(Dispatchers.IO) { runCatching { app.api.latestApp() } }
            found.fold(
                onSuccess = { release ->
                    update = release.takeIf { it.versionCode > versionCode }
                    updateNote = if (update == null) "установлена последняя версия" else ""
                },
                onFailure = { updateNote = "не удалось проверить: ${hint(it)}" },
            )
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Настройки", fontSize = 18.sp, fontWeight = FontWeight.SemiBold) })
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!access) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Нужен доступ ко всем файлам", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Без него не видно ни дерева папок, ни содержимого разделов.",
                            fontSize = 12.sp,
                        )
                        Button(onClick = { openAllFilesSettings(context) }) { Text("Открыть настройки") }
                    }
                }
            }

            if (!app.prefs.secure) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Токен хранится без шифрования", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Системное хранилище ключей недоступно, поэтому токен лежит в обычных " +
                                "настройках приложения.",
                            fontSize = 12.sp,
                        )
                    }
                }
            }

            Text("Сервер", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (token.isBlank()) {
                        OutlinedTextField(
                            value = serverUrl,
                            onValueChange = { serverUrl = it },
                            label = { Text("Адрес") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = login,
                            onValueChange = { login = it },
                            label = { Text("Логин") },
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
                        Button(enabled = !busy, onClick = { signIn() }) { Text("Войти") }
                    } else {
                        Text(
                            if (account.isBlank()) "подключено" else "подключено: $account",
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp,
                        )
                        Text(app.prefs.serverUrl, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (addressField) {
                            OutlinedTextField(
                                value = serverUrl,
                                onValueChange = { serverUrl = it },
                                label = { Text("Адрес") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedButton(onClick = {
                                app.prefs.serverUrl = serverUrl
                                serverUrl = app.prefs.serverUrl
                                addressField = false
                                checkConnection()
                            }) { Text("Сохранить адрес") }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { checkConnection() }) { Text("Проверить подключение") }
                            OutlinedButton(onClick = {
                                app.prefs.token = ""
                                token = ""
                                status = "вышли: токен удалён с телефона"
                            }) { Text("Выйти") }
                        }
                        TextButton(onClick = { tokenField = !tokenField }) {
                            Text(if (tokenField) "скрыть замену токена" else "заменить токен вручную", fontSize = 12.sp)
                        }
                        TextButton(onClick = { addressField = !addressField }) {
                            Text(if (addressField) "скрыть адрес" else "изменить адрес сервера", fontSize = 12.sp)
                        }
                        if (tokenField) {
                            OutlinedTextField(
                                value = token,
                                onValueChange = { token = it; app.prefs.token = it },
                                label = { Text("Токен устройства (ApiToken)") },
                                singleLine = true,
                                visualTransformation = if (showToken) {
                                    VisualTransformation.None
                                } else {
                                    PasswordVisualTransformation()
                                },
                                trailingIcon = {
                                    TextButton(onClick = { showToken = !showToken }) {
                                        Text(if (showToken) "скрыть" else "показать", fontSize = 12.sp)
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    if (status.isNotEmpty()) {
                        Text(status, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                    }
                }
            }

            Text("Папки", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Card(Modifier.fillMaxWidth()) {
                Column {
                    SettingRow(
                        icon = Icons.Filled.Folder,
                        title = "Папки для файлов",
                        subtitle = if (fileFolders == 0) "не выбраны" else "выбрано: $fileFolders",
                        onClick = { onOpenFolders(Section.FILES) },
                    )
                    SettingRow(
                        icon = Icons.Filled.PhotoLibrary,
                        title = "Папки для фото и видео",
                        subtitle = if (photoFolders == 0) "не выбраны" else "выбрано: $photoFolders",
                        onClick = { onOpenFolders(Section.PHOTOS) },
                    )
                }
            }

            Text("Приложение", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("версия $versionName ($versionCode)", fontSize = 12.sp)
                    OutlinedButton(enabled = !updating, onClick = { checkForUpdate() }) {
                        Text("Проверить обновление")
                    }
                    if (updateNote.isNotEmpty()) Text(updateNote, fontSize = 12.sp)
                    update?.let { release ->
                        Text("Доступна версия ${release.versionName}", fontWeight = FontWeight.SemiBold)
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
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun SettingRow(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(title, fontSize = 15.sp)
            Text(subtitle, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null)
    }
}
