package ru.cloudly.sync.mirror

/**
 * Модели двустороннего зеркала. Отдельно от моделей очереди: у очереди смысл «что выгрузить
 * руками», у зеркала — «чем телефон и облако отличаются прямо сейчас», и состояния тут свои.
 */

/**
 * Файл на телефоне в том виде, в каком его видит сверка.
 *
 * @param relDir путь относительно родителя выбранной папки вместе с её именем: выбран
 *        `Download` — файл из `Download/Telegram` даст `Download/Telegram`. Так же строится
 *        структура в облаке внутри корня зеркала.
 * @param inode номер файла в файловой системе: по нему переименование отличается от
 *        «удалил и залил заново». Без него переименование папки с гигабайтами видео стоило бы
 *        повторной выгрузки всего содержимого.
 */
data class LocalFile(
    val path: String,
    val name: String,
    val dir: String,
    val relDir: String,
    val root: String,
    val size: Long,
    val mtime: Long,
    val inode: Long,
)

/** Папка телефона. Нужна, чтобы в облаке повторялась и пустая структура, а не только места с файлами. */
data class LocalDir(val path: String, val relDir: String)

/**
 * @param unreadable сколько папок не удалось прочитать. Нечитаемая папка — это не пустая
 *        папка: при ошибке чтения удаления в облако не отправляются вовсе.
 * @param capped обход упёрся в предел: часть дерева не пройдена, решение об удалениях
 *        принимать по неполному снимку нельзя.
 */
data class LocalSnapshot(
    val files: List<LocalFile>,
    val dirs: List<LocalDir>,
    val unreadable: Int,
    val capped: Boolean,
)

/**
 * Строка «что уже выгружено»: файл телефона, его запись в облаке и слепок содержимого,
 * по которому запись делалась.
 */
data class MirrorRow(
    val path: String,
    val cloudFolderId: String,
    val entryId: String,
    val inode: Long,
    val size: Long,
    val mtime: Long,
    val sha256: String?,
)

/**
 * Незавершённая выгрузка: сессия на сервере и слепок файла, по которому она начата.
 * Нужна, чтобы после обрыва продолжить с принятой части, а не лить файл заново.
 */
data class UploadSessionRow(
    val path: String,
    val uploadId: String,
    val folderId: String,
    val size: Long,
    val mtime: Long,
    val sha256: String,
)

/** Сколько файлов и байт: одна пара чисел для итогов и прогресса. */
data class Totals(val files: Int, val bytes: Long)

/** Выбранная папка телефона и её папка в облаке — пара, заведённая один раз. */
data class MirrorRoot(val localPath: String, val cloudId: String, val cloudPath: String)

/**
 * Номер файла в файловой системе. `File` его не отдаёт, а без него переименование выглядит
 * как «удалили один файл и залили другой» — с повторной передачей всех байтов.
 * Ноль означает «не удалось узнать»: тогда переименование просто не распознаётся.
 */
internal fun inodeOf(file: java.io.File): Long =
    runCatching { android.system.Os.stat(file.absolutePath).st_ino }.getOrDefault(0L)

