package ru.cloudly.sync.mirror

import android.util.Log
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.CloudChange
import java.io.File

/**
 * Облачная сторона зеркала: то, что изменилось в облаке, доезжает до телефона.
 *
 * Два источника, и оба нужны:
 *   • журнал изменений (`GET /sync/changes`) — обычный путь, курсор по `seq`;
 *   • полный проход по содержимому папок — когда курсора ещё нет (зеркало только включили)
 *     или когда сервер ответил `resetRequired` (журнал подрезан, догнать по нему нельзя).
 *
 * Свои же правки пропускаются: в строке журнала есть `deviceId`, и строка, сделанная этим
 * устройством, локально уже учтена — иначе собственная выгрузка приезжала бы назад и догон
 * зацикливался бы. Дополнительно сверяется хэш содержимого: строки, сделанные до появления
 * `deviceId`, всё равно опознаются по нему.
 *
 * Удаления из облака применяются к телефону без предохранителя — это явное указание сервера,
 * а не догадка по неполному снимку (так же ведёт себя Google Drive). Страховка — корзина
 * на сервере: 30 дней и восстановление.
 */
class MirrorPull(
    private val api: Api,
    private val store: MirrorStore,
    private val deviceId: String?,
    private val onProgress: (String) -> Unit,
) {

    var downloaded = 0
        private set
    var deletedLocal = 0
        private set
    var conflicts = 0
        private set
    var failed = 0
        private set
    var renamedLocal = 0
        private set

    /** Полный проход потребовался (не было курсора или журнал подрезан). */
    var rescanned = false
        private set

    /** Ошибка, после которой проход дальше не имеет смысла (нет сети, отозван токен). */
    var fatal: String? = null
        private set

    /**
     * Догнать облако. Первый раз — полный проход и курсор на текущей голове журнала: сначала
     * голова, потом содержимое. Изменения, случившиеся во время полного прохода, приедут
     * журналом и применятся повторно — применение идемпотентно, а потеряться ничего не может.
     */
    fun catchUp() {
        val cursor = store.cursor()
        if (cursor == null) {
            fullPull()
            store.setCursor(runCatching { api.syncHead() }.getOrDefault(0L))
            return
        }
        var since: Long = cursor
        var guard = 0
        while (guard++ < MAX_PAGES) {
            val page = try {
                api.changes(since)
            } catch (e: Exception) {
                fatal = "журнал изменений недоступен: ${e.message}"
                return
            }
            if (page.resetRequired) {
                // по этому курсору часть изменений уже не восстановить: только полный проход
                Log.i(TAG, "журнал подрезан — полный проход по содержимому")
                fullPull()
                store.setCursor(maxOf(page.nextSeq, runCatching { api.syncHead() }.getOrDefault(0L)))
                return
            }
            for (change in page.changes) {
                if (fatal != null) return
                runCatching { apply(change) }.onFailure {
                    failed += 1
                    Log.w(TAG, "изменение ${change.op} ${change.name}: ${it.message}")
                }
            }
            since = page.nextSeq
            store.setCursor(since)
            if (!page.hasMore) return
        }
        Log.w(TAG, "догон журнала упёрся в предел страниц за проход")
    }

    /** Полный проход по папкам зеркала: состояние облака переносится на телефон. */
    fun fullPull() {
        rescanned = true
        for (root in store.roots().values) {
            if (fatal != null) return
            onProgress("облако: ${root.cloudPath}")
            runCatching { pullFolder(root.cloudId, root.localPath, 0) }.onFailure {
                if (it is java.io.IOException) fatal = "облако недоступно: ${it.message}"
                else failed += 1
                Log.w(TAG, "полный проход ${root.cloudPath}: ${it.message}")
            }
        }
    }

    /** Папка облака целиком: подпапки, затем записи. */
    private fun pullFolder(folderId: String, localPath: String, depth: Int) {
        if (depth > MAX_DEPTH || fatal != null) return
        val dir = File(localPath)
        if (!dir.isDirectory && !dir.mkdirs()) {
            failed += 1
            return
        }
        store.registerDir(folderId, localPath)
        val children = api.children(folderId)
        for ((name, id) in children.folderIds) {
            val childPath = "$localPath/$name"
            val known = store.dirPath(id)
            if (known == null) {
                File(childPath).mkdirs()
                store.registerDir(id, childPath)
            } else if (known != childPath) {
                moveLocalDir(known, childPath)
                store.moveDir(id, childPath)
            }
            pullFolder(id, childPath, depth + 1)
        }
        for (entry in children.entries) {
            if (fatal != null) return
            runCatching {
                reconcile(
                    folderId = folderId,
                    name = entry.name,
                    entryId = entry.id,
                    sha256 = entry.sha256,
                    size = entry.size,
                    clientMtime = entry.clientMtime,
                    localDir = localPath,
                )
            }.onFailure {
                failed += 1
                Log.w(TAG, "запись ${entry.name}: ${it.message}")
            }
        }
    }

    /** Одно изменение журнала. */
    private fun apply(change: CloudChange) {
        // своя же правка: локально она уже сделана тем проходом, который её отправил
        if (deviceId != null && change.deviceId != null && change.deviceId == deviceId) return
        if (change.target == "folder") applyFolder(change) else applyEntry(change)
    }

    private fun applyFolder(change: CloudChange) {
        val known = store.dirPath(change.targetId)
        if (change.op == "delete") {
            if (known == null) return
            // в журнале на папку одно событие: поддерево удалено целиком
            for (row in store.filesUnder(known)) {
                if (File(row.path).delete()) deletedLocal += 1
                store.dropFile(row.path)
            }
            for ((id, _) in store.dirsUnder(known)) store.dropDir(id)
            File(known).deleteRecursively()
            deletedLocal += 1
            return
        }
        // create | update | move | restore: папка должна существовать на телефоне
        val parent = change.folderId?.let { store.dirPath(it) } ?: return
        val path = "$parent/${change.name}"
        if (known != null && known != path) {
            moveLocalDir(known, path)
            store.moveDir(change.targetId, path)
            renamedLocal += 1
            return
        }
        if (known == null) {
            File(path).mkdirs()
            store.registerDir(change.targetId, path)
        }
    }

    private fun applyEntry(change: CloudChange) {
        val parent = change.folderId?.let { store.dirPath(it) } ?: return
        if (change.op == "pin") return
        val path = "$parent/${change.name}"
        if (change.op == "delete") {
            val row = store.fileByEntry(change.targetId)
            val file = row?.let { File(it.path) } ?: File(path)
            if (file.isFile && file.delete()) deletedLocal += 1
            if (row != null) store.dropFile(row.path) else store.dropFile(path)
            return
        }
        reconcile(
            folderId = change.folderId,
            name = change.name,
            entryId = change.targetId,
            sha256 = change.sha256,
            size = change.size,
            clientMtime = change.clientMtime,
            localDir = parent,
        )
    }

    /**
     * Решение по одной записи облака: скачать, перенести или не трогать.
     *
     * Запись, содержимое которой совпадает с уже выгруженным (по хэшу), не скачивается: это
     * либо наша собственная выгрузка, либо файл, который уже лежит на телефоне. Если же
     * на телефоне содержимое своё и отличается — оно не затирается: локальная версия уходит
     * в конфликтную копию, каноническое имя занимает версия облака (так же поступает Drive).
     */
    private fun reconcile(
        folderId: String?,
        name: String,
        entryId: String,
        sha256: String?,
        size: Long,
        clientMtime: Long?,
        localDir: String,
    ) {
        val path = "$localDir/$name"
        var row = store.fileByEntry(entryId)

        // запись переименована или перенесена в облаке: повторяем это на телефоне
        if (row != null && row.path != path) {
            val from = File(row.path)
            val to = File(path)
            if (from.isFile && !to.exists() && from.parentFile?.exists() == true) {
                to.parentFile?.mkdirs()
                if (from.renameTo(to)) {
                    val moved = row.copy(path = path, cloudFolderId = folderId ?: row.cloudFolderId)
                    store.moveFile(row.path, moved)
                    row = moved
                    renamedLocal += 1
                }
            } else if (!from.isFile) {
                row = null
            }
        }

        // содержимое облака — ровно то, что у нас уже есть: скачивать нечего
        if (row != null && sha256 != null && row.sha256.equals(sha256, ignoreCase = true)) return

        val file = File(path)
        if (!file.isFile) {
            downloadInto(entryId, folderId, path, sha256, size, clientMtime)
            return
        }

        // локальный файл не менялся с прошлой сверки — облако новее, скачиваем
        val localUntouched = row != null && row.size == file.length() && row.mtime == file.lastModified()
        // файла нет в известных (строка потеряна или файл появился до включения зеркала):
        // содержимое совпадает по размеру и дате устройства-источника — значит это он и есть
        val adopted = row == null && clientMtime != null && clientMtime > 0 &&
            file.length() == size && file.lastModified() == clientMtime
        if (adopted) {
            store.putFile(
                MirrorRow(
                    path = path,
                    cloudFolderId = folderId.orEmpty(),
                    entryId = entryId,
                    inode = inodeOf(file),
                    size = file.length(),
                    mtime = file.lastModified(),
                    sha256 = sha256,
                ),
            )
            return
        }
        if (localUntouched) {
            downloadInto(entryId, folderId, path, sha256, size, clientMtime)
            return
        }

        // менялось и там, и тут: никто не затирается молча
        val conflict = File(localDir, MirrorRules.conflictName(name, System.currentTimeMillis()))
        if (!file.renameTo(conflict)) {
            failed += 1
            onProgress("не удалось отодвинуть ${name} — конфликт не разрешён")
            return
        }
        conflicts += 1
        // строку снимаем: конфликтную копию выгрузит следующий проход как новый файл
        row?.let { store.dropFile(it.path) }
        downloadInto(entryId, folderId, path, sha256, size, clientMtime)
    }

    /** Скачать запись в путь на телефоне и запомнить её как выгруженную. */
    fun downloadInto(
        entryId: String,
        folderId: String?,
        path: String,
        sha256: String?,
        size: Long,
        clientMtime: Long?,
    ): Boolean {
        val dest = File(path)
        dest.parentFile?.let { if (!it.isDirectory) it.mkdirs() }
        return try {
            api.downloadToFile(entryId, dest, sha256)
            // дата файла берётся с устройства-источника: иначе следующий проход счёл бы
            // только что скачанный файл изменённым на телефоне и выгрузил бы его назад
            if (clientMtime != null && clientMtime > 0) dest.setLastModified(clientMtime)
            store.putFile(
                MirrorRow(
                    path = dest.absolutePath,
                    cloudFolderId = folderId.orEmpty(),
                    entryId = entryId,
                    inode = inodeOf(dest),
                    size = dest.length(),
                    mtime = dest.lastModified(),
                    sha256 = sha256,
                ),
            )
            downloaded += 1
            onProgress("скачано: ${dest.name}")
            true
        } catch (e: Exception) {
            failed += 1
            onProgress("не скачалось ${dest.name}: ${e.message}")
            false
        }
    }

    /** Переименование или перенос папки на телефоне вместе со всем, что под ней. */
    private fun moveLocalDir(fromPath: String, toPath: String) {
        val from = File(fromPath)
        val to = File(toPath)
        to.parentFile?.mkdirs()
        if (from.isDirectory && !to.exists()) from.renameTo(to)
        val prefix = "$fromPath/"
        for (row in store.filesUnder(fromPath)) {
            val path = toPath + row.path.removePrefix(fromPath)
            store.moveFile(row.path, row.copy(path = path))
        }
        for ((id, path) in store.dirsUnder(fromPath)) {
            if (path == fromPath) continue
            store.moveDir(id, toPath + path.removePrefix(fromPath))
        }
    }

    private companion object {
        const val TAG = "cloudly-mirror"

        /** Потолок страниц журнала за один проход: остальное доедет следующим. */
        const val MAX_PAGES = 200

        /** Потолок глубины обхода облака: защита от петли в дереве. */
        const val MAX_DEPTH = 64
    }
}
