package ru.cloudly.sync.sync

import android.content.Context
import android.media.MediaScannerConnection
import java.io.File

/**
 * После удаления файла с телефона убираем его из медиатеки. Иначе галерея продолжает
 * показывать запись с битой миниатюрой: файла нет, а строка в MediaStore осталась.
 */
object MediaCleanup {
    fun forget(context: Context, file: File) {
        runCatching {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null, null)
        }
    }
}
