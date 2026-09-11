package ru.cloudly.sync.device

import ru.cloudly.sync.data.Section
import java.util.Locale

/**
 * Правила отбора: что считается фото и видео, что попадает в раздел «Файлы», а что не стоит
 * показывать вообще. Здесь только чистые функции — весь отбор живёт тут, в интерфейсе его нет,
 * и именно эти функции проверяют юнит-тесты.
 *
 * Разделение на медиа и файлы идёт по расширению, а не по папке: скриншоты лежат и в `DCIM`,
 * и в `Pictures/Screenshots`, а скачанные фотографии — в `Download` рядом с документами,
 * поэтому «папки для фото» и «папки для файлов» списком не разложить.
 */
object MediaRules {

    /** Фото: сюда же RAW и HEIC — камера телефона пишет именно так. */
    private val IMAGE = setOf(
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "jxl",
        "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "pef", "sr2",
        "tif", "tiff", "svg",
    )

    private val VIDEO = setOf(
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "3g2", "mpg", "mpeg",
        "mts", "m2ts", "ts", "wmv", "flv",
    )

    /** Недописанное и служебное: в списках не показываем. */
    private val JUNK_SUFFIX = listOf(".tmp", ".part", ".crdownload", ".cloudly-tmp")

    /** Служебные каталоги: в дереве выбора их нет и при скане они не обходятся. */
    private val SKIP_NAMES = setOf(".thumbnails", ".trashed", "LOST.DIR")

    fun extension(name: String): String = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    fun isImage(name: String): Boolean = extension(name) in IMAGE

    fun isVideo(name: String): Boolean = extension(name) in VIDEO

    /** Фото и видео вместе — то, что показывается в разделе «Фото и видео». */
    fun isMedia(name: String): Boolean = isImage(name) || isVideo(name)

    /** Куда попадает файл: медиа — в фото, всё остальное — в файлы. */
    fun matches(section: Section, name: String): Boolean =
        if (section == Section.PHOTOS) isMedia(name) else !isMedia(name)

    /** Имена на точку не показываем: это `.nomedia`, `.thumbnails`, чужой служебный мусор. */
    fun isHidden(name: String): Boolean = name.startsWith(".")

    fun isJunk(name: String): Boolean = JUNK_SUFFIX.any { name.endsWith(it, ignoreCase = true) }

    /**
     * Служебные каталоги. `Android/data` и `Android/obb` — не файлы пользователя, а тысячи
     * каталогов приложений: в раскрытом дереве они хоронят всё остальное.
     */
    fun skipDir(name: String, parentName: String): Boolean {
        if (isHidden(name)) return true
        if (name in SKIP_NAMES) return true
        return parentName == "Android" && (name == "data" || name == "obb")
    }

    /** Размер в человеческом виде: «4.2 МБ» читается лучше, чем «4404019». */
    fun formatSize(bytes: Long): String {
        if (bytes < 1024) return "$bytes Б"
        val units = listOf("КБ", "МБ", "ГБ", "ТБ")
        var value = bytes.toDouble() / 1024
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit += 1
        }
        val format = if (value < 10) "%.1f %s" else "%.0f %s"
        return String.format(Locale.US, format, value, units[unit])
    }
}
