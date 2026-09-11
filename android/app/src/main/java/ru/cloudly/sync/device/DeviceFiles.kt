package ru.cloudly.sync.device

import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import ru.cloudly.sync.data.SelectionRules
import java.io.File

/** Корень выбора: внутренняя память или карта памяти. */
data class RootFolder(val path: String, val name: String)

/** Узел дерева папок: путь, короткое имя, глубина для отступа. */
data class FolderNode(val path: String, val name: String, val depth: Int, val hasChildren: Boolean)

/**
 * Файл на телефоне.
 *
 * @param relDir путь папки относительно родителя выбранной папки, вместе с её именем:
 *        выбрали `Download` — файл из `Download/Telegram` получит `Download/Telegram`.
 *        Именно так строится структура в облаке: выбранная папка становится папкой внутри
 *        корня зеркала, и это видно, откуда файл приехал.
 * @param root   выбранная папка, из которой пришёл файл (для группировки и отладки)
 */
data class DeviceFile(
    val path: String,
    val name: String,
    val dir: String,
    val relDir: String,
    val root: String,
    val size: Long,
    val mtime: Long,
    val media: Boolean,
)

/**
 * @param files  отсортированы по дате изменения: свежие первыми
 * @param total  сколько файлов нашлось всего (может быть больше, чем отдано)
 * @param unreadable сколько папок не удалось прочитать — молчаливый ноль выглядел бы как пустота
 * @param capped обход упёрся в предохранительный предел и файлы остались непройденными
 */
data class ScanResult(
    val files: List<DeviceFile>,
    val dirs: Int,
    val total: Int,
    val unreadable: Int,
    val capped: Boolean = false,
)

/**
 * Чтение телефона: дерево папок для экрана выбора и файлы для разделов и очереди.
 * Работает обычными путями — у приложения есть доступ ко всем файлам, поэтому ни SAF,
 * ни медиатека не нужны: видно ровно то, что лежит на диске.
 *
 * Отбора по расширению здесь нет: раздел определяется тем, к какой папке прикреплена
 * папка телефона, а не типом файла. Медиа-признак остаётся только для иконки в списке.
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
            // по символическим ссылкам не ходим: они уводят за пределы выбранной папки
            .filter { it.isDirectory && !isLink(it) && !MediaRules.skipDir(it.name, dir.name) }
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
     * Файлы выбранных папок. Обход идёт в фоне и умеет останавливаться: на телефоне десятки
     * тысяч файлов, и держать из-за них интерфейс нельзя.
     *
     * @param limit сколько файлов вернуть (для списка раздела); 0 — без предела
     */
    fun scan(
        paths: Collection<String>,
        limit: Int,
        onProgress: (String) -> Unit,
        isCancelled: () -> Boolean,
    ): ScanResult {
        val found = ArrayList<DeviceFile>()
        var dirs = 0
        var unreadable = 0
        var capped = false

        onProgress("сканирую папки…")
        for (root in SelectionRules.scanRoots(paths.toSet())) {
            if (capped || isCancelled()) break
            val rootName = root.substringAfterLast('/')
            // стек обхода: папка и её путь относительно родителя выбранной папки
            val queue = ArrayDeque<Pair<File, String>>()
            queue.addLast(File(root) to rootName)
            while (queue.isNotEmpty() && !capped) {
                if (isCancelled()) break
                val (dir, relDir) = queue.removeLast()
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
                    if (isLink(child)) continue
                    if (child.isDirectory) {
                        if (MediaRules.skipDir(child.name, dir.name)) continue
                        queue.addLast(child to "$relDir/${child.name}")
                        continue
                    }
                    if (!child.isFile) continue
                    if (MediaRules.isHidden(child.name) || MediaRules.isJunk(child.name)) continue
                    found.add(
                        DeviceFile(
                            path = child.absolutePath,
                            name = child.name,
                            dir = dir.absolutePath,
                            relDir = relDir,
                            root = root,
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
        }

        val sorted = found.sortedWith(
            compareByDescending<DeviceFile> { it.mtime }.thenBy { it.name.lowercase() },
        )
        onProgress("папок: $dirs, файлов: ${sorted.size}")
        return ScanResult(
            files = if (limit in 1 until sorted.size) sorted.take(limit) else sorted,
            dirs = dirs,
            total = sorted.size,
            unreadable = unreadable,
            capped = capped,
        )
    }

    /** Символическая ссылка: обход по ней показал бы и выгрузил чужой каталог. */
    private fun isLink(file: File): Boolean =
        runCatching { java.nio.file.Files.isSymbolicLink(file.toPath()) }.getOrDefault(false)

    private companion object {
        /** Предел на всякий случай: 20 000 файлов в списке всё равно никто не листает. */
        const val HARD_MAX = 20_000
    }
}
