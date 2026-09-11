package ru.cloudly.sync.mirror

import ru.cloudly.sync.data.SelectionRules
import ru.cloudly.sync.device.MediaRules
import java.io.File

/**
 * Снимок выбранных папок раздела «Файлы» для сверки.
 *
 * Отдельно от `DeviceFiles.scan`, хотя обход похож: у зеркала другие требования. Здесь нужны
 * папки (чтобы в облаке повторялась и пустая структура), inode у каждого файла (иначе
 * переименование неотличимо от удаления с повторной выгрузкой) и честный счётчик нечитаемых
 * папок — по нему принимается решение, можно ли вообще удалять что-то в облаке в этом проходе.
 * Сортировка не нужна: зеркало не показывает список, а сравнивает множества.
 */
class MirrorScanner {

    fun snapshot(
        paths: Collection<String>,
        onProgress: (String) -> Unit = {},
        isCancelled: () -> Boolean = { false },
    ): LocalSnapshot {
        val files = ArrayList<LocalFile>()
        val dirs = ArrayList<LocalDir>()
        var unreadable = 0
        var visited = 0
        var capped = false

        for (root in SelectionRules.scanRoots(paths.toSet())) {
            if (capped || isCancelled()) break
            val rootName = root.substringAfterLast('/')
            val queue = ArrayDeque<Pair<File, String>>()
            queue.addLast(File(root) to rootName)
            while (queue.isNotEmpty() && !capped) {
                if (isCancelled()) break
                val (dir, relDir) = queue.removeLast()
                val children = dir.listFiles()
                if (children == null) {
                    // не читается: это не «пусто». Проход из-за этого удалять не будет
                    unreadable += 1
                    continue
                }
                dirs.add(LocalDir(dir.absolutePath, relDir))
                visited += 1
                if (visited % 100 == 0) onProgress("просмотрено папок: $visited, файлов: ${files.size}")
                for (child in children) {
                    if (isCancelled()) break
                    // Символическая ссылка уводит за пределы выбранной папки: содержимое чужого
                    // каталога уехало бы в облако как «файлы выбранной папки». Не ходим по ссылкам.
                    if (isLink(child)) continue
                    if (child.isDirectory) {
                        if (MediaRules.skipDir(child.name, dir.name)) continue
                        queue.addLast(child to "$relDir/${child.name}")
                        continue
                    }
                    if (!child.isFile) continue
                    if (MediaRules.isHidden(child.name) || MediaRules.isJunk(child.name)) continue
                    files.add(
                        LocalFile(
                            path = child.absolutePath,
                            name = child.name,
                            dir = dir.absolutePath,
                            relDir = relDir,
                            root = root,
                            size = child.length(),
                            mtime = child.lastModified(),
                            inode = inodeOf(child),
                        ),
                    )
                    if (files.size >= HARD_MAX) {
                        capped = true
                        break
                    }
                }
            }
        }
        return LocalSnapshot(files = files, dirs = dirs, unreadable = unreadable, capped = capped)
    }

    /** Символическая ссылка (или жёсткая на каталог): обход по ней уводит за пределы выбора. */
    private fun isLink(file: File): Boolean =
        runCatching { java.nio.file.Files.isSymbolicLink(file.toPath()) }.getOrDefault(false)

    private companion object {
        /** Предел на всякий случай: снимок держится в памяти целиком. */
        const val HARD_MAX = 200_000
    }
}
