package ru.cloudly.sync.mirror

import android.util.Log
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.data.SelectionRules
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.device.Hasher
import ru.cloudly.sync.device.MediaRules
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import ru.cloudly.sync.queue.UploadPlan
import ru.cloudly.sync.queue.Uploader
import java.io.File

/**
 * Двустороннее зеркало выбранных папок раздела «Файлы»: содержимое телефона и папки в облаке
 * совпадает в обе стороны — как «зеркалирование» в Google Drive, но без «оптимизировать место»:
 * приложение никогда не удаляет файл на телефоне ради свободного места.
 *
 * Порядок прохода:
 *   1. корни — выбранная папка телефона получает свою папку в облаке;
 *   2. облако → телефон: догон журнала (или полный проход, если курсора ещё нет);
 *   3. телефон → облако: новые и изменившиеся файлы, переименования, удаления.
 *
 * Облако идёт первым не случайно: решения по телефону принимаются по свежему состоянию
 * облака, иначе проход выгрузил бы версию, которую в облаке только что заменили.
 *
 * Предохранители, без которых зеркало однажды выкосит облако:
 *   • папка не читается или обход неполный — удаления в облаке не отправляются вовсе;
 *   • пропало слишком много за один проход — удаления приостанавливаются до подтверждения.
 * Снятие галочки с папки удалением не считается: удаление приходит только из сравнения
 * с файловой системой.
 */
class MirrorEngine(
    private val api: Api,
    private val store: MirrorStore,
    private val selection: Selection,
) {

    /** Итог прохода: что удалось, что нет и почему. */
    data class Report(
        var uploaded: Int = 0,
        var downloaded: Int = 0,
        var renamed: Int = 0,
        var deletedInCloud: Int = 0,
        var deletedOnPhone: Int = 0,
        var conflicts: Int = 0,
        var failed: Int = 0,
        var unreadable: Int = 0,
        var capped: Boolean = false,
        var blockedDeletes: Int = 0,
        var blockedReason: String? = null,
        var rescanned: Boolean = false,
        var stopped: Boolean = false,
        var error: String? = null,
        var finishedAt: Long = System.currentTimeMillis(),
    ) {
        fun text(): String = buildString {
            append("выгружено: $uploaded, скачано: $downloaded")
            if (renamed > 0) append(", переименовано: $renamed")
            if (deletedInCloud > 0) append(", удалено в облаке: $deletedInCloud")
            if (deletedOnPhone > 0) append(", удалено на телефоне: $deletedOnPhone")
            if (conflicts > 0) append(", конфликтов: $conflicts")
            if (failed > 0) append(", ошибок: $failed")
            if (unreadable > 0) append(", папок без доступа: $unreadable")
            if (capped) append(", обход неполный")
            if (blockedDeletes > 0) append(", удаления приостановлены: $blockedDeletes")
            if (stopped) append(", проход не закончен — продолжу в следующий раз")
            error?.let { append(" · $it") }
        }
    }

    /**
     * @param budgetMs сколько можно работать за один проход. Фоновая работа ограничена системой,
     *        а выгрузка гигабайтов идёт часами: остаток доедет следующим проходом.
     */
    fun pass(
        onProgress: (String) -> Unit = {},
        isCancelled: () -> Boolean = { false },
        budgetMs: Long = DEFAULT_BUDGET_MS,
    ): Report {
        val startedAt = System.currentTimeMillis()
        val report = Report()

        val me = try {
            api.meInfo()
        } catch (e: Exception) {
            return report.apply { error = "нет связи с сервером: ${e.message}" }
        }
        val mirrorRootId = me.mirrorFolderId
            ?: return report.apply { error = "сервер не отдал корень зеркала — проверьте подключение" }
        store.setMeta(MirrorStore.KEY_DEVICE_ID, me.deviceId.orEmpty())

        val folders = MirrorFolders(api, store)
        val roots = SelectionRules.scanRoots(selection.paths(Section.FILES).toSet())
        // папку сняли с выбора: пару убираем, а строки выгруженного остаются — вернуть выбор
        // можно без повторной заливки и без удаления в облаке
        for (gone in store.roots().keys.filter { it !in roots }) store.dropRoot(gone)
        for (root in roots) {
            if (isCancelled()) return report.apply { stopped = true }
            val name = root.substringAfterLast('/')
            try {
                store.putRoot(root, folders.ensure(name, root, mirrorRootId), name)
            } catch (e: Exception) {
                report.failed += 1
                Log.w(TAG, "корень $root: ${e.message}")
            }
        }

        // 1) облако → телефон
        val pull = MirrorPull(api, store, me.deviceId, onProgress)
        if (roots.isNotEmpty()) {
            onProgress("догоняю облако…")
            pull.catchUp()
        }
        report.downloaded += pull.downloaded
        report.deletedOnPhone += pull.deletedLocal
        report.conflicts += pull.conflicts
        report.renamed += pull.renamedLocal
        report.failed += pull.failed
        report.rescanned = pull.rescanned
        if (pull.fatal != null) return report.apply { error = pull.fatal }

        // 2) телефон → облако
        if (roots.isNotEmpty()) {
            pushLocal(roots, folders, mirrorRootId, pull, report, onProgress, isCancelled, startedAt, budgetMs)
        }

        report.finishedAt = System.currentTimeMillis()
        store.setMeta(MirrorStore.KEY_REPORT, report.text())
        return report
    }

    private fun pushLocal(
        roots: List<String>,
        folders: MirrorFolders,
        mirrorRootId: String,
        pull: MirrorPull,
        report: Report,
        onProgress: (String) -> Unit,
        isCancelled: () -> Boolean,
        startedAt: Long,
        budgetMs: Long,
    ) {
        val snapshot = MirrorScanner().snapshot(roots, onProgress, isCancelled)
        report.unreadable = snapshot.unreadable
        report.capped = snapshot.capped

        // структура в облаке повторяет структуру телефона, включая пустые папки
        for (dir in snapshot.dirs) {
            if (isCancelled()) {
                report.stopped = true
                return
            }
            try {
                folders.ensure(dir.relDir, dir.path, mirrorRootId)
            } catch (e: Exception) {
                report.failed += 1
                Log.w(TAG, "папка ${dir.relDir}: ${e.message}")
            }
        }

        val confirmed = store.meta(MirrorStore.KEY_CONFIRMED) == "1"
        if (confirmed) store.clearMeta(MirrorStore.KEY_CONFIRMED)
        val deletionsAllowed = MirrorRules.deletionsAllowed(snapshot)
        // строки, относящиеся к выбранным сейчас папкам: у папки, снятой с выбора, файлов
        // в снимке нет, и без этого фильтра сверка удалила бы её содержимое в облаке
        val known = store.files().toMutableMap()
        val inRoots = MirrorRules.underRoots(known, roots)
        val plan = MirrorRules.plan(snapshot.files, inRoots, System.currentTimeMillis(), deletionsAllowed, confirmed)

        if (plan.blocked) {
            val reason = if (deletionsAllowed) {
                "одним проходом пропало слишком много файлов"
            } else {
                "часть папок не читается или обход неполный"
            }
            store.setMeta(MirrorStore.KEY_BLOCKED, "${plan.blockedCount}|$reason")
            report.blockedDeletes = plan.blockedCount
            report.blockedReason = reason
        } else {
            store.clearMeta(MirrorStore.KEY_BLOCKED)
        }

        // переименования первыми: выгрузка изменившегося файла пойдёт уже по новому пути
        for ((row, file) in plan.renames) {
            if (outOfTime(startedAt, budgetMs) || isCancelled()) {
                report.stopped = true
                return
            }
            val folderId = store.dirId(file.dir) ?: row.cloudFolderId
            try {
                api.moveFile(row.entryId, folderId, file.name)
                val moved = MirrorRow(file.path, folderId, row.entryId, file.inode, file.size, file.mtime, row.sha256)
                known.remove(row.path)
                known[file.path] = moved
                store.moveFile(row.path, moved)
                report.renamed += 1
                onProgress("переименовано: ${file.name}")
            } catch (e: Exception) {
                report.failed += 1
                Log.w(TAG, "переименование ${row.path} → ${file.path}: ${e.message}")
            }
        }

        for (file in plan.uploads) {
            if (outOfTime(startedAt, budgetMs) || isCancelled()) {
                report.stopped = true
                return
            }
            val folderId = store.dirId(file.dir)
            if (folderId == null) {
                report.failed += 1
                continue
            }
            try {
                upload(file, folderId, known, pull, report, onProgress)
            } catch (e: Exception) {
                report.failed += 1
                onProgress("не выгрузилось ${file.name}: ${e.message}")
                Log.w(TAG, "выгрузка ${file.path}: ${e.message}")
            }
        }

        for (row in plan.deletes) {
            if (outOfTime(startedAt, budgetMs) || isCancelled()) {
                report.stopped = true
                return
            }
            try {
                api.deleteFile(row.entryId)
                known.remove(row.path)
                store.dropFile(row.path)
                report.deletedInCloud += 1
                onProgress("удалено в облаке: ${File(row.path).name}")
            } catch (e: ApiException) {
                // 404 — записи в облаке уже нет: строку всё равно убираем, иначе будем
                // пытаться удалить её в каждом проходе
                if (e.status == 404) {
                    known.remove(row.path)
                    store.dropFile(row.path)
                } else {
                    report.failed += 1
                    Log.w(TAG, "удаление ${row.path}: ${e.message}")
                }
            } catch (e: Exception) {
                report.failed += 1
                Log.w(TAG, "удаление ${row.path}: ${e.message}")
            }
        }
    }

    /**
     * Выгрузка одного файла. Если сервер отвечает, что версия на его стороне другая или что имя
     * занято, — это конфликт: содержимое обеих сторон сохраняется, каноническое имя занимает
     * версия облака, локальная уезжает копией с пометкой. Молча затирать нельзя ни там, ни тут.
     */
    private fun upload(
        file: LocalFile,
        folderId: String,
        known: MutableMap<String, MirrorRow>,
        pull: MirrorPull,
        report: Report,
        onProgress: (String) -> Unit,
    ) {
        val local = File(file.path)
        if (!local.isFile) return
        val row = known[file.path]
        val sha = Hasher.sha256(local)
        val result = try {
            Uploader(api).upload(
                folderId = folderId,
                file = local,
                cloudName = file.name,
                mime = MediaRules.mimeOf(file.name),
                sha256 = sha,
                replace = row != null,
                expectedSha256 = row?.sha256,
                onSession = {},
                onProgress = { sent, total -> onProgress("${file.name}: $sent из $total") },
            )
        } catch (e: ApiException) {
            if (e.code == "stale_version" || e.code == "conflict" || e.code == "in_trash") {
                resolveConflict(file, folderId, known, pull, report, onProgress)
                return
            }
            throw e
        }
        // размер и дата берутся из снимка, по которому считался хэш: если файл успел измениться
        // во время выгрузки, строка останется несовпадающей и следующий проход выгрузит его снова
        val fresh = MirrorRow(file.path, folderId, result.entryId, file.inode, file.size, file.mtime, sha)
        known[file.path] = fresh
        store.putFile(fresh)
        report.uploaded += 1
        onProgress("выгружено: ${file.name}")
    }

    /**
     * Конфликт версий. Локальное содержимое сохраняется копией с пометкой, а по каноническому
     * имени скачивается версия облака — так не теряется ни одна из сторон.
     *
     * Если записи с таким именем в облаке нет (имя занято записью из корзины), не делаем ничего
     * и говорим об этом: воскрешать чужую корзину самостоятельно нельзя.
     */
    private fun resolveConflict(
        file: LocalFile,
        folderId: String,
        known: MutableMap<String, MirrorRow>,
        pull: MirrorPull,
        report: Report,
        onProgress: (String) -> Unit,
    ) {
        val local = File(file.path)
        val remote = runCatching { api.children(folderId).entries }.getOrNull()
        if (remote == null) {
            report.failed += 1
            onProgress("конфликт по «${file.name}»: не удалось прочитать папку облака")
            return
        }
        val cloudEntry = remote.firstOrNull { it.name == file.name }
        if (cloudEntry == null) {
            report.failed += 1
            onProgress("«${file.name}»: имя занято записью в корзине облака — разберите корзину")
            return
        }
        val taken = remote.map { it.name }.toHashSet()
        val copyName = UploadPlan.freeName(MirrorRules.conflictName(file.name, System.currentTimeMillis()), taken)
        try {
            Uploader(api).upload(
                folderId = folderId,
                file = local,
                cloudName = copyName,
                mime = MediaRules.mimeOf(file.name),
                sha256 = Hasher.sha256(local),
                replace = false,
                expectedSha256 = null,
                onSession = {},
                onProgress = { _, _ -> },
            )
        } catch (e: Exception) {
            report.failed += 1
            onProgress("конфликтная копия «$copyName» не уехала: ${e.message}")
            return
        }
        report.conflicts += 1
        onProgress("конфликт: «${file.name}» сохранён как «$copyName», по основному имени — версия облака")
        known.remove(file.path)
        store.dropFile(file.path)
        val ok = pull.downloadInto(cloudEntry.id, folderId, file.path, cloudEntry.sha256, cloudEntry.size, cloudEntry.clientMtime)
        if (ok) report.downloaded += 1 else report.failed += 1
    }

    private fun outOfTime(startedAt: Long, budgetMs: Long): Boolean =
        System.currentTimeMillis() - startedAt > budgetMs

    private companion object {
        const val TAG = "cloudly-mirror"

        /** Проход ограничен по времени: фоновая работа под присмотром системы, а не вечная. */
        const val DEFAULT_BUDGET_MS = 8 * 60_000L
    }
}
