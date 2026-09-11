package ru.cloudly.sync.data

import android.content.Context

/**
 * Выбранные папки разделов. Хранятся как пути в обычных настройках: это не секрет,
 * а шифрованное хранилище занято токеном.
 *
 * В наборе всегда «антицепочка» — если папка выбрана, её подпапок в наборе нет: они и так
 * покрыты выбором. На этом правиле держится и дерево выбора, и обход при показе списка.
 */
class Selection(context: Context) {
    private val prefs = context.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /** Пути, выбранные в разделе (именно отмеченные, без «покрытых» подпапок). */
    fun paths(section: Section): Set<String> =
        // getStringSet отдаёт внутренний набор настроек: копируем, иначе его правка ломает выбор
        prefs.getStringSet(key(section), emptySet())?.toSet() ?: emptySet()

    fun choose(section: Section, path: String): Set<String> =
        store(section, SelectionRules.choose(paths(section), path))

    fun unchoose(section: Section, path: String, childDirsOf: (String) -> List<String>): Set<String> =
        store(section, SelectionRules.unchoose(paths(section), path, childDirsOf))

    fun clear(section: Section): Set<String> = store(section, emptySet())

    private fun store(section: Section, paths: Set<String>): Set<String> {
        prefs.edit().putStringSet(key(section), paths).apply()
        return paths
    }

    private fun key(section: Section): String = when (section) {
        Section.FILES -> "folders_files"
        Section.PHOTOS -> "folders_photos"
    }

    private companion object {
        const val NAME = "cloudly-selection"
    }
}

/**
 * Правила выбора папок. Чистые функции без файловой системы: всё, что зависит от диска,
 * приходит аргументом `childDirsOf`, поэтому правила проверяются юнит-тестами.
 */
object SelectionRules {

    /** Папка покрыта выбором: выбрана сама или лежит внутри выбранной. */
    fun isCovered(paths: Set<String>, path: String): Boolean =
        paths.any { it == path || path.startsWith("$it/") }

    /** Внутри папки есть выбранные: галочка в состоянии «частично». */
    fun hasInside(paths: Set<String>, path: String): Boolean = paths.any { it.startsWith("$path/") }

    /**
     * Отметить папку: она вбирает всё поддерево, поэтому её подпапки и её предки из набора
     * уходят — иначе дерево отвечало бы «выбрано» на разные вопросы сразу.
     */
    fun choose(paths: Set<String>, path: String): Set<String> =
        paths.filterNot { it == path || it.startsWith("$path/") || path.startsWith("$it/") }.toSet() + path

    /**
     * Снять выбор. Если папка была покрыта выбранным предком, предка «раскрываем»: убираем его
     * и отмечаем его прямые подпапки. Иначе снять галочку внутри выбранного дерева было бы нечем.
     */
    fun unchoose(paths: Set<String>, path: String, childDirsOf: (String) -> List<String>): Set<String> {
        var current = paths
        var guard = 0
        while (guard++ < MAX_UNCOVER) {
            // самый глубокий выбранный предок: раскрывать надо его, а не весь путь целиком
            val cover = current
                .filter { it != path && path.startsWith("$it/") }
                .maxByOrNull { it.length } ?: break
            val children = childDirsOf(cover)
            current = (current - cover) + children
            // каталог не читается — раскрыть его нечем, дальше подниматься смысла нет
            if (children.isEmpty()) break
        }
        return current - path
    }

    /** Папки для обхода: без тех, что лежат внутри других выбранных. */
    fun scanRoots(paths: Set<String>): List<String> =
        paths.filter { p -> paths.none { it != p && p.startsWith("$it/") } }.sorted()

    /** Защита от цикла, если файловая система вернёт себя же в качестве подпапки. */
    private const val MAX_UNCOVER = 64
}
