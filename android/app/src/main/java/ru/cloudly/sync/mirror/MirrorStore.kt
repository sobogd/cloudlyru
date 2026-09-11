package ru.cloudly.sync.mirror

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Локальное состояние зеркала. Четыре таблицы:
 *   • roots — пары «выбранная папка телефона ↔ папка в облаке»: пара заводится один раз,
 *             иначе при пропаже папки сверка не знает, куда возвращать содержимое;
 *   • dirs  — соответствие облачных папок и путей на телефоне: по нему правка из журнала
 *             (там известен только folderId) находится в файловой системе;
 *   • files — что уже выгружено: запись в облаке, inode, размер, дата и хэш;
 *   • meta  — курсор журнала и итог последнего прохода.
 *
 * Отдельная база, а не таблицы очереди: очередь руками собирают и чистят, а состояние зеркала
 * терять нельзя — без него удаление не отличить от «ещё не видели» и облако поедет вразнос.
 */
class MirrorStore(context: Context) : SQLiteOpenHelper(context, NAME, null, VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE roots(
              local_path TEXT PRIMARY KEY,
              cloud_id TEXT NOT NULL,
              cloud_path TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE dirs(
              cloud_id TEXT PRIMARY KEY,
              local_path TEXT NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX dirs_local ON dirs(local_path)")
        db.execSQL(
            """
            CREATE TABLE files(
              path TEXT PRIMARY KEY,
              cloud_folder_id TEXT NOT NULL,
              entry_id TEXT NOT NULL,
              inode INTEGER NOT NULL DEFAULT 0,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              sha256 TEXT,
              at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX files_entry ON files(entry_id)")
        db.execSQL("CREATE INDEX files_inode ON files(inode)")
        db.execSQL("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Состояние зеркала не пересобирается «на глаз»: потеря строки означает удаление
        // файла в облаке на следующем проходе. Поэтому апгрейд только добавляет колонки.
        if (oldVersion < 2) {
            runCatching { db.execSQL("ALTER TABLE files ADD COLUMN sha256 TEXT") }
        }
    }

    // ===== корни зеркала =====

    fun putRoot(localPath: String, cloudId: String, cloudPath: String) {
        writableDatabase.insertWithOnConflict(
            "roots",
            null,
            ContentValues().apply {
                put("local_path", localPath)
                put("cloud_id", cloudId)
                put("cloud_path", cloudPath)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
        registerDir(cloudId, localPath)
    }

    fun roots(): Map<String, MirrorRoot> =
        readableDatabase.rawQuery("SELECT local_path, cloud_id, cloud_path FROM roots", null).use { c ->
            buildMap {
                while (c.moveToNext()) put(c.getString(0), MirrorRoot(c.getString(0), c.getString(1), c.getString(2)))
            }
        }

    /** Папку сняли с выбора: пару убираем, а строки files остаются — вернуть выбор можно без последствий. */
    fun dropRoot(localPath: String) {
        writableDatabase.delete("roots", "local_path = ?", arrayOf(localPath))
    }

    // ===== папки =====

    fun registerDir(cloudId: String, localPath: String) {
        if (cloudId.isBlank()) return
        writableDatabase.insertWithOnConflict(
            "dirs",
            null,
            ContentValues().apply {
                put("cloud_id", cloudId)
                put("local_path", localPath)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun dirId(localPath: String): String? =
        readableDatabase.rawQuery("SELECT cloud_id FROM dirs WHERE local_path = ?", arrayOf(localPath)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    fun dirPath(cloudId: String): String? =
        readableDatabase.rawQuery("SELECT local_path FROM dirs WHERE cloud_id = ?", arrayOf(cloudId)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    fun dropDir(cloudId: String) {
        writableDatabase.delete("dirs", "cloud_id = ?", arrayOf(cloudId))
    }

    /** Папку на телефоне переименовали или перенесли: путь в паре меняется, id остаётся. */
    fun moveDir(cloudId: String, newLocalPath: String) {
        writableDatabase.update(
            "dirs",
            ContentValues().apply { put("local_path", newLocalPath) },
            "cloud_id = ?",
            arrayOf(cloudId),
        )
    }

    // ===== файлы =====

    fun files(): Map<String, MirrorRow> =
        readableDatabase.rawQuery(
            "SELECT path, cloud_folder_id, entry_id, inode, size, mtime, sha256 FROM files",
            null,
        ).use { c ->
            buildMap {
                while (c.moveToNext()) {
                    put(
                        c.getString(0),
                        MirrorRow(
                            path = c.getString(0),
                            cloudFolderId = c.getString(1),
                            entryId = c.getString(2),
                            inode = c.getLong(3),
                            size = c.getLong(4),
                            mtime = c.getLong(5),
                            sha256 = c.getString(6),
                        ),
                    )
                }
            }
        }

    fun fileByEntry(entryId: String): MirrorRow? =
        readableDatabase.rawQuery(
            "SELECT path, cloud_folder_id, entry_id, inode, size, mtime, sha256 FROM files WHERE entry_id = ?",
            arrayOf(entryId),
        ).use { c ->
            if (!c.moveToFirst()) return null
            MirrorRow(c.getString(0), c.getString(1), c.getString(2), c.getLong(3), c.getLong(4), c.getLong(5), c.getString(6))
        }

    fun fileCount(): Int =
        readableDatabase.rawQuery("SELECT COUNT(*) FROM files", null).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    fun putFile(row: MirrorRow) {
        writableDatabase.insertWithOnConflict(
            "files",
            null,
            ContentValues().apply {
                put("path", row.path)
                put("cloud_folder_id", row.cloudFolderId)
                put("entry_id", row.entryId)
                put("inode", row.inode)
                put("size", row.size)
                put("mtime", row.mtime)
                put("sha256", row.sha256)
                put("at", System.currentTimeMillis())
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    /** Переименование: путь меняется, запись в облаке остаётся той же. */
    fun moveFile(oldPath: String, row: MirrorRow) {
        writableDatabase.beginTransaction()
        try {
            writableDatabase.delete("files", "path = ?", arrayOf(oldPath))
            putFile(row)
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
    }

    fun dropFile(path: String) {
        writableDatabase.delete("files", "path = ?", arrayOf(path))
    }

    fun dropFileByEntry(entryId: String): String? {
        val row = fileByEntry(entryId) ?: return null
        dropFile(row.path)
        return row.path
    }

    /** Записи папки: нужны, когда папку удалили в облаке — поддерево уходит целиком. */
    fun filesUnder(localPath: String): List<MirrorRow> {
        val prefix = if (localPath.endsWith("/")) localPath else "$localPath/"
        return files().values.filter { it.path.startsWith(prefix) }
    }

    /** Папки поддерева: `cloud_id` к `local_path`. Нужны при переименовании и удалении папки. */
    fun dirsUnder(localPath: String): List<Pair<String, String>> {
        val prefix = if (localPath.endsWith("/")) localPath else "$localPath/"
        return readableDatabase.rawQuery(
            "SELECT cloud_id, local_path FROM dirs WHERE local_path = ? OR local_path LIKE ?",
            arrayOf(localPath, "$prefix%"),
        ).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0) to c.getString(1)) }
        }
    }

    // ===== прочее =====

    fun meta(key: String): String? =
        readableDatabase.rawQuery("SELECT value FROM meta WHERE key = ?", arrayOf(key)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    fun setMeta(key: String, value: String) {
        writableDatabase.insertWithOnConflict(
            "meta",
            null,
            ContentValues().apply {
                put("key", key)
                put("value", value)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun clearMeta(key: String) {
        writableDatabase.delete("meta", "key = ?", arrayOf(key))
    }

    fun cursor(): Long? = meta(KEY_CURSOR)?.toLongOrNull()

    fun setCursor(seq: Long) = setMeta(KEY_CURSOR, seq.toString())

    companion object {
        /** Курсор журнала: с какого seq продолжать догон облака. */
        const val KEY_CURSOR = "changes_cursor"

        /** Сколько удалений приостановлено предохранителем и почему (для экрана настроек). */
        const val KEY_BLOCKED = "blocked_deletes"

        /** Пользователь подтвердил удаление: следующий проход выполнит его один раз. */
        const val KEY_CONFIRMED = "delete_confirmed"

        /** Итог последнего прохода в человеческом виде. */
        const val KEY_REPORT = "last_report"

        /** Автоматические проходы выключены пользователем (ручная сверка работает). */
        const val KEY_PAUSED = "paused"

        /** Мгновенный режим включён: постоянный сервис держит процесс и уведомление висит. */
        const val KEY_LIVE = "live_always"

        const val KEY_DEVICE_ID = "device_id"

        private const val NAME = "cloudly-mirror.db"
        private const val VERSION = 1
    }
}
