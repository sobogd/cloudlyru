package ru.cloudly.sync.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Настройки подключения. Токен (ApiToken, он же app-password) лежит в шифрованном хранилище:
 * он даёт полный доступ к облаку, а телефон — потеряемая вещь.
 */
class Prefs(context: Context) {
    /** false — шифрованное хранилище не поднялось, токен лежит в обычных настройках. */
    val secure: Boolean

    private val prefs: SharedPreferences

    init {
        val encrypted = runCatching {
            val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            EncryptedSharedPreferences.create(
                context,
                "cloudly-secure",
                key,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            ) as SharedPreferences
        }.getOrNull()
        // Keystore на некоторых прошивках капризен; без хранилища приложение бесполезно,
        // поэтому деградируем до обычных настроек, но не падаем — и говорим об этом в интерфейсе
        secure = encrypted != null
        prefs = encrypted ?: context.getSharedPreferences("cloudly-plain", Context.MODE_PRIVATE)
    }

    var serverUrl: String
        get() = prefs.getString(KEY_URL, DEFAULT_URL) ?: DEFAULT_URL
        set(value) {
            var normalized = value.trim().trimEnd('/')
            // OkHttp требует схему: «files.example.com» без неё просто не соберётся в URL
            if (normalized.isNotEmpty() && !normalized.contains("://")) normalized = "https://$normalized"
            prefs.edit().putString(KEY_URL, normalized).apply()
        }

    var token: String
        get() = prefs.getString(KEY_TOKEN, "") ?: ""
        set(value) = prefs.edit().putString(KEY_TOKEN, value.trim()).apply()

    /** Токен для этого прогона, чтобы не читать шифрованное хранилище на каждый запрос. */
    val configured: Boolean get() = serverUrl.isNotBlank() && token.isNotBlank()

    /** Хост хранилища из последней presigned-ссылки: показываем его в диагностике. */
    var lastS3Host: String?
        get() = prefs.getString(KEY_S3_HOST, null)
        set(value) = prefs.edit().putString(KEY_S3_HOST, value).apply()

    /**
     * Системные папки сервера. Спрашиваются один раз и запоминаются: без них нельзя
     * наполнить очередь, а очередь должна собираться и без сети (выгрузка всё равно ручная).
     */
    var phoneFolderId: String
        get() = prefs.getString(KEY_PHONE_FOLDER, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_PHONE_FOLDER, value).apply()

    var photoFolderId: String
        get() = prefs.getString(KEY_PHOTO_FOLDER, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_PHOTO_FOLDER, value).apply()

    companion object {
        const val DEFAULT_URL = "https://files.iq-factura.com"
        private const val KEY_URL = "server_url"
        private const val KEY_TOKEN = "api_token"
        private const val KEY_S3_HOST = "last_s3_host"
        private const val KEY_PHONE_FOLDER = "phone_folder_id"
        private const val KEY_PHOTO_FOLDER = "photo_folder_id"
    }
}
