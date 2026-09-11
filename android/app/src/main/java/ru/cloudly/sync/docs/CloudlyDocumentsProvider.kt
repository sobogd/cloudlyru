package ru.cloudly.sync.docs

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import ru.cloudly.sync.App
import ru.cloudly.sync.net.RemoteEntry
import ru.cloudly.sync.sync.Decisions
import ru.cloudly.sync.sync.Downloader
import ru.cloudly.sync.sync.Hasher
import ru.cloudly.sync.sync.LocalFile
import ru.cloudly.sync.sync.Uploader
import ru.cloudly.sync.work.Notifications

/**
 * Файловый браузер облака средствами Android: приложение отдаёт системе провайдер документов,
 * и папки облака появляются в «Файлах», в системном выборе файлов и в диалогах сохранения —
 * без собственного интерфейса.
 *
 * Что умеет:
 *   • показывает дерево папок и файлов (чтение — прямо из API);
 *   • открывает файл: качаем в кэш с докачкой и проверкой хэша и отдаём обычный seekable fd;
 *   • отдаёт миниатюры: сервер считает превью по хэшу содержимого, оригинал качать не нужно;
 *   • «сохранить в облако» из другого приложения: пишем во временный файл и после закрытия
 *     дескриптора выгружаем в ту папку, где пользователь создал документ;
 *   • переименование и удаление: удаление уходит в корзину сервера и никогда не трогает
 *     файлы на телефоне.
 *
 * Все методы ходят в сеть: система вызывает их в фоновом потоке, а не в главном.
 */
class CloudlyDocumentsProvider : DocumentsProvider() {

    private lateinit var app: App
    private lateinit var handlerThread: HandlerThread
    private lateinit var handler: Handler
    private val uploads = Executors.newSingleThreadExecutor { r -> Thread(r, "cloudly-provider-upload") }

    /** Файлы, созданные системой и ещё не выгруженные: id → что и куда сохранять. */
    private val pending = ConcurrentHashMap<String, Pending>()

    private data class Pending(val file: File, val folderId: String, val name: String, val mime: String)

    override fun onCreate(): Boolean {
        val ctx = context ?: return false
        app = App.of(ctx)
        handlerThread = HandlerThread("cloudly-provider-fd").apply { start() }
        handler = Handler(handlerThread.looper)
        return true
    }

    // ===== дерево =====

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        row(
            cursor,
            mapOf(
                Root.COLUMN_ROOT_ID to ROOT_ID,
                Root.COLUMN_DOCUMENT_ID to ROOT_DOC_ID,
                Root.COLUMN_TITLE to "Cloudly",
                Root.COLUMN_SUMMARY to app.prefs.serverUrl,
                Root.COLUMN_FLAGS to (
                    Root.FLAG_SUPPORTS_CREATE or
                        Root.FLAG_SUPPORTS_IS_CHILD or
                        Root.FLAG_SUPPORTS_RECENTS
                    ),
                Root.COLUMN_MIME_TYPES to "*/*",
                Root.COLUMN_ICON to android.R.drawable.ic_menu_upload,
            ),
        )
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        row(cursor, describe(documentId))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val children = app.api.children(folderIdOf(parentDocumentId))
        // папки первыми: так список читается сверху вниз
        for ((name, id) in children.folderIds.entries.sortedBy { it.key.lowercase() }) {
            row(cursor, folderRow(id, name))
        }
        for (entry in children.entries.sortedBy { it.name.lowercase() }) {
            row(cursor, entryRow(entry))
        }
        return cursor
    }

    /** Свежие файлы: системный раздел «Последние» в «Файлах» — удобный вход в облако. */
    override fun queryRecentDocuments(rootId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val children = runCatching { app.api.children(folderIdOf(ROOT_DOC_ID)) }.getOrNull() ?: return cursor
        for (entry in children.entries.sortedByDescending { it.clientMtime ?: 0L }.take(50)) {
            row(cursor, entryRow(entry))
        }
        return cursor
    }

    /**
     * Создание документа системой: папку заводим на сервере сразу, а для файла запоминаем
     * будущее место и отдаём временный дескриптор — выгрузим, когда приложение допишет файл.
     */
    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        val name = cleanName(displayName)
        val folderId = folderIdOf(parentDocumentId)
        if (mimeType == Document.MIME_TYPE_DIR) return app.api.ensurePath(name, folderId)

        val dir = File(app.cacheDir, "pending").apply { mkdirs() }
        val tmp = File(dir, "new-${System.nanoTime()}")
        val id = NEW_PREFIX + java.util.UUID.randomUUID()
        pending[id] = Pending(tmp, folderId, name, mimeType)
        return id
    }

    /**
     * Открытие документа. Для обычного файла скачиваем его в кэш целиком (с докачкой и проверкой
     * размера и хэша) и отдаём файловый дескриптор: просмотрщики и плееры любят произвольный
     * доступ, а pipe без перемотки ломает часть приложений.
     */
    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (documentId.startsWith(NEW_PREFIX)) return openForWrite(documentId)
        if (mode.contains('w') || mode.contains('t')) {
            // правку файла в облаке не поддерживаем: новую версию можно сохранить рядом
            throw FileNotFoundException("файл в облаке доступен только для чтения")
        }
        if (!isFileDoc(documentId)) throw FileNotFoundException("это папка")
        val uuid = uuidOf(documentId)
        val meta = app.api.entryMeta(uuid)
        val target = browseFile(uuid, meta.name)
        if (!target.isFile || target.length() != meta.size) {
            Downloader.download(
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
        return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** Дескриптор на запись для только что созданного документа: выгрузка начнётся на закрытии. */
    private fun openForWrite(documentId: String): ParcelFileDescriptor {
        val item = pending[documentId] ?: throw FileNotFoundException("документ уже сохранён")
        val raf = RandomAccessFile(item.file, "rw")
        val manager = context!!.getSystemService(StorageManager::class.java)
        val mode = ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE or
            ParcelFileDescriptor.MODE_TRUNCATE
        val callback = SaveCallback(raf) {
            pending.remove(documentId)
            uploads.execute { uploadSaved(item) }
        }
        return manager.openProxyFileDescriptor(mode, callback, handler)
    }

    /** Миниатюра: сервер отдаёт превью по хэшу содержимого, оригинал качать не нужно. */
    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point,
        signal: CancellationSignal?,
    ): AssetFileDescriptor {
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
        return AssetFileDescriptor(fd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun deleteDocument(documentId: String) {
        pending.remove(documentId)?.file?.delete()
        if (isFileDoc(documentId)) {
            // «удалить» в системе = корзина сервера: файл на телефоне не трогаем
            app.api.deleteFile(uuidOf(documentId))
            return
        }
        if (documentId == ROOT_DOC_ID) throw FileNotFoundException("корень удалить нельзя")
        app.api.deleteFolder(uuidOf(documentId))
    }

    override fun renameDocument(documentId: String, displayName: String): String? {
        val name = cleanName(displayName)
        if (isFileDoc(documentId)) {
            val meta = app.api.entryMeta(uuidOf(documentId))
            val folderId = meta.folderId ?: throw FileNotFoundException("не нашёл папку файла")
            app.api.moveFile(meta.id, folderId, name)
        } else {
            app.api.renameFolder(uuidOf(documentId), name)
        }
        return null
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        if (!isFileDoc(documentId)) return false
        val parent = uuidOf(parentDocumentId)
        return runCatching { app.api.entryMeta(uuidOf(documentId)).folderId == parent }.getOrDefault(false)
    }

    // ===== выгрузка сохранённого файла =====

    private fun uploadSaved(item: Pending) {
        val api = app.api
        try {
            if (item.file.length() == 0L) {
                item.file.delete()
                return
            }
            val sha = Hasher.sha256(item.file)
            // имя могло быть занято, пока файл писался: ставим свободное, чужое не перезаписываем
            val taken = runCatching { api.children(item.folderId).entries.map { it.name }.toHashSet() }
                .getOrDefault(emptySet())
            val name = Decisions.freeName(item.name, taken)
            val local = LocalFile(name, item.file.absolutePath, name, item.file.length(), item.file.lastModified())
            val result = runCatching { upload(api, item.folderId, local, sha, viaRelay = false) }
                .getOrElse { first ->
                    // прямое подключение к хранилищу могло не сработать — повторяем через сервер
                    Log.w(TAG, "прямая выгрузка не удалась (${first.message}) — пробую через сервер")
                    upload(api, item.folderId, local, sha, viaRelay = true)
                }
            Log.i(TAG, "сохранено в облако: ${result.name}")
            item.file.delete()
        } catch (e: Exception) {
            // файл, который сохранил пользователь, терять нельзя: оставляем и говорим, где он
            Log.w(TAG, "не удалось выгрузить ${item.name}: ${e.message}")
            Notifications.notifyProblems(
                context!!,
                "не удалось выгрузить «${item.name}»: ${e.message}. Файл остался на телефоне: ${item.file.absolutePath}",
            )
        }
    }

    private fun upload(
        api: ru.cloudly.sync.net.Api,
        folderId: String,
        file: LocalFile,
        sha256: String,
        viaRelay: Boolean,
    ) = Uploader(api).upload(
        folderId = folderId,
        file = file,
        sha256 = sha256,
        replace = false,
        expectedSha256 = null,
        uploadIdFromQueue = null,
        onSession = {},
        onProgress = { _, _ -> },
        forceRelay = viaRelay,
    )

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
        app.db.kv(KV_ROOT)?.takeIf { it.isNotBlank() }?.let { return it }
        val id = app.api.rootFolderId()
        app.db.putKv(KV_ROOT, id)
        return id
    }

    private fun describe(documentId: String): Map<String, Any?> {
        if (documentId.startsWith(NEW_PREFIX)) {
            val item = pending[documentId] ?: throw FileNotFoundException("документ уже сохранён")
            return mapOf(
                Document.COLUMN_DOCUMENT_ID to documentId,
                Document.COLUMN_DISPLAY_NAME to item.name,
                Document.COLUMN_MIME_TYPE to item.mime.ifBlank { "application/octet-stream" },
                Document.COLUMN_SIZE to item.file.length(),
                Document.COLUMN_LAST_MODIFIED to System.currentTimeMillis(),
                Document.COLUMN_FLAGS to 0,
            )
        }
        if (isFileDoc(documentId)) return entryRow(app.api.entryMeta(uuidOf(documentId)))
        val (name, _) = app.api.folderMeta(folderIdOf(documentId))
        return folderRow(documentId, name.ifBlank { "Облако" })
    }

    private fun folderRow(id: String, name: String): Map<String, Any?> = mapOf(
        Document.COLUMN_DOCUMENT_ID to id,
        Document.COLUMN_DISPLAY_NAME to name,
        Document.COLUMN_MIME_TYPE to Document.MIME_TYPE_DIR,
        Document.COLUMN_FLAGS to (
            Document.FLAG_DIR_SUPPORTS_CREATE or
                Document.FLAG_SUPPORTS_RENAME or
                Document.FLAG_SUPPORTS_DELETE
            ),
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
            Document.COLUMN_FLAGS to (
                Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME or
                    (if (previewable) Document.FLAG_SUPPORTS_THUMBNAIL else 0)
                ),
        )
    }

    private fun row(cursor: MatrixCursor, values: Map<String, Any?>) {
        val row = cursor.newRow()
        for (column in cursor.columnNames) row.add(values[column])
    }

    private fun browseFile(uuid: String, name: String) =
        File(File(app.cacheDir, "browse").apply { mkdirs() }, "$uuid-${cleanName(name)}")

    /**
     * Кэш открытых файлов: держим не больше гигабайта и чистим по времени последнего
     * использования — открытое недавно остаётся, старое освобождает место.
     */
    private fun trimBrowseCache() {
        val files = File(app.cacheDir, "browse").listFiles()?.filter { it.isFile } ?: return
        var total = files.sumOf { it.length() }
        if (total <= MAX_BROWSE_CACHE) return
        for (file in files.sortedBy { it.lastModified() }) {
            if (total <= MAX_BROWSE_CACHE) break
            val size = file.length()
            if (file.delete()) total -= size
        }
    }

    override fun shutdown() {
        uploads.shutdown()
        handlerThread.quitSafely()
        super.shutdown()
    }

    /**
     * Дескриптор для сохранения файла в облако. Система сообщает о закрытии через onRelease —
     * это и есть момент, когда файл дописан и его можно выгружать.
     */
    private class SaveCallback(
        private val raf: RandomAccessFile,
        private val onDone: () -> Unit,
    ) : ProxyFileDescriptorCallback() {
        private val released = AtomicBoolean(false)

        override fun onGetSize(): Long = raf.length()

        override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
            raf.seek(offset)
            val read = raf.read(data, 0, size)
            // 0 — конец файла: именно так система понимает, что читать больше нечего
            return if (read < 0) 0 else read
        }

        override fun onWrite(offset: Long, size: Int, data: ByteArray): Int {
            raf.seek(offset)
            raf.write(data, 0, size)
            return size
        }

        override fun onFsync() {
            runCatching { raf.fd.sync() }
        }

        override fun onRelease() {
            if (!released.compareAndSet(false, true)) return
            runCatching { raf.close() }
            onDone()
        }
    }

    companion object {
        private const val TAG = "cloudly-sync"

        /** Authority провайдера: тот же, что в манифесте. */
        const val AUTHORITY = "ru.cloudly.sync.documents"

        private const val ROOT_ID = "cloudly"
        const val ROOT_DOC_ID = "root"
        private const val FILE_PREFIX = "f:"
        private const val NEW_PREFIX = "new:"
        private const val KV_ROOT = "root_folder_id"
        private const val MAX_BROWSE_CACHE = 1L shl 30

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

        /** Имя от системы: чистим так же, как имена из «Поделиться». */
        private fun cleanName(raw: String): String =
            Decisions.cleanFileName(raw).ifBlank { "файл-${System.currentTimeMillis()}" }
    }
}
