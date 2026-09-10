package ru.cloudly.sync.sync

import android.util.Log
import org.json.JSONObject
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import java.io.File

/**
 * Движок синхронизации.
 *
 * Порядок прохода: сначала догоняем журнал изменений сервера (курсор по seq), потом сканируем
 * папку задачи и раскладываем файлы на «уже синхронизировано», «надо залить», «надо удалить».
 * Решения принимаются по трём сторонам: локальный файл, состояние в base (таблица items)
 * и снимки из журнала сервера.
 *
 * Что осознанно не делает этот этап (M3.1): скачивание файлов с сервера и вытеснение по сроку —
 * это M3.2/M3.3. Фото-задача льёт вверх, файловая — вверх и удаляет за сервером.
 */
class Engine(private val db: Db, private val api: Api) {

    data class Stats(
        var scanned: Int = 0,
        var uploaded: Int = 0,
        var deduped: Int = 0,
        var skipped: Int = 0,
        var deleted: Int = 0,
        var conflicts: Int = 0,
        var errors: Int = 0,
        var pending: Int = 0,
        var fatal: String? = null,
    )

    /** Результат применения журнала: сколько событий доехало и не нужен ли полный рескан. */
    private data class JournalResult(val applied: Int, val reset: Boolean)

    fun syncAll(onProgress: (String) -> Unit = {}): Stats {
        val stats = Stats()
        for (job in db.jobs(enabledOnly = true)) {
            val journal = try {
                applyJournal(job, onProgress)
            } catch (e: Exception) {
                stats.errors += 1
                stats.fatal = "журнал: ${e.message}"
                continue
            }
            if (journal.reset) {
                // курсор устарел (журнал подрезали или БД восстановили): состояние пересоберём с нуля
                for (item in db.itemsOf(job.id)) db.deleteItem(job.id, item.relPath)
            }
            try {
                syncJob(job, stats, onProgress)
            } catch (e: Exception) {
                stats.errors += 1
                stats.fatal = e.message
            }
        }
        stats.pending = db.ops().size
        return stats
    }

    // ===== журнал сервера =====

    private fun applyJournal(job: Db.Job, onProgress: (String) -> Unit): JournalResult {
        var cursor = db.cursor().toLongOrNull() ?: 0L
        var applied = 0
        var reset = false
        for (round in 0 until 50) {
            val page = api.changes(cursor.toString())
            if (page.resetRequired) reset = true
            for (change in page.changes) {
                applyChange(job, change)
                applied += 1
                cursor = change.seq
            }
            db.setCursor(cursor.toString())
            if (!page.hasMore) break
            onProgress("журнал: ${applied} событий")
        }
        return JournalResult(applied, reset)
    }

    /**
     * Применение одного события. Событие — снимок цели, поэтому решение принимается по нему,
     * а не по догадкам: `delete` у папки означает «всего её поддерева нет».
     */
    private fun applyChange(job: Db.Job, change: ru.cloudly.sync.net.Change) {
        if (change.target == "folder") {
            if (change.op == "delete") {
                // папка удалена на сервере — локальные файлы, которые в неё синхронизировались, тоже уходят
                for (item in db.itemsOf(job.id)) {
                    val remoteFolder = item.remoteFolderId ?: continue
                    if (remoteFolder == change.targetId) deleteLocal(job, item, "папка удалена на сервере")
                }
            }
            return
        }
        // запись в дереве
        val item = db.itemsOf(job.id).firstOrNull { it.remoteEntryId == change.targetId }
            ?: db.itemsOf(job.id).firstOrNull { it.remoteFolderId == change.folderId && it.name == change.name }
        when (change.op) {
            "delete" -> {
                db.markRemoteDeleted(change.targetId, job.id, change.name, change.folderId, change.sha256)
                if (item != null) deleteLocal(job, item, "удалено на сервере")
            }
            "create", "update", "move", "restore", "pin" -> {
                if (item != null) {
                    db.updateItem(
                        job.id,
                        item.relPath,
                        mapOf(
                            "remote_entry_id" to change.targetId,
                            "remote_sha256" to change.sha256,
                            "remote_folder_id" to change.folderId,
                            "keep_offline" to if (change.keepOffline) 1 else 0,
                        ),
                    )
                    // содержимое на сервере изменилось не нами: снимаем метку «удалено», чтобы не блокировать заливку
                    db.clearRemoteDeleted(change.targetId)
                }
            }
        }
    }

    private fun deleteLocal(job: Db.Job, item: Db.Item, reason: String) {
        if (item.keepOffline) {
            Log.i(TAG, "не удаляю закреплённое: ${item.relPath} ($reason)")
            return
        }
        val file = File(item.localPath)
        if (file.exists() && !file.delete()) {
            Log.w(TAG, "не удалось удалить ${item.localPath}")
            return
        }
        db.deleteItem(job.id, item.relPath)
        Log.i(TAG, "удалено локально: ${item.relPath} ($reason)")
    }

    // ===== проход по папке задачи =====

    private fun syncJob(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        val root = File(job.sourceDir)
        val known = db.itemsOf(job.id)
        // Аварийный стоп: если корень задачи пропал или скан внезапно пуст при известных файлах,
        // ни одного удаления не делаем — иначе один сбой чтения снесёт и облако, и телефон.
        if (!root.isDirectory) {
            stats.fatal = "папка недоступна: ${job.sourceDir}"
            return
        }
        val files = Scanner.scan(job.sourceDir, job.includeSubfolders)
        if (files.isEmpty() && known.isNotEmpty()) {
            stats.fatal = "скан вернул 0 файлов при ${known.size} известных — проход прерван"
            return
        }
        stats.scanned += files.size
        onProgress("${job.sourceDir}: ${files.size} файлов")

        val seen = HashSet<String>()
        val candidates = ArrayList<Pair<LocalFile, Db.Item?>>()
        for (file in files) {
            seen.add(file.relPath)
            val item = known.firstOrNull { it.relPath == file.relPath }
            if (item != null && item.state == Db.STATE_SYNCED && item.sha256 != null &&
                item.localSize == file.size && item.localMtime == file.mtime
            ) {
                stats.skipped += 1
                continue
            }
            candidates.add(file to item)
        }

        // Удаления: то, что было в base и исчезло локально.
        for (item in known) {
            if (item.relPath in seen) continue
            if (item.state == Db.STATE_EVICTED) continue
            if (item.remoteEntryId == null) {
                // так и не выгрузилось — на сервере ничего нет, удалять нечего
                db.deleteItem(job.id, item.relPath)
                continue
            }
            if (item.keepOffline) {
                Log.i(TAG, "не удаляю закреплённое локально: ${item.relPath}")
                continue
            }
            db.enqueueOp(job.id, item.relPath, Db.OP_DELETE)
        }

        // Новые и изменённые: считаем хэш и решаем, нужны ли байты.
        val shas = ArrayList<String>(candidates.size)
        val hashed = ArrayList<Triple<LocalFile, Db.Item?, String>>(candidates.size)
        for ((file, item) in candidates) {
            if (file.size == 0L) continue
            val sha = Hasher.sha256(File(file.path))
            hashed.add(Triple(file, item, sha))
            if (item == null || item.sha256 != sha) shas.add(sha)
        }
        val present = if (shas.isEmpty()) emptySet() else runCatching { api.have(shas.distinct().take(500)) }.getOrDefault(emptySet())

        for ((file, item, sha) in hashed) {
            if (item == null) {
                // новая запись: сохраняем состояние и ставим в очередь (в облаке может уже быть это содержимое)
                db.putItem(
                    Db.Item(
                        jobId = job.id,
                        relPath = file.relPath,
                        localPath = file.path,
                        localSize = file.size,
                        localMtime = file.mtime,
                        sha256 = sha,
                        remoteEntryId = null,
                        remoteSha256 = if (sha in present) sha else null,
                        remoteFolderId = job.targetFolderId,
                        name = file.name,
                        state = Db.STATE_NEW,
                        keepOffline = false,
                        uploadedAt = null,
                    ),
                )
                db.enqueueOp(job.id, file.relPath, Db.OP_UPLOAD)
                continue
            }
            if (item.sha256 == sha && item.state == Db.STATE_SYNCED) {
                // содержимое то же, поменялись только дата/размер в метаданных
                db.updateItem(job.id, file.relPath, mapOf("local_mtime" to file.mtime, "local_size" to file.size))
                stats.skipped += 1
                continue
            }
            db.updateItem(
                job.id,
                file.relPath,
                mapOf(
                    "sha256" to sha,
                    "local_size" to file.size,
                    "local_mtime" to file.mtime,
                    "state" to Db.STATE_NEW,
                ),
            )
            db.enqueueOp(job.id, file.relPath, Db.OP_UPLOAD)
        }

        runOps(job, stats, onProgress)
    }

    // ===== очередь операций =====

    private fun runOps(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        while (true) {
            val op = db.nextOpForJob(job.id, System.currentTimeMillis()) ?: break
            try {
                when (op.kind) {
                    Db.OP_UPLOAD -> handleUpload(job, op, stats, onProgress)
                    Db.OP_DELETE -> handleDelete(job, op, stats)
                    else -> db.deleteOp(op.id)
                }
            } catch (e: ApiException) {
                if (e.status == 409 && e.code == "stale_version") {
                    // сервер: версия разошлась. Локальную копию сохраняем как конфликтную,
                    // каноническое имя остаётся за сервером (сервер — источник истины).
                    handleStale(job, op, e)
                    continue
                }
                if (e.status == 409 && e.code == "in_trash") {
                    // файл в корзине сервера: не воскрешаем сами, помечаем и не повторяем бесконечно
                    db.updateOp(op.id, mapOf("last_error" to "в корзине сервера", "next_attempt_at" to Long.MAX_VALUE / 2))
                    db.updateItem(job.id, op.relPath, mapOf("state" to Db.STATE_SYNCED, "remote_sha256" to null))
                    stats.conflicts += 1
                    continue
                }
                retry(op, e.message ?: "ошибка API", stats)
            } catch (e: Exception) {
                retry(op, e.message ?: "ошибка", stats)
            }
        }
    }

    private fun handleUpload(job: Db.Job, op: Db.Op, stats: Stats, onProgress: (String) -> Unit) {
        val item = db.item(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val file = File(item.localPath)
        if (!file.isFile) {
            // файл исчез между сканом и заливкой: удаление обработает следующая проверка
            db.deleteOp(op.id)
            db.deleteItem(job.id, op.relPath)
            return
        }
        val sha = item.sha256 ?: Hasher.sha256(file).also { db.updateItem(job.id, op.relPath, mapOf("sha256" to it)) }
        val replace = item.remoteEntryId != null
        onProgress("загрузка: ${item.name}")
        val result = Uploader(api).upload(
            job = job,
            file = LocalFile(item.relPath, item.localPath, item.name, item.localSize, item.localMtime),
            sha256 = sha,
            replace = replace,
            expectedSha256 = if (replace) item.remoteSha256 else null,
            uploadIdFromQueue = op.uploadId,
            onProgress = { sent, total ->
                val pct = if (total > 0) (sent * 100 / total).toInt() else 0
                onProgress("загрузка ${item.name}: $pct%")
            },
        )
        if (result.stale) {
            handleStale(job, op, null)
            return
        }
        db.updateItem(
            job.id,
            op.relPath,
            mapOf(
                "state" to Db.STATE_SYNCED,
                "remote_entry_id" to result.entryId.ifBlank { item.remoteEntryId },
                "remote_sha256" to sha,
                "uploaded_at" to System.currentTimeMillis(),
            ),
        )
        db.deleteOp(op.id)
        if (result.deduped) stats.deduped += 1 else stats.uploaded += 1
    }

    private fun handleDelete(job: Db.Job, op: Db.Op, stats: Stats) {
        val item = db.item(job.id, op.relPath)
        val entryId = item?.remoteEntryId
        if (entryId != null) {
            api.deleteFile(entryId) // сервер отправит запись в корзину
        }
        db.deleteItem(job.id, op.relPath)
        db.deleteOp(op.id)
        stats.deleted += 1
    }

    /**
     * Локальная правка против изменившейся серверной версии: переименовываем локальный файл
     * в «конфликтную копию» и заливаем её отдельной записью, а канонический файл на сервере
     * не трогаем. Ничего не теряется, и это видно в файловом менеджере.
     */
    private fun handleStale(job: Db.Job, op: Db.Op, e: ApiException?) {
        val item = db.item(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val src = File(item.localPath)
        val stamp = java.text.SimpleDateFormat("yyyy-MM-dd HH-mm", java.util.Locale.US).format(java.util.Date())
        val conflictName = buildConflictName(item.name, stamp)
        val target = File(src.parentFile, conflictName)
        if (src.exists() && !target.exists() && src.renameTo(target)) {
            db.deleteItem(job.id, op.relPath)
            db.putItem(
                item.copy(
                    relPath = conflictName,
                    localPath = target.absolutePath,
                    name = conflictName,
                    remoteEntryId = null,
                    remoteSha256 = null,
                    state = Db.STATE_NEW,
                ),
            )
            db.enqueueOp(job.id, conflictName, Db.OP_UPLOAD)
            Log.i(TAG, "конфликт версий: ${item.name} → $conflictName")
        } else {
            Log.w(TAG, "конфликт версий, но переименовать не удалось: ${item.localPath}")
            db.updateOp(op.id, mapOf("last_error" to (e?.message ?: "stale"), "next_attempt_at" to Long.MAX_VALUE / 2))
        }
    }

    private fun buildConflictName(name: String, stamp: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) {
            "${name.substring(0, dot)} (конфликт $stamp)${name.substring(dot)}"
        } else {
            "$name (конфликт $stamp)"
        }
    }

    /** Ретраи с экспоненциальным бэкоффом: 30 с, 2 мин, 10 мин, 1 ч, дальше — раз в 6 часов. */
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
        Log.w(TAG, "операция ${op.kind} ${op.relPath}: $message (попытка $attempts)")
    }

    /** Служебное: пометить папку на сервере как «держать офлайн». */
    fun setFolderKeepOffline(folderId: String, keepOffline: Boolean) {
        api.patchFolder(folderId, JSONObject().put("keepOffline", keepOffline))
    }

    companion object {
        private const val TAG = "cloudly-sync"
    }
}
