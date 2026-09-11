package ru.cloudly.sync.queue

import android.content.Context
import ru.cloudly.sync.App
import ru.cloudly.sync.device.DeviceFiles

/**
 * Один заход наполнения очереди, целиком: узнать системные папки сервера (если ещё не знаем),
 * пройти выбранные папки и поставить новое в очередь.
 *
 * Вызывается при старте приложения, после изменения выбора папок, при открытии раздела
 * «Очередь» и по кнопке «Обновить». Ничего не выгружает: запуск файлов — ручной.
 */
object QueueRefresher {

    suspend fun refresh(context: Context, onProgress: (String) -> Unit = {}): QueueBuilder.Result {
        val app = App.of(context)
        val prefs = app.prefs

        // системные папки сервера спрашиваем один раз: без них очередь некуда направить,
        // но и наполнять её при отсутствии сети смысла нет
        if (prefs.photoFolderId.isBlank() && prefs.token.isNotBlank()) {
            onProgress("спрашиваю системные папки…")
            val folders = runCatching { app.api.systemFolders() }.getOrNull()
            if (folders != null) {
                folders.photoFolderId?.let { prefs.photoFolderId = it }
                // «Телефон» больше не используется: раздел «Файлы» ведёт зеркало
                folders.phoneFolderId?.let { prefs.phoneFolderId = it }
            }
        }

        val builder = QueueBuilder(DeviceFiles(context), app.queueStore)
        return builder.build(
            selection = app.selection,
            photoFolderId = prefs.photoFolderId.takeIf { it.isNotBlank() },
            onProgress = onProgress,
        )
    }
}
