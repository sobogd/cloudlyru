package ru.cloudly.sync.docs

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import ru.cloudly.sync.App
import ru.cloudly.sync.net.RemoteEntry

/**
 * Облако в системном выборе файлов: приложение отдаёт системе провайдер документов, и его
 * папки появляются в «Файлах», в диалогах сохранения и в «прикрепить файл» других приложений —
 * без собственного интерфейса. Так же работают Google Фото, Termux и системные «Мои файлы».
 *
 * Что умеет (только чтение):
 *   • показывает дерево папок и файлов облака;
 *   • открывает файл: качаем в кэш с докачкой и проверкой хэша и отдаём обычный seekable fd;
 *   • отдаёт миниатюры: сервер считает превью по хэшу содержимого, оригинал качать не нужно;
 *   • раздел «Последние» — свежие файлы облака.
 *
 * Чего не делает: не создаёт, не переименовывает и не удаляет записи. Запись в облако — это
 * выгрузка, и она появится вместе с новым флоу загрузки; до тех пор система видит провайдер
 * только для чтения, и любая попытка писать заканчивается понятным отказом.
 *
 * Все методы ходят в сеть: система вызывает их в фоновом потоке, а не в главном. Наружу можно
 * бросать только [FileNotFoundException] — любое другое исключение уйдёт через Binder как
 * RuntimeException в чужое приложение, поэтому тела обёрнуты в [safe].
 */
class CloudlyDocumentsProvider : DocumentsProvider() {

    private lateinit var app: App

    /** Корневая папка владельца: спрашиваем один раз за жизнь процесса провайдера. */
    @Volatile
    private var rootFolder: String? = null

    override fun onCreate(): Boolean {
        val ctx = context ?: return false
        app = App.of(ctx)
        return true
    }

    /** Провайдер не имеет права отдавать наружу ничего, кроме FileNotFoundException. */
    private fun <T> safe(what: String, block: () -> T): T = try {
        block()
    } catch (e: FileNotFoundException) {
        throw e
    } catch (e: Exception) {
        Log.w(TAG, "$what: ${e.message}")
        throw FileNotFoundException(e.message ?: "$what: не получилось")
    }

    // ===== дерево =====

    override fun queryRoots(projection: Array<out String>?): Cursor = safe("корни") {
        val cursor = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        row(
            cursor,
            mapOf(
                Root.COLUMN_ROOT_ID to ROOT_ID,
                Root.COLUMN_DOCUMENT_ID to ROOT_DOC_ID,
                Root.COLUMN_TITLE to "Cloudly",
                // без входа в аккаунт объясняем это прямо здесь: иначе корень выглядел бы пустым
                Root.COLUMN_SUMMARY to if (app.prefs.token.isBlank()) {
                    "вход не выполнен — откройте приложение"
                } else {
                    app.prefs.serverUrl
                },
                Root.COLUMN_FLAGS to (Root.FLAG_SUPPORTS_IS_CHILD or Root.FLAG_SUPPORTS_RECENTS),
                Root.COLUMN_MIME_TYPES to "*/*",
                Root.COLUMN_ICON to android.R.drawable.ic_menu_upload,
            ),
        )
        cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        safe("документ") {
            val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
            row(cursor, describe(documentId))
            cursor
        }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor = safe("содержимое папки") {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val children = app.api.children(folderIdOf(parentDocumentId))
        // папки первыми: так список читается сверху вниз
        for ((name, id) in children.folderIds.entries.sortedBy { it.key.lowercase() }) {
            row(cursor, folderRow(id, name))
        }
        for (entry in children.entries.sortedBy { it.name.lowercase() }) {
            row(cursor, entryRow(entry))
        }
        cursor
    }

    /** Свежие файлы: системный раздел «Последние» — удобный вход в облако. */
    override fun queryRecentDocuments(rootId: String, projection: Array<out String>?): Cursor =
        safe("последние") {
            val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
            val children = runCatching { app.api.children(rootFolderId()) }.getOrNull()
            if (children == null) return@safe cursor
            for (entry in children.entries.sortedByDescending { it.clientMtime ?: 0L }.take(50)) {
                row(cursor, entryRow(entry))
            }
            cursor
        }

    /**
     * Открытие документа. Файл скачиваем в кэш целиком (с докачкой и проверкой размера и хэша)
     * и отдаём файловый дескриптор: просмотрщики и плееры любят произвольный доступ, а pipe без
     * перемотки ломает часть приложений.
     */
    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor = safe("открытие документа") {
        if (mode.contains('w') || mode.contains('t')) {
            // записи в облако здесь нет: она появится вместе с новым флоу загрузки
            throw FileNotFoundException("облако открыто только для чтения")
        }
        if (!isFileDoc(documentId)) throw FileNotFoundException("это папка")
        val uuid = uuidOf(documentId)
        val meta = app.api.entryMeta(uuid)
        val target = browseFile(uuid, meta)
        if (!target.isFile || target.length() != meta.size) {
            // без запаса на сам файл и на параллельные загрузки система останется без места
            if (app.cacheDir.usableSpace < meta.size + MIN_FREE_CACHE) {
                throw FileNotFoundException("мало места для кэша: нужно ещё ${meta.size / 1048576} МБ")
            }
            CloudDownloader.download(
                api = app.api,
                entryId = uuid,
                target = target,
                clientMtime = meta.clientMtime,
                expectSha256 = meta.sha256.takeIf { it.isNotBlank() },
                expectSize = meta.size,
            )
        }
        target.setLastModified(System.currentTimeMillis()) // отметка «кэш ещё нужен»
        trimBrowseCache()
        ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** Миниатюра: сервер отдаёт превью по хэшу содержимого, оригинал качать не нужно. */
    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point,
        signal: CancellationSignal?,
    ): AssetFileDescriptor = safe("миниатюра") {
        val meta = app.api.entryMeta(uuidOf(documentId))
        val sha = meta.sha256
        val previewable = meta.mime.startsWith("image/") || meta.mime.startsWith("video/")
        if (sha.isBlank() || !previewable) throw FileNotFoundException("нет превью для ${meta.mime}")
        val thumbs = File(app.cacheDir, "thumbs").apply { mkdirs() }
        val file = File(thumbs, "$sha.webp")
        if (!file.isFile || file.length() == 0L) {
            val bytes = app.api.previewBytes(sha, if (sizeHint.x > 512) 2048 else 512)
            val tmp = File(thumbs, "$sha.tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) {
                tmp.delete()
                throw FileNotFoundException("не удалось сохранить превью")
            }
        }
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        AssetFileDescriptor(fd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        safe("проверка вложенности") {
            if (!isFileDoc(documentId)) return@safe false
            val parent = uuidOf(parentDocumentId)
            runCatching { app.api.entryMeta(uuidOf(documentId)).folderId == parent }.getOrDefault(false)
        }

    // ===== вспомогательное =====

    /** Корень — корневая папка владельца; папка в дереве — её uuid, файл — «f:uuid». */
    private fun folderIdOf(documentId: String): String =
        if (documentId == ROOT_DOC_ID) rootFolderId() else uuidOf(documentId)

    private fun uuidOf(documentId: String): String = when {
        isFileDoc(documentId) -> documentId.removePrefix(FILE_PREFIX)
        documentId == ROOT_DOC_ID -> rootFolderId()
        else -> documentId
    }

    private fun isFileDoc(documentId: String) = documentId.startsWith(FILE_PREFIX)

    private fun rootFolderId(): String {
        rootFolder?.takeIf { it.isNotBlank() }?.let { return it }
        val id = app.api.rootFolderId()
        rootFolder = id
        return id
    }

    private fun describe(documentId: String): Map<String, Any?> {
        if (isFileDoc(documentId)) return entryRow(app.api.entryMeta(uuidOf(documentId)))
        val (name, _) = app.api.folderMeta(folderIdOf(documentId))
        return folderRow(documentId, name.ifBlank { "Облако" })
    }

    private fun folderRow(id: String, name: String): Map<String, Any?> = mapOf(
        Document.COLUMN_DOCUMENT_ID to id,
        Document.COLUMN_DISPLAY_NAME to name,
        Document.COLUMN_MIME_TYPE to Document.MIME_TYPE_DIR,
        // флагов правки нет: провайдер только читает
        Document.COLUMN_FLAGS to 0,
        Document.COLUMN_LAST_MODIFIED to 0L,
    )

    private fun entryRow(entry: RemoteEntry): Map<String, Any?> {
        val previewable = entry.sha256.isNotBlank() &&
            (entry.mime.startsWith("image/") || entry.mime.startsWith("video/"))
        return mapOf(
            Document.COLUMN_DOCUMENT_ID to FILE_PREFIX + entry.id,
            Document.COLUMN_DISPLAY_NAME to entry.name,
            Document.COLUMN_MIME_TYPE to entry.mime.ifBlank { "application/octet-stream" },
            Document.COLUMN_SIZE to entry.size,
            Document.COLUMN_LAST_MODIFIED to (entry.clientMtime ?: 0L),
            Document.COLUMN_FLAGS to (if (previewable) Document.FLAG_SUPPORTS_THUMBNAIL else 0),
        )
    }

    private fun row(cursor: MatrixCursor, values: Map<String, Any?>) {
        val row = cursor.newRow()
        for (column in cursor.columnNames) row.add(values[column])
    }

    /**
     * Файл в кэше. Имя — по хэшу содержимого, а не по имени записи: одно и то же содержимое,
     * лежащее в облаке дважды, качается один раз. Расширение оставляем — по нему часть
     * просмотрщиков выбирает способ открытия.
     */
    private fun browseFile(uuid: String, meta: RemoteEntry): File {
        val stem = if (meta.sha256.isNotBlank()) meta.sha256 else uuid
        val ext = meta.name.substringAfterLast('.', "").filter { it.isLetterOrDigit() }.take(8)
        val name = if (ext.isEmpty()) stem else "$stem.$ext"
        return File(File(app.cacheDir, "browse").apply { mkdirs() }, name)
    }

    /**
     * Кэш открытых файлов: держим не больше гигабайта. Чистим по времени последнего обращения,
     * но не трогаем то, что открыли только что, и служебные файлы докачки (`.имя.cloudly-part`):
     * иначе чистка одного файла сносит недокачанный другой.
     */
    private fun trimBrowseCache() {
        val cutoff = System.currentTimeMillis() - TRIM_GRACE_MS
        val files = File(app.cacheDir, "browse").listFiles()
            ?.filter { it.isFile && !it.name.startsWith(".") } ?: return
        var total = files.sumOf { it.length() }
        if (total <= MAX_BROWSE_CACHE) return
        for (file in files.filter { it.lastModified() < cutoff }.sortedBy { it.lastModified() }) {
            if (total <= MAX_BROWSE_CACHE) break
            val size = file.length()
            if (file.delete()) total -= size
        }
    }

    companion object {
        private const val TAG = "cloudly-sync"

        /** Authority провайдера: тот же, что в манифесте. */
        const val AUTHORITY = "ru.cloudly.sync.documents"

        /**
         * Ссылка на файл облака для чужого приложения: `content://ru.cloudly.sync.documents/document/f:<id>`.
         * По ней работает и системный выборщик, и наша activity выбора файла.
         */
        fun fileUri(entryId: String): android.net.Uri =
            android.provider.DocumentsContract.buildDocumentUri(AUTHORITY, "$FILE_PREFIX$entryId")

        private const val ROOT_ID = "cloudly"
        const val ROOT_DOC_ID = "root"
        private const val FILE_PREFIX = "f:"
        private const val MAX_BROWSE_CACHE = 1L shl 30

        /** Не удаляем из кэша то, что открыли в последние минуты: файл ещё читают. */
        private const val TRIM_GRACE_MS = 10 * 60 * 1000L

        /** Запас свободного места сверх размера файла — 64 МБ. */
        private const val MIN_FREE_CACHE = 64L * 1024 * 1024

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_FLAGS,
            Root.COLUMN_MIME_TYPES,
            Root.COLUMN_ICON,
            Root.COLUMN_AVAILABLE_BYTES,
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
    }
}
