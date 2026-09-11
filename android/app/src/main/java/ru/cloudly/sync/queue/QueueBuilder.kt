package ru.cloudly.sync.queue

import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.device.DeviceFiles

/**
 * Наполнение очереди: пройти выбранные папки обоих разделов, сравнить с тем, что уже
 * известно, и поставить новое и изменённое в очередь.
 *
 * Ничего не запускает: запуск — ручной, кнопкой на строке. Здесь только подготовка.
 */
class QueueBuilder(
    private val files: DeviceFiles,
    private val store: QueueStore,
) {

    data class Result(
        val scanned: Int,
        val queued: Int,
        val removed: Int,
        val skipped: Int,
        val capped: Boolean,
        val unreadable: Int,
        /** Что помешало части работы: нет входа в аккаунт, нет цели для раздела. */
        val problem: String? = null,
    ) {
        fun text(): String = buildString {
            append("проверено файлов: $scanned, новых в очереди: $queued")
            if (removed > 0) append(", убрано из очереди: $removed")
            if (unreadable > 0) append(", папок без доступа: $unreadable")
            if (capped) append(", обход упёрся в предел")
            problem?.let { append(" · $it") }
        }
    }

    /**
     * @param phoneFolderId корень зеркала в облаке для раздела «Файлы»
     * @param photoFolderId медиатека для раздела «Фото» (туда льём плоско)
     */
    fun build(
        selection: Selection,
        phoneFolderId: String?,
        photoFolderId: String?,
        onProgress: (String) -> Unit = {},
        isCancelled: () -> Boolean = { false },
    ): Result {
        val targets = mapOf(Section.FILES to phoneFolderId, Section.PHOTOS to photoFolderId)
        val problems = ArrayList<String>()
        val candidates = ArrayList<Candidate>()
        val scannedSections = HashSet<Section>()
        var scanned = 0
        var unreadable = 0
        var capped = false

        for (section in Section.entries) {
            if (isCancelled()) break
            val target = targets[section]
            if (target.isNullOrBlank()) {
                // Цель раздела неизвестна (не выполнен вход) — раздел не сканируем и НЕ считаем
                // пройденным: иначе уборка выкосила бы его строки из-за одной неполадки.
                problems.add(
                    if (section == Section.FILES) {
                        "«Файлы»: папка «Телефон» неизвестна — войдите в аккаунт"
                    } else {
                        "«Фото»: медиатека неизвестна — войдите в аккаунт"
                    },
                )
                continue
            }
            // Цель есть — раздел пройден целиком, даже если папок в нём не выбрано:
            // тогда его строки из очереди убираются. Без этого отключённая последняя папка
            // оставалась в очереди навсегда.
            scannedSections.add(section)
            val paths = selection.paths(section)
            if (paths.isEmpty()) continue
            val label = if (section == Section.FILES) "Файлы" else "Фото"
            val result = files.scan(
                paths = paths,
                limit = 0,
                onProgress = { onProgress("$label: $it") },
                isCancelled = isCancelled,
            )
            scanned += result.total
            unreadable += result.unreadable
            capped = capped || result.capped
            for (file in result.files) {
                candidates.add(
                    Candidate(
                        path = file.path,
                        // «Фото» ложится плоско: структуру повторяет только раздел «Файлы»
                        relDir = if (section == Section.FILES) file.relDir else "",
                        name = file.name,
                        size = file.size,
                        mtime = file.mtime,
                        section = section,
                        target = target,
                    ),
                )
            }
        }

        val planned = QueuePlanner.plan(candidates, store.uploaded())
        val added = store.enqueue(planned)
        // и убираем то, чего в выбранных папках больше нет: иначе отключённая папка
        // оставалась бы в очереди навсегда
        val keep = candidates.map { UploadedKey(it.path, it.target) }.toSet()
        val removed = store.prune(keep, scannedSections)

        return Result(
            scanned = scanned,
            queued = added,
            removed = removed,
            skipped = candidates.size - planned.size,
            capped = capped,
            unreadable = unreadable,
            problem = problems.takeIf { it.isNotEmpty() }?.joinToString("; "),
        )
    }
}
