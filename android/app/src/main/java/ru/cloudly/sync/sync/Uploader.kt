package ru.cloudly.sync.sync

import ru.cloudly.sync.data.Db
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

    /**
     * Итог заливки. `stale` — сервер отказал из-за расхождения версий: файл на сервере
     * уже другой, клиент должен сохранить локальную копию как конфликтную.
     */
    data class Result(val entryId: String, val name: String, val sha256: String, val deduped: Boolean, val stale: Boolean, val currentSha256: String?)

    /**
     * @param expectedSha256 версия файла на сервере, которую клиент считает актуальной
     *        (обязательна при перезаписи: сервер откажет, если там уже другое содержимое).
     */
    fun upload(
        job: Db.Job,
        file: LocalFile,
        sha256: String,
        replace: Boolean,
        expectedSha256: String?,
        uploadIdFromQueue: String?,
        onProgress: (sent: Long, total: Long) -> Unit,
    ): Result {
        val mime = Scanner.mimeOf(file.name)
        if (uploadIdFromQueue == null) {
            val init = api.initUpload(
                folderId = job.targetFolderId,
                name = file.name,
                size = file.size,
                mime = mime,
                sha256 = sha256,
                replace = replace,
                clientMtime = file.mtime,
                expectedSha256 = expectedSha256,
            )
            if (init.stale) return Result("", file.name, sha256, false, stale = true, currentSha256 = init.currentSha256)
            if (init.deduped || init.uploadId == null) {
                // содержимое уже в облаке: запись создана, байты не передавались
                return Result(init.uploadId ?: "", file.name, sha256, deduped = true, stale = false, currentSha256 = null)
            }
            return sendParts(init.uploadId, init.direct, init.partSize, File(file.path), sha256, onProgress)
        }
        // сессия осталась с прошлого прохода: продолжаем с последней принятой части
        val (nextPart, size) = api.uploadStatus(uploadIdFromQueue)
        return sendParts(uploadIdFromQueue, direct = true, partSize = size, file = File(file.path), sha256 = sha256, onProgress = onProgress, startPart = nextPart)
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

        RandomAccessFile(file, "r").use { raf ->
            var part = startPart
            while (part <= parts) {
                val batchEnd = min(parts, part + parallelism - 1)
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
        return Result(entry.id, entry.name, sha256, deduped = false, stale = false, currentSha256 = null)
    }

    /** Оценка числа частей для лога/прогресса. */
    fun partCount(size: Long): Int = max(1, ((size + partSize - 1) / partSize).toInt())
}
