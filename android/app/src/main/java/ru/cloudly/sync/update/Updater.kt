package ru.cloudly.sync.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import okhttp3.OkHttpClient
import okhttp3.Request
import ru.cloudly.sync.device.Hasher
import ru.cloudly.sync.net.AppRelease
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Обновление приложения по кнопке: без браузера, поиска файла в «Загрузках» и ручной
 * установки APK. Сборка качается по постоянной ссылке сервера (`/apk`) в кэш, проверяется
 * по размеру и sha256 — и уходит системному установщику.
 *
 * Совсем молча обновиться приложение не может: Android показывает диалог установки, и его
 * надо подтвердить. Тихая установка доступна только системным приложениям и владельцу
 * устройства, поэтому «кнопка → диалог → готово» — это минимум ручных действий, который
 * возможен для APK.
 */
object Updater {
    /** authority FileProvider'а из манифеста: через него установщик читает скачанный APK. */
    const val AUTHORITY = "ru.cloudly.sync.files"

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()

    /** versionCode установленного приложения — с ним сравнивается версия с сервера. */
    fun currentVersionCode(context: Context): Long = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }.getOrElse { 0L }

    fun currentVersionName(context: Context): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
    }.getOrElse { "" }

    /**
     * Скачать сборку и убедиться, что это она. Файл кладём в кэш целиком, только потом
     * отдаём установщику: обрезанный APK он бы отверг с непонятной ошибкой разбора.
     */
    fun download(context: Context, release: AppRelease): File {
        val dir = File(context.cacheDir, "release").apply { mkdirs() }
        val target = File(dir, "cloudlyru-sync-${release.versionCode}.apk")
        val tmp = File(dir, "cloudlyru-sync-${release.versionCode}.apk.part")
        // эта же версия уже скачана и проверена — второй раз те же байты не тянем
        if (target.exists() && release.sha256.isNotBlank() && Hasher.sha256(target) == release.sha256) {
            return target
        }
        // старые сборки в кэше не нужны: телефон не обязан хранить историю APK
        dir.listFiles()?.filter { it != target }?.forEach { it.delete() }

        val response = http.newCall(Request.Builder().url(release.url).build()).execute()
        if (!response.isSuccessful) {
            response.close()
            throw IllegalStateException("по ссылке ${release.url} пришёл HTTP ${response.code}, а не APK")
        }
        response.use { res ->
            val body = res.body ?: throw IllegalStateException("пустой ответ вместо APK")
            body.byteStream().use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, bufferSize = 1 shl 16) }
            }
        }

        if (release.size > 0 && tmp.length() != release.size) {
            tmp.delete()
            throw IllegalStateException("скачано ${tmp.length()} байт вместо ${release.size}")
        }
        if (release.sha256.isNotBlank() && Hasher.sha256(tmp) != release.sha256) {
            tmp.delete()
            throw IllegalStateException("sha256 скачанного не совпал с серверным")
        }
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IllegalStateException("не удалось сохранить скачанный APK")
        }
        return target
    }

    /** Разрешена ли установка APK из этого приложения («неизвестные источники»). */
    fun canInstall(context: Context): Boolean = context.packageManager.canRequestPackageInstalls()

    /** Экран разрешения: без него система откажет в установке. */
    fun openInstallSettings(context: Context) {
        context.startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /** Отдать APK системному установщику — он покажет диалог подтверждения. */
    fun install(context: Context, apk: File) {
        val uri = FileProvider.getUriForFile(context, AUTHORITY, apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
