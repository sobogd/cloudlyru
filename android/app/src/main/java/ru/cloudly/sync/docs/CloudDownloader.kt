package ru.cloudly.sync.docs

import ru.cloudly.sync.device.Hasher
import ru.cloudly.sync.net.Api
import java.io.File

/**
 * Скачивание файла из облака в кэш телефона: файл, открытый из системного выбора файлов,
 * должен быть обычным файлом на диске, иначе просмотрщики и плееры не смогут его перематывать.
 *
 * Пишем во временный файл рядом с целью и переименовываем только после проверки: убитый
 * процесс не должен оставить обрезанный файл, который выглядел бы как готовый.
 */
object CloudDownloader {
    /**
     * @param expectSha256 содержимое, которое должно получиться. Проверка обязательна: без неё
     *        обрыв связи или плохой прокси оставили бы в кэше битый файл, а система отдала бы его
     *        чужому приложению как настоящий.
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
        // имя части стабильно: обрыв на большом файле не должен означать «качать сначала»
        val tmp = File(target.parentFile, ".${target.name}.cloudly-part")
        val backup = File(target.parentFile, "${target.name}.cloudly-old")
        var replaced = false
        try {
            var offset = if (tmp.exists()) tmp.length() else 0L
            if (expectSize in 0 until offset) offset = 0L // часть больше ожидаемого — начинаем заново
            api.downloadStream(entryId, offset).use { input ->
                tmp.outputStream().use { output ->
                    if (offset > 0) output.channel.position(offset)
                    input.copyTo(output, bufferSize = 1 shl 20)
                }
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
