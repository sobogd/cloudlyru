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
    private val prefs: SharedPreferences = runCatching {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context,
            "cloudly-secure",
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        ) as SharedPreferences
    }.getOrElse {
        // Keystore на некоторых прошивках капризен; без хранилища приложение бесполезно,
        // поэтому деградируем до обычных настроек, но не падаем
        context.getSharedPreferences("cloudly-plain", Context.MODE_PRIVATE)
    }

    var serverUrl: String
        get() = prefs.getString(KEY_URL, DEFAULT_URL) ?: DEFAULT_URL
        set(value) {
            val normalized = value.trim().trimEnd('/')
            prefs.edit().putString(KEY_URL, normalized).apply()
        }

    var token: String
        get() = prefs.getString(KEY_TOKEN, "") ?: ""
        set(value) = prefs.edit().putString(KEY_TOKEN, value.trim()).apply()

    /** Токен для этого прогона, чтобы не читать шифрованное хранилище на каждый запрос. */
    val configured: Boolean get() = serverUrl.isNotBlank() && token.isNotBlank()

    companion object {
        const val DEFAULT_URL = "https://files.iq-factura.com"
        private const val KEY_URL = "server_url"
        private const val KEY_TOKEN = "api_token"
    }
}
