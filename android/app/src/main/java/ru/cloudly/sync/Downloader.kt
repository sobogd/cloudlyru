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
    /**
     * @param expectSha256 содержимое, которое должно получиться: скачанное проверяем по размеру
     *        и хэшу, иначе испорченный файл (обрыв, плохой прокси) следующий проход зальёт в облако
     *        как «локальную правку» и затрёт хорошую серверную копию.
     */
    fun download(
        api: Api,
        entryId: String,
        target: File,
        clientMtime: Long?,
        expectSha256: String? = null,
        expectSize: Long = -1,
    ) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, ".${target.name}.${System.nanoTime()}.cloudly-tmp")
        val backup = File(target.parentFile, "${target.name}.cloudly-old")
        var replaced = false
        try {
            api.downloadStream(entryId).use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, bufferSize = 1 shl 20) }
            }
            if (expectSize >= 0 && tmp.length() != expectSize) {
                throw IllegalStateException("скачано ${tmp.length()} байт вместо $expectSize")
            }
            if (expectSha256 != null && Hasher.sha256(tmp) != expectSha256) {
                throw IllegalStateException("хэш скачанного не совпал")
            }
            // цель убираем только после успешной проверки и держим её копию до переименования
            if (target.exists()) {
                if (backup.exists()) backup.delete()
                if (!target.renameTo(backup)) throw IllegalStateException("не удалось отложить старый файл")
            }
            if (!tmp.renameTo(target)) {
                if (backup.exists()) backup.renameTo(target)
                throw IllegalStateException("не удалось переименовать ${tmp.name}")
            }
            replaced = true
            if (clientMtime != null && clientMtime > 0) target.setLastModified(clientMtime)
        } finally {
            if (tmp.exists()) tmp.delete()
            if (replaced && backup.exists()) backup.delete()
            if (!replaced && !target.exists() && backup.exists()) backup.renameTo(target)
        }
    }
}
