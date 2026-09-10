package ru.cloudly.sync.sync

import ru.cloudly.sync.net.Api
import java.io.File

/**
 * Скачивание файла с сервера (файловое зеркало).
 *
 * Пишем во временный файл рядом с целью и только потом переименовываем: убитый процесс
 * не должен оставить обрезанный файл, который потом выглядел бы как «локальная правка».
 * После переименования выставляем mtime с сервера, чтобы следующий скан не считал файл изменённым.
 */
object Downloader {
    fun download(api: Api, entryId: String, target: File, clientMtime: Long?) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.cloudly-tmp")
        try {
            api.downloadStream(entryId).use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, bufferSize = 1 shl 20) }
            }
            if (target.exists()) target.delete()
            if (!tmp.renameTo(target)) throw IllegalStateException("не удалось переименовать ${tmp.name}")
            if (clientMtime != null && clientMtime > 0) target.setLastModified(clientMtime)
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }
}
