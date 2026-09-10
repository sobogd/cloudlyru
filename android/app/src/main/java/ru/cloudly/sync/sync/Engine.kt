package ru.cloudly.sync.sync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import java.io.File

/**
 * Движок синхронизации.
 *
 * Порядок прохода: догоняем журнал изменений сервера (курсор по seq), сканируем папку задачи,
 * раскладываем файлы на «уже синхронизировано», «залить», «удалить», выполняем очередь операций,
 * затем (для файловых папок без вытеснения) привозим то, чего нет локально, и в конце вытесняем
 * выгруженное по сроку.
 *
 * Три состояния файла в base: `synced` (есть локально и в облаке), `new` (появился или изменился),
 * `evicted` (мы сами удалили локально, чтобы освободить место). Путать `evicted` с удалением
 * пользователем нельзя: иначе retention снёс бы копии в облаке.
 */
class Engine(private val context: Context, private val db: Db, private val api: Api) {

    /** relDir → id папки на сервере: создаём подпапки один раз за проход. */
    private val folderCache = HashMap<String, String>()

    data class Stats(
        var scanned: Int = 0,
        var uploaded: Int = 0,
        var deduped: Int = 0,
        var skipped: Int = 0,
        var downloaded: Int = 0,
        var deleted: Int = 0,
        var evicted: Int = 0,
        var conflicts: Int = 0,
        var errors: Int = 0,
        var pending: Int = 0,
        var fatal: String? = null,
    )

    /**
     * Папка на сервере для относительного пути файла. Файловые задачи повторяют структуру
     * подпапок как есть, поэтому адрес каталога вычисляется один раз и кэшируется на проход.
     */
    private fun remoteFolderFor(job: Db.Job, relDir: String): String {
        // «Фото» ложится плоско (структура подпапок телефона не переносится), «Файлы» — как есть
        if (job.zone == "PHOTOS") return job.targetFolderId
        if (relDir.isEmpty()) return job.targetFolderId
        folderCache["${job.id}:$relDir"]?.let { return it }
        val id = api.ensurePath(relDir, job.targetFolderId)
        folderCache["${job.id}:$relDir"] = id
        return id
    }

    fun syncAll(onProgress: (String) -> Unit = {}): Stats {
        val stats = Stats()
        folderCache.clear()
        for (job in db.jobs(enabledOnly = true)) {
            if (job.wifiOnly && !Network.isUnmetered(context)) {
                onProgress("${File(job.sourceDir).name}: ждём Wi-Fi")
                continue
            }
            try {
                if (applyJournal(job, onProgress)) {
                    // курсор устарел (журнал подрезали или БД восстановили): состояние пересоберём сканом
                    for (item in db.itemsOf(job.id)) db.deleteItem(job.id, item.relPath)
                }
                syncJob(job, stats, onProgress)
            } catch (e: Exception) {
                stats.errors += 1
                stats.fatal = "${File(job.sourceDir).name}: ${e.message}"
                Log.w(TAG, "проход задачи ${job.sourceDir}: ${e.message}")
            }
        }
        stats.pending = db.ops().size
        db.putKv("last_run_at", System.currentTimeMillis().toString())
        return stats
    }

    // ===== журнал сервера =====

    /** @return true, если нужен полный рескан (курсор старше журнала). */
    private fun applyJournal(job: Db.Job, onProgress: (String) -> Unit): Boolean {
        var cursor = db.cursor().toLongOrNull() ?: 0L
        var reset = false
        // Состояние читаем один раз и держим в памяти: применять событие запросом к базе на каждый
        // файл — это O(n²) на первой синхронизации большой библиотеки.
        val items = db.itemsOf(job.id)
        val byEntry = items.filter { it.remoteEntryId != null }.associateBy { it.remoteEntryId!! }.toMutableMap()
        val byPathName = items.associateBy { it.remoteFolderId to it.name }.toMutableMap()
        for (round in 0 until 100) {
            val page = api.changes(cursor.toString())
            if (page.resetRequired) reset = true
            for (change in page.changes) {
                cursor = change.seq
                if (change.target == "folder") {
                    applyFolderChange(change)
                    continue
                }
                val item = byEntry[change.targetId] ?: byPathName[change.folderId to change.name]
                if (change.op == "delete") {
                    db.markRemoteDeleted(change.targetId, job.id, change.name, change.folderId, change.sha256)
                    if (item != null) {
                        deleteLocal(job, item, "удалено на сервере")
                        byEntry.remove(item.remoteEntryId)
                        byPathName.remove(item.remoteFolderId to item.name)
                    }
                    continue
                }
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
                    val updated = item.copy(
                        remoteEntryId = change.targetId,
                        remoteSha256 = change.sha256,
                        remoteFolderId = change.folderId,
                        keepOffline = change.keepOffline,
                    )
                    byEntry[change.targetId] = updated
                    byPathName[change.folderId to change.name] = updated
                    db.clearRemoteDeleted(change.targetId)
                }
            }
            db.setCursor(cursor.toString())
            if (!page.hasMore) break
            onProgress("журнал: ${page.changes.size} событий")
        }
        return reset
    }

    private fun applyFolderChange(change: ru.cloudly.sync.net.Change) {
        if (change.op == "pin") {
            val set = pinned().toMutableSet()
            if (change.keepOffline) set.add(change.targetId) else set.remove(change.targetId)
            db.putKv(KV_PINNED_FOLDERS, set.joinToString(","))
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
        if (!root.isDirectory) {
            stats.fatal = "папка недоступна: ${job.sourceDir}"
            return
        }
        val files = Scanner.scan(job.sourceDir, job.includeSubfolders)
        // Аварийный стоп: пустой скан при известных файлах — это сбой чтения, а не удаление всего.
        // Без этой проверки один сбойный проход снёс бы и облако, и телефон.
        if (files.isEmpty() && known.isNotEmpty()) {
            stats.fatal = "скан вернул 0 файлов при ${known.size} известных — проход прерван"
            return
        }
        stats.scanned += files.size
        onProgress("${File(job.sourceDir).name}: ${files.size} файлов")

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

        // Хэшируем всех кандидатов одним проходом: эти же хэши нужны и для переносов, и для дедупа.
        val hashed = ArrayList<Triple<LocalFile, Db.Item?, String>>(candidates.size)
        for ((file, item) in candidates) {
            if (file.size == 0L) continue
            hashed.add(Triple(file, item, Hasher.sha256(File(file.path))))
        }

        // Переименование или перенос на телефоне — это НЕ «удалили и залили заново»: сопоставляем
        // исчезнувшее с появившимся по содержимому и отправляем серверу move. Так сохраняется id
        // записи, корзина не мусорится, а второе устройство видит перемещение.
        val vanished = known.filter { it.relPath !in seen && it.state != Db.STATE_EVICTED && it.remoteEntryId != null }
        val appeared = hashed.filter { it.second == null }
        val movedPairs = matchMoves(vanished, appeared)
        val movedOld = HashSet<String>()
        val movedNew = HashSet<String>()
        for ((old, file) in movedPairs) {
            val newDir = file.relPath.substringBeforeLast('/', "")
            val targetFolderId = remoteFolderFor(job, newDir)
            try {
                api.moveFile(old.remoteEntryId!!, targetFolderId, file.name)
            } catch (e: Exception) {
                stats.errors += 1
                Log.w(TAG, "перенос ${old.relPath} → ${file.relPath} не прошёл: ${e.message}")
                continue
            }
            db.deleteItem(job.id, old.relPath)
            db.putItem(
                old.copy(
                    relPath = file.relPath,
                    localPath = file.path,
                    localSize = file.size,
                    localMtime = file.mtime,
                    name = file.name,
                    remoteFolderId = targetFolderId,
                    state = Db.STATE_SYNCED,
                ),
            )
            movedOld.add(old.relPath)
            movedNew.add(file.relPath)
            Log.i(TAG, "перенос: ${old.relPath} → ${file.relPath}")
        }

        // Локальные удаления: было в base, локально исчезло и ни с чем не совпало по содержимому.
        for (item in known) {
            if (item.relPath in seen || item.relPath in movedOld) continue
            if (item.state == Db.STATE_EVICTED) continue
            if (item.remoteEntryId == null) {
                db.deleteItem(job.id, item.relPath)
                continue
            }
            if (item.keepOffline) {
                Log.i(TAG, "не удаляю закреплённое локально: ${item.relPath}")
                continue
            }
            db.enqueueOp(job.id, item.relPath, Db.OP_DELETE)
        }

        val shas = hashed.filter { entry -> entry.second?.sha256 != entry.third }.map { it.third }
        val present = if (shas.isEmpty()) emptySet() else runCatching { api.have(shas.distinct().take(500)) }.getOrDefault(emptySet())

        for ((file, item, sha) in hashed) {
            if (file.relPath in movedNew) continue
            if (item == null) {
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
                        remoteFolderId = remoteFolderFor(job, file.relPath.substringBeforeLast('/', "")),
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

        // Скачивание вниз: зеркало (папка без вытеснения) либо закрепление. Закрепление перекрывает
        // срок хранения — «держать офлайн» должно дотягивать отсутствующее, иначе оно врёт.
        val pinnedFolders = pinned()
        val jobPinned = job.targetFolderId in pinnedFolders
        val mirror = job.zone == "FILES" && job.keepDays < 0
        if (mirror || jobPinned) mirrorDown(job, stats, onProgress)
        else downloadPinnedFiles(job, stats, onProgress)
        if (job.keepDays >= 0 && !jobPinned) evict(job, onProgress)
    }

    /**
     * Пары «исчезло/появилось» по совпадению sha256. Сначала ищем пары в одном каталоге
     * (обычное переименование), потом — единственные совпадения по всему дереву задачи.
     */
    private fun matchMoves(
        vanished: List<Db.Item>,
        appeared: List<Triple<LocalFile, Db.Item?, String>>,
    ): List<Pair<Db.Item, LocalFile>> {
        val usedOld = HashSet<String>()
        val pairs = ArrayList<Pair<Db.Item, LocalFile>>()
        // Сначала пары внутри одного каталога (обычное переименование), затем — единственное
        // совпадение по содержимому во всём дереве задачи (перенос в другую папку).
        for (pass in 0..1) {
            for ((file, _, sha) in appeared) {
                if (pairs.any { it.second.relPath == file.relPath }) continue
                val dir = file.relPath.substringBeforeLast('/', "")
                val candidates = vanished.filter { old ->
                    old.relPath !in usedOld && old.sha256 == sha &&
                        (pass == 1 || old.relPath.substringBeforeLast('/', "") == dir)
                }
                if (candidates.size != 1 && pass == 1) continue
                val candidate = candidates.firstOrNull() ?: continue
                usedOld.add(candidate.relPath)
                pairs.add(candidate to file)
            }
        }
        return pairs
    }

    // ===== очередь операций =====

    private fun runOps(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        while (true) {
            val op = db.nextOpForJob(job.id, System.currentTimeMillis()) ?: break
            try {
                when (op.kind) {
                    Db.OP_UPLOAD -> handleUpload(job, op, stats, onProgress)
                    Db.OP_DELETE -> handleDelete(job, op, stats)
                    Db.OP_DOWNLOAD -> handleDownload(job, op, stats, onProgress)
                    else -> db.deleteOp(op.id)
                }
            } catch (e: ApiException) {
                when {
                    e.code == "stale_version" -> handleStale(job, op)
                    e.code == "in_trash" -> handleInTrash(job, op)
                    e.code == "conflict" || (e.message ?: "").contains("already exists") -> handleNameTaken(job, op, stats)
                    e.code == "upload_session_lost" -> {
                        // сервер потерял состояние релей-сессии — начинаем загрузку заново
                        db.updateOp(op.id, mapOf("upload_id" to null, "next_attempt_at" to System.currentTimeMillis() + 5_000))
                    }
                    else -> retry(op, e.message ?: "ошибка API", stats)
                }
            } catch (e: Exception) {
                retry(op, e.message ?: "ошибка", stats)
            }
        }
    }

    private fun handleUpload(job: Db.Job, op: Db.Op, stats: Stats, onProgress: (String) -> Unit) {
        val item = db.item(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val file = File(item.localPath)
        if (!file.isFile) {
            db.deleteOp(op.id)
            db.deleteItem(job.id, op.relPath)
            return
        }
        val sha = item.sha256 ?: Hasher.sha256(file).also { db.updateItem(job.id, op.relPath, mapOf("sha256" to it)) }
        val replace = item.remoteEntryId != null
        onProgress("загрузка: ${item.name}")
        val result = Uploader(api).upload(
            folderId = remoteFolderFor(job, item.relPath.substringBeforeLast('/', "")),
            file = LocalFile(item.relPath, item.localPath, item.name, item.localSize, item.localMtime),
            sha256 = sha,
            replace = replace,
            expectedSha256 = if (replace) item.remoteSha256 else null,
            uploadIdFromQueue = op.uploadId,
            onSession = { id -> db.updateOp(op.id, mapOf("upload_id" to id)) },
            onProgress = { sent, total ->
                val pct = if (total > 0) (sent * 100 / total).toInt() else 0
                onProgress("загрузка ${item.name}: $pct%")
            },
        )
        if (result.stale) {
            handleStale(job, op)
            return
        }
        if (result.inTrash) {
            handleInTrash(job, op)
            return
        }
        db.updateItem(
            job.id,
            op.relPath,
            mapOf(
                "state" to Db.STATE_SYNCED,
                "remote_entry_id" to result.entryId.ifBlank { item.remoteEntryId ?: "" },
                "remote_sha256" to sha,
                "uploaded_at" to System.currentTimeMillis(),
            ),
        )
        db.deleteOp(op.id)
        if (result.deduped) stats.deduped += 1 else stats.uploaded += 1
    }

    /** Явный запрос «вернуть на телефон» (в том числе для вытесненного файла). */
    private fun handleDownload(job: Db.Job, op: Db.Op, stats: Stats, onProgress: (String) -> Unit) {
        val item = db.item(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val entryId = item.remoteEntryId ?: run {
            // записи на сервере нет — возвращать нечего
            db.deleteOp(op.id)
            return
        }
        val target = File(item.localPath.ifBlank { File(job.sourceDir, item.relPath).absolutePath })
        onProgress("возврат: ${item.name}")
        Downloader.download(api, entryId, target, null)
        db.updateItem(
            job.id,
            op.relPath,
            mapOf(
                "local_path" to target.absolutePath,
                "local_size" to target.length(),
                "local_mtime" to target.lastModified(),
                "state" to Db.STATE_SYNCED,
            ),
        )
        db.deleteOp(op.id)
        stats.downloaded += 1
    }

    private fun handleDelete(job: Db.Job, op: Db.Op, stats: Stats) {
        val item = db.item(job.id, op.relPath)
        val entryId = item?.remoteEntryId
        if (entryId != null) api.deleteFile(entryId)
        db.deleteItem(job.id, op.relPath)
        db.deleteOp(op.id)
        stats.deleted += 1
    }

    /**
     * Локальная правка против изменившейся серверной версии: локальный файл становится
     * «конфликтной копией» и уезжает отдельной записью, канонический файл на сервере не трогаем.
     */
    private fun handleStale(job: Db.Job, op: Db.Op) {
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
            // переименовать не удалось — не долбим сервер тем же самым, ждём следующего прохода
            db.updateOp(op.id, mapOf("last_error" to "конфликт версий", "next_attempt_at" to System.currentTimeMillis() + 3_600_000))
        }
    }

    /**
     * Файл с таким именем лежит в корзине сервера. Возвращать его сами не имеем права (корзина —
     * решение пользователя), поэтому помечаем состояние и больше не повторяем бесконечно.
     */
    private fun handleInTrash(job: Db.Job, op: Db.Op) {
        db.updateItem(job.id, op.relPath, mapOf("state" to Db.STATE_SYNCED, "remote_sha256" to null))
        db.updateOp(op.id, mapOf("last_error" to "имя занято корзиной сервера", "next_attempt_at" to Long.MAX_VALUE / 2))
        Log.w(TAG, "файл в корзине сервера: ${op.relPath}")
    }

    /**
     * Имя занято записью на сервере (загружено из веба, с другого устройства или после полного
     * рескана). Совпал хэш — просто фиксируем состояние; не совпал — заливаем как замену строго,
     * с ожидаемой версией, чтобы сервер подтвердил, что мы правим актуальное содержимое.
     */
    private fun handleNameTaken(job: Db.Job, op: Db.Op, stats: Stats) {
        val item = db.item(job.id, op.relPath) ?: run { db.deleteOp(op.id); return }
        val remoteFolderId = remoteFolderFor(job, item.relPath.substringBeforeLast('/', ""))
        val remote = runCatching { api.children(remoteFolderId).entries.firstOrNull { it.name == item.name } }.getOrNull()
        if (remote == null) {
            retry(op, "имя занято, но запись не найдена", stats)
            return
        }
        if (remote.sha256 == item.sha256) {
            db.updateItem(
                job.id,
                op.relPath,
                mapOf(
                    "state" to Db.STATE_SYNCED,
                    "remote_entry_id" to remote.id,
                    "remote_sha256" to remote.sha256,
                    "uploaded_at" to System.currentTimeMillis(),
                ),
            )
            db.deleteOp(op.id)
            stats.deduped += 1
            Log.i(TAG, "уже на сервере (совпало по хэшу): ${item.name}")
        } else {
            db.updateItem(job.id, op.relPath, mapOf("remote_entry_id" to remote.id, "remote_sha256" to remote.sha256))
            db.updateOp(op.id, mapOf("next_attempt_at" to 0, "upload_id" to null))
            stats.conflicts += 1
            Log.i(TAG, "на сервере другая версия ${item.name} — заливаем как замену")
        }
    }

    // ===== зеркало вниз и вытеснение =====

    private fun mirrorDown(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        val remote = ArrayList<Pair<String, ru.cloudly.sync.net.RemoteEntry>>()
        collectRemote(job.targetFolderId, "", remote, 0)
        val known = db.itemsOf(job.id).associateBy { it.relPath }
        for ((relPath, entry) in remote) {
            val item = known[relPath]
            if (item != null) {
                // вытесненное обратно не тянем — иначе смысл вытеснения теряется; исключение — закреплённое
                if (item.state == Db.STATE_EVICTED && !entry.keepOffline && !item.keepOffline) continue
                if (item.remoteSha256 == entry.sha256 && File(item.localPath).isFile) continue
            }
            val target = File(job.sourceDir, relPath)
            onProgress("скачивание: ${entry.name}")
            try {
                Downloader.download(api, entry.id, target, entry.clientMtime)
            } catch (e: Exception) {
                stats.errors += 1
                Log.w(TAG, "не скачался ${entry.name}: ${e.message}")
                continue
            }
            db.putItem(
                Db.Item(
                    jobId = job.id,
                    relPath = relPath,
                    localPath = target.absolutePath,
                    localSize = target.length(),
                    localMtime = target.lastModified(),
                    sha256 = entry.sha256,
                    remoteEntryId = entry.id,
                    remoteSha256 = entry.sha256,
                    remoteFolderId = entry.folderId ?: job.targetFolderId,
                    name = entry.name,
                    state = Db.STATE_SYNCED,
                    keepOffline = entry.keepOffline,
                    uploadedAt = System.currentTimeMillis(),
                ),
            )
            stats.downloaded += 1
        }
    }

    /**
     * Точечный случай: папка со сроком хранения, но отдельные файлы закреплены («держать офлайн»
     * на файл). Их надо вернуть, остальное не трогаем.
     */
    private fun downloadPinnedFiles(job: Db.Job, stats: Stats, onProgress: (String) -> Unit) {
        val pinnedItems = db.itemsOf(job.id).filter { it.keepOffline && it.remoteEntryId != null }
        if (pinnedItems.isEmpty()) return
        for (item in pinnedItems) {
            val target = File(item.localPath.ifBlank { File(job.sourceDir, item.relPath).absolutePath })
            if (target.isFile && item.state == Db.STATE_SYNCED) continue
            onProgress("возврат закреплённого: ${item.name}")
            try {
                Downloader.download(api, item.remoteEntryId!!, target, null)
            } catch (e: Exception) {
                stats.errors += 1
                Log.w(TAG, "не вернулся ${item.name}: ${e.message}")
                continue
            }
            db.updateItem(
                job.id,
                item.relPath,
                mapOf(
                    "local_path" to target.absolutePath,
                    "local_size" to target.length(),
                    "local_mtime" to target.lastModified(),
                    "state" to Db.STATE_SYNCED,
                ),
            )
            stats.downloaded += 1
        }
    }

    private fun collectRemote(
        folderId: String,
        prefix: String,
        out: MutableList<Pair<String, ru.cloudly.sync.net.RemoteEntry>>,
        depth: Int,
    ) {
        if (depth > 32) return
        val children = api.children(folderId)
        for (entry in children.entries) {
            if (entry.size == 0L) continue
            val rel = if (prefix.isEmpty()) entry.name else "$prefix/${entry.name}"
            out.add(rel to entry.copy(folderId = folderId))
        }
        for ((name, id) in children.folderIds) {
            collectRemote(id, if (prefix.isEmpty()) name else "$prefix/$name", out, depth + 1)
        }
    }

    /**
     * Вытеснение выгруженного. Защиты: только подтверждённое сервером содержимое, грейс после
     * загрузки (файл не исчезает из-под рук), закреплённое не трогаем никогда, состояние помечаем
     * `evicted` — иначе скан принял бы это за удаление пользователем и снёс копию в облаке.
     */
    private fun evict(job: Db.Job, onProgress: (String) -> Unit) {
        val keepMs = job.keepDays.toLong() * 24 * 60 * 60 * 1000
        val now = System.currentTimeMillis()
        val grace = 10 * 60 * 1000L
        val pinnedFolders = pinned()
        var evicted = 0
        for (item in db.itemsOf(job.id)) {
            if (item.state != Db.STATE_SYNCED) continue
            if (item.keepOffline) continue
            if (item.remoteFolderId != null && item.remoteFolderId in pinnedFolders) continue
            val uploadedAt = item.uploadedAt ?: continue
            if (now - uploadedAt < keepMs.coerceAtLeast(0) + grace) continue
            if (item.remoteSha256 == null) continue
            val file = File(item.localPath)
            if (!file.isFile) continue
            if (file.delete()) {
                db.updateItem(job.id, item.relPath, mapOf("state" to Db.STATE_EVICTED))
                evicted += 1
            }
        }
        if (evicted > 0) {
            onProgress("освобождено на телефоне: $evicted")
            Log.i(TAG, "вытеснено по сроку: $evicted")
        }
    }

    private fun pinned(): Set<String> =
        (db.kv(KV_PINNED_FOLDERS) ?: "").split(',').filter { it.isNotBlank() }.toSet()

    private fun buildConflictName(name: String, stamp: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) {
            "${name.substring(0, dot)} (конфликт $stamp)${name.substring(dot)}"
        } else {
            "$name (конфликт $stamp)"
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
        Log.w(TAG, "операция ${op.kind} ${op.relPath}: $message (попытка $attempts)")
    }

    /** Служебное: пометить папку на сервере как «держать офлайн». */
    fun setFolderKeepOffline(folderId: String, keepOffline: Boolean) {
        api.patchFolder(folderId, JSONObject().put("keepOffline", keepOffline))
    }

    /** Закрепить или открепить отдельный файл (флаг живёт на сервере). */
    fun setFileKeepOffline(jobId: Long, relPath: String, entryId: String, keepOffline: Boolean) {
        api.patchFile(entryId, JSONObject().put("keepOffline", keepOffline))
        db.updateItem(jobId, relPath, mapOf("keep_offline" to if (keepOffline) 1 else 0))
        if (keepOffline) {
            // закрепили — файл должен быть на телефоне, даже если он был вытеснен
            db.enqueueOp(jobId, relPath, Db.OP_DOWNLOAD)
        }
    }

    /** Разовое «вернуть на телефон» для вытесненного файла. */
    fun restoreToPhone(jobId: Long, relPath: String) {
        db.enqueueOp(jobId, relPath, Db.OP_DOWNLOAD)
    }

    /** Состояние «держать офлайн» у папки задачи (читается с сервера). */
    fun folderPinned(folderId: String): Boolean = runCatching { api.folderMeta(folderId).second }.getOrDefault(false)

    companion object {
        private const val TAG = "cloudly-sync"
        private const val KV_PINNED_FOLDERS = "pinned_folders"
    }
}
