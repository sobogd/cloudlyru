package ru.cloudly.sync.device

import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.data.SelectionRules
import java.io.File

/** Корень выбора: внутренняя память или карта памяти. */
data class RootFolder(val path: String, val name: String)

/** Узел дерева папок: путь, короткое имя, глубина для отступа. */
data class FolderNode(val path: String, val name: String, val depth: Int, val hasChildren: Boolean)

/** Файл для списка раздела. */
data class DeviceFile(
    val path: String,
    val name: String,
    val dir: String,
    val size: Long,
    val mtime: Long,
    val media: Boolean,
)

/**
 * @param files  отсортированы по дате изменения: свежие первыми
 * @param total  сколько файлов нашлось всего (может быть больше, чем отдано)
 * @param unreadable сколько папок не удалось прочитать — молчаливый ноль выглядел бы как пустота
 */
data class ScanResult(val files: List<DeviceFile>, val dirs: Int, val total: Int, val unreadable: Int)

/**
 * Чтение телефона: дерево папок для экрана выбора и файлы для списков разделов.
 * Работает обычными путями — у приложения есть доступ ко всем файлам, поэтому ни SAF,
 * ни медиатека не нужны: видно ровно то, что лежит на диске.
 */
class DeviceFiles(private val context: Context) {

    fun roots(): List<RootFolder> {
        val out = LinkedHashMap<String, RootFolder>()
        val primary = Environment.getExternalStorageDirectory()
        if (primary != null && primary.isDirectory) {
            out[primary.absolutePath] = RootFolder(primary.absolutePath, "Внутренняя память")
        }
        // Карты памяти: getDirectory() появился в Android 11, на десяти адресуем только внутреннюю
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.getSystemService(StorageManager::class.java)?.storageVolumes?.forEach { volume ->
                val dir = volume.directory ?: return@forEach
                if (!dir.isDirectory) return@forEach
                if (out.containsKey(dir.absolutePath)) return@forEach
                val name = runCatching { volume.getDescription(context) }.getOrNull().orEmpty()
                out[dir.absolutePath] = RootFolder(dir.absolutePath, name.ifBlank { dir.name })
            }
        }
        return out.values.toList()
    }

    /** Прямые подпапки: нужны и дереву, и раскрытию выбранного предка при снятии галочки. */
    fun subdirs(path: String): List<String> {
        val dir = File(path)
        val children = dir.listFiles() ?: return emptyList()
        return children
            .filter { it.isDirectory && !MediaRules.skipDir(it.name, dir.name) }
            .map { it.absolutePath }
            .sortedBy { it.substringAfterLast('/').lowercase() }
    }

    /**
     * Обход дерева в порядке отображения (родитель, затем его подпапки). Отдаёт узлы по мере
     * обхода: дерево на телефоне большое, ждать полного обхода перед первым экраном нельзя.
     */
    fun walkTree(roots: List<RootFolder>, emit: (FolderNode) -> Unit, isCancelled: () -> Boolean) {
        fun visit(path: String, name: String, depth: Int) {
            if (isCancelled()) return
            val children = subdirs(path)
            emit(FolderNode(path, name, depth, children.isNotEmpty()))
            for (child in children) {
                if (isCancelled()) return
                visit(child, child.substringAfterLast('/'), depth + 1)
            }
        }
        for (root in roots) visit(root.path, root.name, 0)
    }

    /**
     * Файлы всех выбранных папок, свежие первыми. Обход идёт в фоне и умеет останавливаться:
     * на телефоне десятки тысяч файлов, и держать из-за них интерфейс нельзя.
     */
    fun scan(
        paths: Collection<String>,
        section: Section,
        limit: Int,
        onProgress: (String) -> Unit,
        isCancelled: () -> Boolean,
    ): ScanResult {
        val found = ArrayList<DeviceFile>()
        val queue = ArrayDeque<String>()
        SelectionRules.scanRoots(paths.toSet()).forEach { queue.addLast(it) }
        var dirs = 0
        var unreadable = 0
        var capped = false

        onProgress("сканирую папки…")
        while (queue.isNotEmpty() && !capped) {
            if (isCancelled()) break
            val dir = File(queue.removeLast())
            val children = dir.listFiles()
            if (children == null) {
                // каталог не читается: это не «пусто», и в итоге это должно быть видно
                unreadable += 1
                continue
            }
            dirs += 1
            if (dirs % 50 == 0) onProgress("просмотрено папок: $dirs, найдено файлов: ${found.size}")
            for (child in children) {
                if (isCancelled()) break
                if (child.isDirectory) {
                    if (!MediaRules.skipDir(child.name, dir.name)) queue.addLast(child.absolutePath)
                    continue
                }
                if (!child.isFile) continue
                if (MediaRules.isHidden(child.name) || MediaRules.isJunk(child.name)) continue
                if (!MediaRules.matches(section, child.name)) continue
                found.add(
                    DeviceFile(
                        path = child.absolutePath,
                        name = child.name,
                        dir = dir.absolutePath,
                        size = child.length(),
                        mtime = child.lastModified(),
                        media = MediaRules.isMedia(child.name),
                    ),
                )
                if (found.size >= HARD_MAX) {
                    capped = true
                    break
                }
            }
        }

        val sorted = found.sortedWith(
            compareByDescending<DeviceFile> { it.mtime }.thenBy { it.name.lowercase() },
        )
        onProgress("папок: $dirs, файлов: ${sorted.size}")
        return ScanResult(sorted.take(limit), dirs, sorted.size, unreadable)
    }

    private companion object {
        /** Предел на всякий случай: 20 000 файлов в списке всё равно никто не листает. */
        const val HARD_MAX = 20_000
    }
}
