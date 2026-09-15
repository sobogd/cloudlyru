package ru.cloudly.cloudly_flutter

import android.content.Context

/**
 * Что службе нужно знать до старта движка: заведено ли задание и где точка входа.
 *
 * Ключи пишет Dart (`BackgroundSync.register`), а лежат они в обычных настройках Flutter —
 * файл `FlutterSharedPreferences`, ключи с префиксом `flutter.`. Читать чужой файл настроек
 * приходится потому, что к моменту запуска задания движка приложения уже нет и спросить
 * его не у кого.
 *
 * Токена устройства здесь нет и быть не должно: он в шифрованном хранилище, и фоновый
 * изолят достаёт его сам.
 */
object BackgroundSettings {

    private const val FILE = "FlutterSharedPreferences"
    private const val KEY_ENABLED = "flutter.syncbg_enabled"
    private const val KEY_CALLBACK = "flutter.syncbg_callback"

    fun enabled(context: Context): Boolean =
        runCatching { prefs(context).getBoolean(KEY_ENABLED, false) }.getOrDefault(false)

    /**
     * Handle точки входа фонового изолята. Ноль и меньше — «не заведено»: тогда движок
     * поднимать нечего, и задание молча заканчивается.
     *
     * Int читается вторым заходом на случай, если хранилище положило число как Int: тип
     * значения зависит от того, чем его писали, а падать из-за этого задание не должно.
     */
    fun callbackHandle(context: Context): Long {
        val raw = runCatching { prefs(context).getLong(KEY_CALLBACK, -1L) }.getOrNull()
        if (raw != null && raw > 0L) return raw
        return runCatching { prefs(context).getInt(KEY_CALLBACK, -1).toLong() }.getOrDefault(-1L)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}
