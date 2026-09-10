package ru.cloudly.sync.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Локальное состояние синхронизации: задачи, состояние файлов, очередь операций, курсор журнала. */
class Db(context: Context) : SQLiteOpenHelper(context, NAME, null, VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE jobs(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_dir TEXT NOT NULL,
              target_folder_id TEXT NOT NULL,
              target_path TEXT NOT NULL,
              zone TEXT NOT NULL,
              include_subfolders INTEGER NOT NULL DEFAULT 1,
              wifi_only INTEGER NOT NULL DEFAULT 0,
              keep_days INTEGER NOT NULL DEFAULT -1,
              enabled INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE items(
              job_id INTEGER NOT NULL,
              rel_path TEXT NOT NULL,
              local_path TEXT NOT NULL,
              local_size INTEGER NOT NULL,
              local_mtime INTEGER NOT NULL,
              sha256 TEXT,
              remote_entry_id TEXT,
              remote_sha256 TEXT,
              remote_folder_id TEXT,
              name TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'new',
              keep_offline INTEGER NOT NULL DEFAULT 0,
              uploaded_at INTEGER,
              PRIMARY KEY(job_id, rel_path)
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE ops(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id INTEGER NOT NULL,
              rel_path TEXT NOT NULL,
              kind TEXT NOT NULL,
              upload_id TEXT,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              next_attempt_at INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE UNIQUE INDEX ops_unique ON ops(job_id, rel_path, kind)")
        db.execSQL("CREATE INDEX ops_ready ON ops(job_id, next_attempt_at)")
        db.execSQL("CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    /**
     * Обновление схемы БЕЗ потери состояния: раньше здесь дропались все таблицы, то есть при
     * первом же повышении версии терялись курсор журнала, состояние вытеснения и очередь —
     * приложение заново заливало всю библиотеку.
     */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("CREATE INDEX IF NOT EXISTS ops_ready ON ops(job_id, next_attempt_at)")
            db.execSQL("DROP TABLE IF EXISTS remote_deleted")
        }
    }

    // ===== задачи =====

    fun addJob(
        sourceDir: String,
        targetFolderId: String,
        targetPath: String,
        zone: String,
        keepDays: Int = -1,
        wifiOnly: Boolean = false,
    ): Long {
        val now = System.currentTimeMillis()
        return writableDatabase.insertOrThrow(
            "jobs",
            null,
            ContentValues().apply {
                put("source_dir", sourceDir)
                put("target_folder_id", targetFolderId)
                put("target_path", targetPath)
                put("zone", zone)
                put("keep_days", keepDays)
                put("wifi_only", if (wifiOnly) 1 else 0)
                put("created_at", now)
            },
        )
    }

    /** Сколько файлов в каком состоянии: считает SQL, а не обход всех строк в Kotlin. */
    fun stateCounts(jobId: Long): Map<String, Int> {
        val out = HashMap<String, Int>()
        readableDatabase.rawQuery(
            "SELECT state, COUNT(*) FROM items WHERE job_id = ? GROUP BY state",
            arrayOf(jobId.toString()),
        ).use { c -> while (c.moveToNext()) out[c.getString(0)] = c.getInt(1) }
        return out
    }

    fun itemCount(jobId: Long): Int = readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM items WHERE job_id = ?",
        arrayOf(jobId.toString()),
    ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    fun opCount(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM ops", null).use { c ->
        if (c.moveToFirst()) c.getInt(0) else 0
    }

    /** Операции, которые не прошли: показываем текст последней ошибки. */
    fun failedOps(limit: Int = 5): List<Op> = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE last_error IS NOT NULL AND last_error <> '' ORDER BY id LIMIT ?",
        arrayOf(limit.toString()),
    ).use { c -> buildList { while (c.moveToNext()) add(readOp(c)) } }

    fun jobs(enabledOnly: Boolean = false): List<Job> {
        val where = if (enabledOnly) " WHERE enabled = 1" else ""
        return readableDatabase.rawQuery("SELECT * FROM jobs$where ORDER BY id", null).use { c ->
            buildList { while (c.moveToNext()) add(readJob(c)) }
        }
    }

    fun job(id: Long): Job? = readableDatabase.rawQuery("SELECT * FROM jobs WHERE id = ?", arrayOf(id.toString())).use { c ->
        if (c.moveToFirst()) readJob(c) else null
    }

    fun updateJob(id: Long, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("jobs", cv, "id = ?", arrayOf(id.toString()))
    }

    fun deleteJob(id: Long) {
        writableDatabase.delete("jobs", "id = ?", arrayOf(id.toString()))
        writableDatabase.delete("items", "job_id = ?", arrayOf(id.toString()))
        writableDatabase.delete("ops", "job_id = ?", arrayOf(id.toString()))
    }

    private fun readJob(c: Cursor) = Job(
        id = c.getLong(c.getColumnIndexOrThrow("id")),
        sourceDir = c.getString(c.getColumnIndexOrThrow("source_dir")),
        targetFolderId = c.getString(c.getColumnIndexOrThrow("target_folder_id")),
        targetPath = c.getString(c.getColumnIndexOrThrow("target_path")),
        zone = c.getString(c.getColumnIndexOrThrow("zone")),
        includeSubfolders = c.getInt(c.getColumnIndexOrThrow("include_subfolders")) == 1,
        wifiOnly = c.getInt(c.getColumnIndexOrThrow("wifi_only")) == 1,
        keepDays = c.getInt(c.getColumnIndexOrThrow("keep_days")),
        enabled = c.getInt(c.getColumnIndexOrThrow("enabled")) == 1,
    )

    // ===== состояние файлов =====

    fun itemsOf(jobId: Long): List<Item> =
        readableDatabase.rawQuery("SELECT * FROM items WHERE job_id = ?", arrayOf(jobId.toString())).use { c ->
            buildList { while (c.moveToNext()) add(readItem(c)) }
        }

    fun item(jobId: Long, relPath: String): Item? =
        readableDatabase.rawQuery("SELECT * FROM items WHERE job_id = ? AND rel_path = ?", arrayOf(jobId.toString(), relPath)).use { c ->
            if (c.moveToFirst()) readItem(c) else null
        }

    fun putItem(item: Item) {
        writableDatabase.insertWithOnConflict("items", null, itemValues(item), SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun updateItem(jobId: Long, relPath: String, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("items", cv, "job_id = ? AND rel_path = ?", arrayOf(jobId.toString(), relPath))
    }

    fun deleteItem(jobId: Long, relPath: String) {
        writableDatabase.delete("items", "job_id = ? AND rel_path = ?", arrayOf(jobId.toString(), relPath))
    }

    fun itemsWithSha(jobId: Long): Map<String, Item> = itemsOf(jobId)
        .filter { it.sha256 != null }
        .associateBy { it.sha256!! }

    private fun itemValues(i: Item) = ContentValues().apply {
        put("job_id", i.jobId)
        put("rel_path", i.relPath)
        put("local_path", i.localPath)
        put("local_size", i.localSize)
        put("local_mtime", i.localMtime)
        put("sha256", i.sha256)
        put("remote_entry_id", i.remoteEntryId)
        put("remote_sha256", i.remoteSha256)
        put("remote_folder_id", i.remoteFolderId)
        put("name", i.name)
        put("state", i.state)
        put("keep_offline", if (i.keepOffline) 1 else 0)
        put("uploaded_at", i.uploadedAt)
    }

    private fun readItem(c: Cursor) = Item(
        jobId = c.getLong(c.getColumnIndexOrThrow("job_id")),
        relPath = c.getString(c.getColumnIndexOrThrow("rel_path")),
        localPath = c.getString(c.getColumnIndexOrThrow("local_path")),
        localSize = c.getLong(c.getColumnIndexOrThrow("local_size")),
        localMtime = c.getLong(c.getColumnIndexOrThrow("local_mtime")),
        sha256 = c.getString(c.getColumnIndexOrThrow("sha256")),
        remoteEntryId = c.getString(c.getColumnIndexOrThrow("remote_entry_id")),
        remoteSha256 = c.getString(c.getColumnIndexOrThrow("remote_sha256")),
        remoteFolderId = c.getString(c.getColumnIndexOrThrow("remote_folder_id")),
        name = c.getString(c.getColumnIndexOrThrow("name")),
        state = c.getString(c.getColumnIndexOrThrow("state")),
        keepOffline = c.getInt(c.getColumnIndexOrThrow("keep_offline")) == 1,
        uploadedAt = c.getLongOrNull("uploaded_at"),
    )

    // ===== очередь операций =====

    fun enqueueOp(jobId: Long, relPath: String, kind: String) {
        val now = System.currentTimeMillis()
        // Повторная постановка обновляет срок и снимает прошлую ошибку, но НЕ трогает upload_id:
        // прогресс частично залитого файла сохраняется. Раньше был CONFLICT_IGNORE, из-за чего
        // операция с истёкшим «не повторять» оставалась мёртвой навсегда.
        writableDatabase.execSQL(
            "INSERT INTO ops(job_id, rel_path, kind, attempts, next_attempt_at, created_at) VALUES(?,?,?,0,?,?) " +
                "ON CONFLICT(job_id, rel_path, kind) DO UPDATE SET next_attempt_at = 0, last_error = NULL",
            arrayOf(jobId, relPath, kind, now, now),
        )
    }

    fun nextOp(now: Long): Op? = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE next_attempt_at <= ? ORDER BY id LIMIT 1",
        arrayOf(now.toString()),
    ).use { c -> if (c.moveToFirst()) readOp(c) else null }

    /** Операции конкретной задачи: проход по одной папке не должен утаскивать чужие. */
    fun nextOpForJob(jobId: Long, now: Long): Op? = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE job_id = ? AND next_attempt_at <= ? ORDER BY id LIMIT 1",
        arrayOf(jobId.toString(), now.toString()),
    ).use { c -> if (c.moveToFirst()) readOp(c) else null }

    fun ops(): List<Op> = readableDatabase.rawQuery("SELECT * FROM ops ORDER BY id", null).use { c ->
        buildList { while (c.moveToNext()) add(readOp(c)) }
    }

    fun updateOp(id: Long, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("ops", cv, "id = ?", arrayOf(id.toString()))
    }

    fun deleteOp(id: Long) = writableDatabase.delete("ops", "id = ?", arrayOf(id.toString()))

    private fun readOp(c: Cursor) = Op(
        id = c.getLong(c.getColumnIndexOrThrow("id")),
        jobId = c.getLong(c.getColumnIndexOrThrow("job_id")),
        relPath = c.getString(c.getColumnIndexOrThrow("rel_path")),
        kind = c.getString(c.getColumnIndexOrThrow("kind")),
        uploadId = c.getString(c.getColumnIndexOrThrow("upload_id")),
        attempts = c.getInt(c.getColumnIndexOrThrow("attempts")),
        lastError = c.getString(c.getColumnIndexOrThrow("last_error")),
    )

    // ===== курсор журнала =====

    fun kv(key: String): String? = readableDatabase.rawQuery("SELECT value FROM kv WHERE key = ?", arrayOf(key)).use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    }

    fun putKv(key: String, value: String) {
        writableDatabase.insertWithOnConflict(
            "kv",
            null,
            ContentValues().apply { put("key", key); put("value", value) },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    data class Job(
        val id: Long,
        val sourceDir: String,
        val targetFolderId: String,
        val targetPath: String,
        val zone: String,
        val includeSubfolders: Boolean,
        val wifiOnly: Boolean,
        val keepDays: Int,
        val enabled: Boolean,
    )

    data class Item(
        val jobId: Long,
        val relPath: String,
        val localPath: String,
        val localSize: Long,
        val localMtime: Long,
        val sha256: String?,
        val remoteEntryId: String?,
        val remoteSha256: String?,
        val remoteFolderId: String?,
        val name: String,
        val state: String,
        val keepOffline: Boolean,
        val uploadedAt: Long?,
    )

    data class Op(val id: Long, val jobId: Long, val relPath: String, val kind: String, val uploadId: String?, val attempts: Int, val lastError: String?)

    companion object {
        const val NAME = "cloudly-sync.db"
        const val VERSION = 2

        const val STATE_NEW = "new"
        const val STATE_SYNCED = "synced"
        const val STATE_EVICTED = "evicted"

        const val OP_UPLOAD = "upload"
        const val OP_DOWNLOAD = "download"
        const val OP_DELETE = "delete"
        const val OP_MOVE = "move"
    }
}

/** ContentValues не умеет Any: раскладываем по типам, остальное пишем строкой. */
private fun ContentValues.putAny(key: String, value: Any?) {
    when (value) {
        null -> putNull(key)
        is String -> put(key, value)
        is Int -> put(key, value)
        is Long -> put(key, value)
        is Boolean -> put(key, value)
        is Double -> put(key, value)
        is Float -> put(key, value)
        is ByteArray -> put(key, value)
        else -> put(key, value.toString())
    }
}

private fun Cursor.getLongOrNull(name: String): Long? {
    val idx = getColumnIndexOrThrow(name)
    return if (isNull(idx)) null else getLong(idx)
}
