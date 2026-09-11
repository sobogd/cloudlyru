package ru.cloudly.sync.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings

/** Понятная подсказка вместо «cleartext not permitted» и прочих технических текстов. */
internal fun hint(e: Throwable): String {
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

/** Полный доступ к файлам — то, ради чего приложение ставится APK-ом, а не из Play. */
internal fun hasAllFilesAccess(): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

/** Экран настроек Android, где выдаётся доступ ко всем файлам. */
internal fun openAllFilesSettings(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
    runCatching {
        context.startActivity(
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                .setData(Uri.parse("package:${context.packageName}")),
        )
    }
}
