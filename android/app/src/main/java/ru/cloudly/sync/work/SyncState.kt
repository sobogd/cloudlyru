package ru.cloudly.sync.work

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import ru.cloudly.sync.App
import ru.cloudly.sync.data.QueueState
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.queue.Candidate
import ru.cloudly.sync.queue.UploadedKey

/**
 * Снимок телефона для сервера: что у него есть и что с этим происходит.
 *
 * Строится из результата последнего прохода по папкам (`App.lastCandidates`, `App.lastDirs`),
 * а не из нового сканирования диска: иначе каждое обновление состояния стоило бы полного
 * обхода, и статусы в вебе отставали бы на минуты.
 *
 * Отправляется только то, чего нет в облаке: скелет папок и файлы, которые ещё не выгружены
 * или стоят в очереди. Выгруженное веб видит в облачном дереве и без снимка.
 */
object SyncState {

    /** Предел на снимок: больше всё равно никто не читает, а сеть и сервер жалко. */
    private const val MAX_ENTRIES = 20_000

    fun build(context: Context): JSONArray {
        val app = App.of(context)
        val queue = app.queueStore.items(MAX_ENTRIES)
        val uploaded = app.queueStore.uploaded()
        val byTargetPath = queue.associateBy { UploadedKey(it.path, it.target) }

        val entries = JSONArray()
        var truncated = false

        for (section in Section.entries) {
            val target = when (section) {
                Section.FILES -> app.prefs.phoneFolderId
                Section.PHOTOS -> app.prefs.photoFolderId
            }.takeIf { it.isNotBlank() } ?: continue

            // скелет папок: без него в вебе не видно структуры, пока ничего не выгружено
            for ((dirSection, rel, name) in app.lastDirs) {
                if (dirSection != section.name) continue
                if (entries.length() >= MAX_ENTRIES) {
                    truncated = true
                    break
                }
                entries.put(entry(section.name, rel, name, isDir = true, size = 0, mtime = null, state = "LOCAL"))
            }

            for (file in app.lastCandidates) {
                if (file.sectionFor(app) != section) continue
                if (entries.length() >= MAX_ENTRIES) {
                    truncated = true
                    break
                }
                val key = UploadedKey(file.path, target)
                val queued = byTargetPath[key]
                val already = uploaded[key]
                val uploadedHere = already != null && already.size == file.size && already.mtime == file.mtime
                // уже в облаке и не в очереди — веб видит файл в облачном дереве
                if (uploadedHere && queued == null) continue
                entries.put(
                    entry(
                        section = section.name,
                        path = if (section == Section.FILES) file.relDir + "/" + file.name else file.name,
                        name = file.name,
                        isDir = false,
                        size = file.size,
                        mtime = file.mtime,
                        state = queued?.state?.name ?: "LOCAL",
                        error = queued?.lastError,
                        localPath = file.path,
                    ),
                )
            }
        }

        if (truncated) {
            entries.put(entry("FILES", "…", "снимок обрезан", isDir = false, size = 0, mtime = null, state = "LOCAL"))
        }
        return entries
    }

    /** Короткая сводка для уведомления и для строки состояния в приложении. */
    fun summary(context: Context): String {
        val counts = App.of(context).queueStore.counts()
        val pending = (counts[QueueState.PENDING] ?: 0) + (counts[QueueState.FAILED] ?: 0)
        val running = counts[QueueState.RUNNING] ?: 0
        val done = (counts[QueueState.DONE] ?: 0) + (counts[QueueState.SKIPPED] ?: 0)
        return buildString {
            append("ждут: $pending")
            if (running > 0) append(" · идёт: $running")
            append(" · выгружено: $done")
        }
    }

    /** Раздел файла берётся из его цели: у «Файлов» и «Фото» разные облачные папки. */
    private fun Candidate.sectionFor(app: App): Section =
        if (app.prefs.photoFolderId.isNotBlank() && target == app.prefs.photoFolderId) Section.PHOTOS else Section.FILES

    private fun entry(
        section: String,
        path: String,
        name: String,
        isDir: Boolean,
        size: Long,
        mtime: Long?,
        state: String,
        error: String? = null,
        localPath: String? = null,
    ): JSONObject = JSONObject().apply {
        put("section", section)
        put("path", path)
        // абсолютный путь нужен, чтобы веб мог попросить выгрузить именно этот файл
        if (!localPath.isNullOrBlank()) put("localPath", localPath)
        put("name", name)
        put("isDir", isDir)
        put("size", size)
        if (mtime != null && mtime > 0) put("mtime", java.time.Instant.ofEpochMilli(mtime).toString())
        put("state", state)
        if (!error.isNullOrBlank()) put("error", error.take(300))
    }
}
