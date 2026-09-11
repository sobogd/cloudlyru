package ru.cloudly.sync.queue

import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.max
import kotlin.math.min

/**
 * Заливка одного файла: части идут прямо в S3 по presigned-ссылкам (сервер видит только ETag'и),
 * а если хранилище с телефона недоступно — через сервер.
 *
 * Части читаются из файла случайным доступом и льются параллельно: память ≈ параллелизм ×
 * размер части. Продолжение после обрыва на уровне очереди пока не сохраняется — повтор
 * начинается файл заново.
 */
class Uploader(private val api: Api) {

    /** Сколько частей льём одновременно: память ≈ parallelism × partSize. */
    private val parallelism = 3

    data class Result(val entryId: String, val name: String, val sha256: String, val deduped: Boolean)

    /**
     * @param expectedSha256 версия файла на сервере, которую клиент считает актуальной
     *        (обязательна при перезаписи: сервер откажет, если там уже другое содержимое)
     */
    fun upload(
        folderId: String,
        file: File,
        cloudName: String,
        mime: String,
        sha256: String,
        replace: Boolean,
        expectedSha256: String?,
        onSession: (String) -> Unit,
        onProgress: (sent: Long, total: Long) -> Unit,
        /** true — лить через сервер: нужно, когда хранилище с телефона недоступно. */
        forceRelay: Boolean = false,
    ): Result {
        val size = file.length()
        val mtime = file.lastModified()
        val init = api.initUpload(
            folderId = folderId,
            name = cloudName,
            size = size,
            mime = mime,
            sha256 = sha256,
            replace = replace,
            clientMtime = mtime,
            expectedSha256 = expectedSha256,
            mode = if (forceRelay) "relay" else "direct",
        )
        if (init.stale || init.inTrash || init.nameTaken) {
            // имя занято или версия на сервере другая — решает вызывающий: свободное имя
            // или отказ, чтобы не затереть чужое
            throw ApiException(409, if (init.inTrash) "in_trash" else "conflict", "name taken", null)
        }
        if (init.deduped || init.uploadId == null) {
            // содержимое уже в облаке: запись создана, байты не передавались
            return Result(init.entryId, cloudName, sha256, deduped = true)
        }
        onSession(init.uploadId)
        return sendParts(init.uploadId, init.direct, init.partSize, file, sha256, onProgress)
    }

    private fun sendParts(
        uploadId: String,
        direct: Boolean,
        partSize: Int,
        file: File,
        sha256: String,
        onProgress: (Long, Long) -> Unit,
    ): Result {
        val total = file.length()
        val parts = max(1, ((total + partSize - 1) / partSize).toInt())
        var sent = 0L
        onProgress(sent, total)
        // релей-режим (байты идут через сервер) требует строгого порядка частей;
        // на очень больших файлах ужимаем параллелизм: буферы частей держатся в памяти целиком
        val width = when {
            !direct -> 1
            total > 1024L * 1024 * 1024 -> 2
            else -> parallelism
        }

        RandomAccessFile(file, "r").use { raf ->
            var part = 1
            while (part <= parts) {
                val batchEnd = min(parts, part + width - 1)
                val batch = (part..batchEnd).toList()
                val lock = Object()
                var failure: Throwable? = null
                val threads = batch.map { number ->
                    Thread {
                        try {
                            val offset = (number - 1).toLong() * partSize
                            val length = min(partSize.toLong(), total - offset).toInt()
                            val buf = ByteArray(length)
                            synchronized(raf) {
                                raf.seek(offset)
                                raf.readFully(buf)
                            }
                            if (direct) {
                                val url = api.partUrl(uploadId, number)
                                val etag = api.putPartToS3(url, buf, 0, length)
                                api.registerPart(uploadId, number, etag, length)
                            } else {
                                api.relayChunk(uploadId, number, buf, 0, length)
                            }
                            synchronized(lock) {
                                sent += length
                                onProgress(sent, total)
                            }
                        } catch (t: Throwable) {
                            synchronized(lock) { if (failure == null) failure = t }
                        }
                    }
                }
                threads.forEach { it.start() }
                threads.forEach { it.join() }
                failure?.let { throw it }
                part = batchEnd + 1
            }
        }
        val entry = api.complete(uploadId, sha256)
        return Result(entry.id, entry.name, sha256, deduped = false)
    }
}
