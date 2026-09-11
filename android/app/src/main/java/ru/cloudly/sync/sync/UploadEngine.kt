package ru.cloudly.sync.sync

import android.content.Context
import android.util.Log
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import java.io.File

/**
 * Односторонняя выгрузка: папка телефона → папка в облаке.
 *
 * Модель намеренно простая и безопасная: приложение только читает файлы на телефоне и добавляет
 * их в облако. Оно ничего не удаляет, не перезаписывает и не скачивает — поэтому здесь нет
 * ни состояний «вытеснено/удалено», ни разрешения конфликтов, ни применения журнала изменений.
 *
 * Что делает проход:
 *   1. обходит папку задачи (Scanner) и сравнивает с кэшем (путь → размер, mtime, sha);
 *   2. для новых и изменённых файлов считает хэш и спрашивает сервер, есть ли такое содержимое
 *      (`/sync/have`) — если есть, байты не передаются вообще;
 *   3. переименования распознаёт по совпадению содержимого и отправляет серверу move,
 *      чтобы в облаке не появлялось дублей;
 *   4. загружает очередь: части прямо в S3, а если хранилище с телефона недоступно — через сервер.
 */
class UploadEngine(private val context: Context, private val db: Db, private val api: Api) {

    data class Stats(
        var scanned: Int = 0,
        var uploaded: Int = 0,
        var deduped: Int = 0,
        var skipped: Int = 0,
        var empty: Int = 0,
        var renamed: Int = 0,
        var errors: Int = 0,
        var pending: Int = 0,
        var fatal: String? = null,
    ) {
        /** Одна строка для интерфейса, уведомления и журнала. */
        fun text(): String =
            "проверено ${scanned}, выгружено ${uploaded}, дедуп ${deduped}, переносов ${renamed}, " +
                "пропущено ${skipped}, пустых ${empty}, ошибок ${errors}"
    }

    private val folderCache = HashMap<String, String>()
    private var currentJobId: Long? = null

    fun syncAll(onProgress: (String) -> Unit = {}): Stats {
        val stats = Stats()
        folderCache.clear()
        val report: (String) -> Unit = { line ->
            onProgress(line)
            currentJobId?.let { db.putKv("job_progress:$it", line) }
        }
        // Сначала то, что сохранили в облако из другого приложения и не смогли выгрузить:
        // такие файлы лежат вне кэша и ждут именно этого момента.
        val (lateUploaded, lateFailed) = PendingUploads.retryAll(context, api)
        if (lateUploaded > 0) {
            stats.uploaded += lateUploaded
            report("догружено сохранённое ранее: $lateUploaded")
        }
        if (lateFailed > 0) stats.errors += lateFailed

        for (job in db.jobs(enabledOnly = true)) {
            if (Decisions.shouldWaitForWifi(job, Network.isUnmetered(context))) {
                db.putKv("job_note:${job.id}", "ждём Wi-Fi: у задачи включено «только по Wi-Fi»")
                report("${File(job.sourceDir).name}: ждём Wi-Fi")
                continue
            }
            db.putKv("job_note:${job.id}", "")
            currentJobId = job.id
            try {
                syncJob(job, stats, report)
            } catch (e: Exception) {
                stats.errors += 1
                stats.fatal = "${File(job.sourceDir).name}: ${e.message}"
                db.putKv("job_note:${job.id}", "ошибка прохода: ${e.message}")
                Log.w(TAG, "проход задачи ${job.sourceDir}: ${e.message}")
            }
        }
        stats.pending = db.opCount()
        db.putKv("last_run_at", System.currentTimeMillis().toString())
        currentJobId = null
        return stats
    }

    private fun remoteFolderFor(job: Db.Job, relDir: String): String {
        // «Фото» ложится плоско (структура подпапок телефона не переносится), «Файлы» — как есть
        if (job.zone == "PHOTOS") return job.targetFolderId
        if (relDir.isEmpty()) return job.targetFolderId
        folderCache["${job.id}:$relDir"]?.let { return it }
        val id = withRateLimitRetry("создание папки $relDir") { api.ensurePath(relDir, job.targetFolderId) }
        folderCache["${job.id}:$relDir"] = id
        return id
    }

    /**
     * Сервер ограничивает частоту запросов (429). Первый проход по дереву с подпапками
     * заводит их десятками, и упереться в лимит на середине — значит уронить весь проход
     * и повторять это каждый раз. Ждём и повторяем, а не сдаёмся.
     */
    private fun <T> withRateLimitRetry(what: String, block: () -> T): T {
        var waitMs = 2_000L
        for (attempt in 0 until 4) {
            try {
                return block()
            } catch (e: ApiException) {
                if (e.status != 429 || attempt == 3) throw e
                Log.w(TAG, "$what: сервер просит подождать — пауза ${waitMs / 1000} с")
                Thread.sleep(waitMs)
                waitMs *= 2
            }
        }
        throw IllegalStateException("$what: сервер так и не принял запрос")
    }

    private fun syncJob(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        val root = File(job.sourceDir)
        if (!root.isDirectory) {
            stats.fatal = "папка недоступна: ${job.sourceDir}"
            return
        }
        val scan = Scanner.scan(job.sourceDir, job.includeSubfolders)
        val files = scan.files
        val cached = db.cacheOf(job.id).associateBy { it.relPath }

        val dirEntries = root.listFiles()?.size ?: -1
        val note = when {
            dirEntries < 0 -> "папка не читается (нет доступа ко всем файлам?)"
            files.isEmpty() && dirEntries == 0 -> "папка пуста"
            files.isEmpty() && scan.skipped.isNotEmpty() -> "все файлы пропущены (свежие или скрытые): ${scan.skipped.size}"
            files.isEmpty() -> "файлов не найдено, хотя в папке $dirEntries объектов"
            else -> ""
        }
        db.putKv("job_note:${job.id}", note)
        stats.scanned += files.size
        onProgress("${root.name}: ${files.size} файлов")

        val seen = HashSet<String>(scan.skipped)
        val fresh = ArrayList<LocalFile>()
        for (file in files) {
            seen.add(file.relPath)
            val known = cached[file.relPath]
            val unchanged = known != null && known.localSize == file.size && known.localMtime == file.mtime &&
                known.entryId != null
            if (unchanged) {
                stats.skipped += 1
                continue
            }
            fresh.add(file)
        }

        // Переименования: путь исчез, путь появился, содержимое то же. Считаем хэши один раз —
        // они нужны и для этого, и для дедупа ниже.
        val hashed = ArrayList<Triple<LocalFile, Db.Cached?, String>>(fresh.size)
        for (file in fresh) {
            if (file.size == 0L) {
                stats.empty += 1
                continue
            }
            val known = cached[file.relPath]
            val sha = known?.sha256?.takeIf { known.localSize == file.size && known.localMtime == file.mtime }
                ?: Hasher.sha256(File(file.path))
            hashed.add(Triple(file, known, sha))
        }

        val vanished = cached.values
            .filter { it.relPath !in seen && it.entryId != null }
            .map { it.relPath to it.sha256 }
        val appeared = hashed.filter { it.second == null }.map { it.first.relPath to it.third }
        val moves = Decisions.matchMoves(vanished, appeared)
        val movedNew = HashSet<String>()
        for ((oldPath, newPath) in moves) {
            val old = cached[oldPath] ?: continue
            val file = files.firstOrNull { it.relPath == newPath } ?: continue
            val targetFolder = remoteFolderFor(job, newPath.substringBeforeLast('/', ""))
            try {
                api.moveFile(old.entryId!!, targetFolder, file.name)
            } catch (e: Exception) {
                stats.errors += 1
                Log.w(TAG, "перенос ${old.relPath} → $newPath не прошёл: ${e.message}")
                continue
            }
            db.deleteCache(job.id, oldPath)
            db.putCache(
                old.copy(
                    relPath = newPath,
                    localPath = file.path,
                    localSize = file.size,
                    localMtime = file.mtime,
                ),
            )
            movedNew.add(newPath)
            stats.renamed += 1
            Log.i(TAG, "перенос: $oldPath → $newPath")
        }

        for ((file, known, sha) in hashed) {
            if (file.relPath in movedNew) continue
            if (known != null && Decisions.isAlreadyUploaded(known.sha256, known.localSize, sha, file.size) && known.entryId != null) {
                db.updateCache(job.id, file.relPath, mapOf("local_mtime" to file.mtime, "local_size" to file.size))
                stats.skipped += 1
                continue
            }
            db.putCache(
                Db.Cached(
                    jobId = job.id,
                    relPath = file.relPath,
                    localPath = file.path,
                    localSize = file.size,
                    localMtime = file.mtime,
                    sha256 = sha,
                    entryId = null,
                    uploadedAt = null,
                ),
            )
            db.enqueue(job.id, file.relPath)
        }

        runOps(job, stats, onProgress)

        db.putKv(
            "job_stat:${job.id}",
            "проверено ${files.size}, выгружено ${stats.uploaded}, дедуп ${stats.deduped}, " +
                "переносов ${stats.renamed}, пропущено ${stats.skipped}, пустых ${stats.empty}, ошибок ${stats.errors}",
        )
        db.putKv("job_at:${job.id}", System.currentTimeMillis().toString())
        db.putKv("job_progress:${job.id}", "проход завершён")
    }

    private fun runOps(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        while (true) {
            val op = db.nextOp(job.id, System.currentTimeMillis()) ?: break
            try {
                handleUpload(job, op, stats, onProgress)
            } catch (e: ApiException) {
                when {
                    // сервер потерял сессию (рестарт, чистка брошенных, повторный complete):
                    // сбрасываем upload_id и начинаем заново, иначе 404 будет вечно
                    // сервер потерял сессию, файл на диске изменился (число частей другое) или
                    // в сессии не хватает части: начинаем загрузку заново, иначе 404/400 навсегда
                    e.status == 404 || e.code == "upload_session_lost" || e.code == "upload_completed" ||
                        (e.status == 400 && (e.message ?: "").contains("missing part")) -> {
                        db.updateOp(op.id, mapOf("upload_id" to null, "next_attempt_at" to System.currentTimeMillis() + 3_000))
                    }
                    e.status == 401 || e.status == 403 -> {
                        db.putKv("auth_error", e.message ?: "нет доступа")
                        db.updateOp(op.id, mapOf("last_error" to "нет доступа (проверь токен)", "next_attempt_at" to System.currentTimeMillis() + 3_600_000))
                    }
                    else -> retry(op, e.message ?: "ошибка API", stats)
                }
            } catch (e: Exception) {
                retry(op, e.message ?: "ошибка", stats)
            }
        }
    }

    private fun handleUpload(job: Db.Job, op: Db.Op, stats: Stats, onProgress: (String) -> Unit) {
        val cached = db.cacheEntry(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val file = File(cached.localPath)
        if (!file.isFile) {
            // файл исчез между сканом и загрузкой — просто забываем запись, ничего не удаляем
            db.deleteOp(op.id)
            return
        }
        // Хэш в кэше верен, если файл с тех пор не менялся: на большом видео повторное
        // хэширование на каждую попытку — минуты работы и батарея.
        val size = file.length()
        val mtime = file.lastModified()
        val sha = cached.sha256.takeIf {
            it.isNotBlank() && cached.localSize == size && cached.localMtime == mtime
        } ?: Hasher.sha256(file)
        db.updateCache(job.id, op.relPath, mapOf("sha256" to sha, "local_size" to size, "local_mtime" to mtime))
        val folderId = remoteFolderFor(job, op.relPath.substringBeforeLast('/', ""))
        // Имя записи в облаке может отличаться от локального: если такое имя уже занято другим
        // содержимым, свободное имя получает только облачная запись. Локальный файл не трогаем —
        // приложение не переименовывает и не переносит файлы на телефоне.
        var cloudName = file.name
        var attempt = 0
        while (true) {
            onProgress("выгрузка: $cloudName")
            try {
                val result = uploadFile(job, op, file, cloudName, sha, onProgress)
                db.updateCache(
                    job.id,
                    op.relPath,
                    mapOf(
                        "entry_id" to result.entryId,
                        "uploaded_at" to System.currentTimeMillis(),
                        "sha256" to sha,
                    ),
                )
                db.deleteOp(op.id)
                if (result.deduped) stats.deduped += 1 else stats.uploaded += 1
                Log.i(TAG, "выгружено ${op.relPath}${if (result.deduped) " (содержимое уже было в облаке)" else ""}")
                return
            } catch (e: ApiException) {
                val nameTaken = e.code == "conflict" || e.code == "in_trash" ||
                    (e.message ?: "").contains("already exists")
                if (!nameTaken || ++attempt >= NAME_ATTEMPTS) throw e
                val taken = runCatching { api.children(folderId).entries.map { it.name }.toHashSet() }
                    .getOrElse { throw e }
                cloudName = Decisions.freeName(file.name, taken)
                op.uploadId?.let { runCatching { api.abort(it) } }
                db.updateOp(op.id, mapOf("upload_id" to null))
                Log.i(TAG, "имя ${file.name} занято — в облако уйдёт как $cloudName")
            }
        }
    }

    /**
     * Одна попытка заливки. Прямая загрузка в хранилище может не работать (DNS, блокировщик,
     * VPN, TLS) — это не повод не выгрузить файл: пробуем через сервер и запоминаем режим.
     */
    private fun uploadFile(
        job: Db.Job,
        op: Db.Op,
        file: File,
        cloudName: String,
        sha: String,
        onProgress: (String) -> Unit,
    ): Uploader.Result {
        val folderId = remoteFolderFor(job, op.relPath.substringBeforeLast('/', ""))
        val local = LocalFile(op.relPath, file.absolutePath, cloudName, file.length(), file.lastModified())
        val progress: (String) -> (Long, Long) -> Unit = { prefix ->
            { sent, total ->
                val pct = if (total > 0) (sent * 100 / total).toInt() else 0
                onProgress("$prefix $cloudName: $pct%")
            }
        }
        return runCatching {
            Uploader(api).upload(
                folderId = folderId,
                file = local,
                sha256 = sha,
                replace = false,
                expectedSha256 = null,
                uploadIdFromQueue = op.uploadId,
                onSession = { id -> db.updateOp(op.id, mapOf("upload_id" to id)) },
                onProgress = progress("выгрузка"),
            )
        }.getOrElse { e ->
            if (relayMode()) throw e
            Log.w(TAG, "прямая загрузка не удалась (${e.message}) — пробую через сервер")
            op.uploadId?.let { runCatching { api.abort(it) } }
            db.putKv(KV_RELAY_MODE, System.currentTimeMillis().toString())
            db.putKv("job_note:${job.id}", "хранилище недоступно напрямую — выгрузка идёт через сервер")
            Uploader(api).upload(
                folderId = folderId,
                file = local,
                sha256 = sha,
                replace = false,
                expectedSha256 = null,
                uploadIdFromQueue = null,
                onSession = { id -> db.updateOp(op.id, mapOf("upload_id" to id)) },
                onProgress = progress("выгрузка через сервер"),
                forceRelay = true,
            )
        }
    }

    /** 30 с, 2 мин, 10 мин, 1 ч, дальше — раз в 6 часов. */
    private fun retry(op: Db.Op, message: String, stats: Stats) {
        val attempts = op.attempts + 1
        val delayMs = when (attempts) {
            1 -> 30_000L
            2 -> 120_000L
            3 -> 600_000L
            4 -> 3_600_000L
            else -> 6 * 3_600_000L
        }
        db.updateOp(
            op.id,
            mapOf(
                "attempts" to attempts,
                "last_error" to message.take(300),
                "next_attempt_at" to System.currentTimeMillis() + delayMs,
            ),
        )
        stats.errors += 1
        Log.w(TAG, "операция ${op.relPath}: $message (попытка $attempts)")
    }

    /** Режим «через сервер»: включён, если прямое подключение к хранилищу не сработало. */
    fun relayMode(): Boolean = !db.kv(KV_RELAY_MODE).isNullOrBlank()

    fun resetRelayMode() = db.putKv(KV_RELAY_MODE, "")

    /**
     * Освободить место: удалить с телефона то, что уже подтверждено в облаке.
     * Только вручную и только при совпадении размера и даты — если файл менялся после выгрузки,
     * его не трогаем, чтобы не потерять правку.
     */
    fun deleteUploadedLocally(items: List<Db.Cached>): Pair<Int, Long> {
        var deleted = 0
        var freed = 0L
        for (item in items) {
            val file = File(item.localPath)
            if (!file.isFile) continue
            if (file.length() != item.localSize || file.lastModified() != item.localMtime) {
                Log.w(TAG, "не удаляю изменённый после выгрузки файл: ${item.relPath}")
                continue
            }
            if (item.entryId.isNullOrBlank()) continue
            val size = file.length()
            if (!file.delete()) {
                Log.w(TAG, "не удалось удалить ${item.localPath}")
                continue
            }
            // у медиа убираем и запись в галерее, иначе останется битая миниатюра
            MediaCleanup.forget(context, file)
            db.deleteCache(item.jobId, item.relPath)
            deleted += 1
            freed += size
        }
        return deleted to freed
    }

    companion object {
        private const val TAG = "cloudly-sync"
        private const val KV_RELAY_MODE = "relay_mode"

        /** Сколько раз подряд переспрашивать свободное имя: параллельная запись в ту же папку. */
        private const val NAME_ATTEMPTS = 5
    }
}
