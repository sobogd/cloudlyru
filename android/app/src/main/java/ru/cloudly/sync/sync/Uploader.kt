package ru.cloudly.sync.sync

import ru.cloudly.sync.net.Api
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.max
import kotlin.math.min

/**
 * Заливка одного файла: части идут прямо в S3 по presigned-ссылкам, сервер видит только
 * ETag'и. Часть загрузки можно прервать и продолжить: сервер держит принятые части в БД,
 * поэтому после обрыва спрашиваем статус сессии и продолжаем с нужного номера.
 */
class Uploader(private val api: Api) {

    /** Сколько частей льём одновременно: память ≈ parallelism × partSize. */
    private val parallelism = 3
    /** Части, которые клиент заливает в S3 напрямую (сколько успел — то и принято). */
    private var partSize = 16 * 1024 * 1024

    /** Итог выгрузки одного файла. */

    data class Result(
        val entryId: String,
        val name: String,
        val sha256: String,
        val deduped: Boolean,
    )

    /**
     * @param expectedSha256 версия файла на сервере, которую клиент считает актуальной
     *        (обязательна при перезаписи: сервер откажет, если там уже другое содержимое).
     */
    fun upload(
        folderId: String,
        file: LocalFile,
        sha256: String,
        replace: Boolean,
        expectedSha256: String?,
        uploadIdFromQueue: String?,
        onSession: (String) -> Unit,
        onProgress: (sent: Long, total: Long) -> Unit,
        /** true — лить через сервер: нужно, когда хранилище с телефона недоступно. */
        forceRelay: Boolean = false,
    ): Result {
        val mime = Scanner.mimeOf(file.name)
        if (uploadIdFromQueue == null) {
            val init = api.initUpload(
                folderId = folderId,
                name = file.name,
                size = file.size,
                mime = mime,
                sha256 = sha256,
                replace = replace,
                clientMtime = file.mtime,
                expectedSha256 = expectedSha256,
                mode = if (forceRelay) "relay" else "direct",
            )
            if (init.stale || init.inTrash || init.nameTaken) {
                // имя занято — движок придумает свободное имя и вернётся к этому файлу
                throw ru.cloudly.sync.net.ApiException(409, if (init.inTrash) "in_trash" else "conflict", "name taken", null)
            }
            if (init.deduped || init.uploadId == null) {
                // содержимое уже в облаке: запись создана, байты не передавались
                return Result(init.entryId, file.name, sha256, deduped = true)
            }
            onSession(init.uploadId)
            return sendParts(init.uploadId, init.direct, init.partSize, File(file.path), sha256, onProgress)
        }
        // сессия осталась с прошлого прохода: продолжаем с последней принятой части
        // (способ берём у сервера: релей-сессию нельзя продолжать presigned-ссылками)
        val status = api.uploadStatus(uploadIdFromQueue)
        return sendParts(
            uploadIdFromQueue,
            direct = status.direct,
            partSize = status.partSize,
            file = File(file.path),
            sha256 = sha256,
            onProgress = onProgress,
            startPart = status.nextPart,
        )
    }

    private fun sendParts(
        uploadId: String,
        direct: Boolean,
        partSize: Int,
        file: File,
        sha256: String,
        onProgress: (Long, Long) -> Unit,
        startPart: Int = 1,
    ): Result {
        this.partSize = partSize
        val total = file.length()
        val parts = max(1, ((total + partSize - 1) / partSize).toInt())
        var sent = ((startPart - 1).toLong() * partSize).coerceAtMost(total)
        onProgress(sent, total)
        // релей-режим (байты идут через сервер) требует строгого порядка частей;
        // на очень больших файлах ужимаем параллелизм: буферы частей держатся в памяти целиком
        val width = when {
            !direct -> 1
            total > 1024L * 1024 * 1024 -> 2
            else -> parallelism
        }

        RandomAccessFile(file, "r").use { raf ->
            var part = startPart
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

    /** Оценка числа частей для лога/прогресса. */
    fun partCount(size: Long): Int = max(1, ((size + partSize - 1) / partSize).toInt())
}
