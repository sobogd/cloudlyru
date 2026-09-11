package ru.cloudly.sync.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Локальное состояние приложения. Модель односторонняя: облако — копия телефона,
 * поэтому хранить нужно только задачи, кэш уже выгруженного и очередь загрузок.
 * Никаких состояний «вытеснено/удалено» здесь нет: приложение ничего не удаляет само.
 */
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
              enabled INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        // Кэш выгруженного: без него библиотека хэшировалась бы целиком на каждом проходе
        db.execSQL(CACHE_TABLE)
        db.execSQL(
            """
            CREATE TABLE ops(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id INTEGER NOT NULL,
              rel_path TEXT NOT NULL,
              upload_id TEXT,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              next_attempt_at INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE UNIQUE INDEX ops_unique ON ops(job_id, rel_path)")
        db.execSQL("CREATE INDEX ops_ready ON ops(next_attempt_at)")
        db.execSQL("CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    /**
     * Обновление схемы без потери того, что дорого восстановить: задачи сохраняем,
     * кэш переносим (он экономит повторное хэширование), очередь пересобирается сканом.
     */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 3) {
            db.execSQL(CACHE_TABLE.replace("CREATE TABLE cache", "CREATE TABLE IF NOT EXISTS cache"))
            // переносим всё, что уже подтверждено сервером
            runCatching {
                db.execSQL(
                    """
                    INSERT OR REPLACE INTO cache(job_id, rel_path, local_path, local_size, local_mtime, sha256, entry_id, uploaded_at)
                    SELECT job_id, rel_path, local_path, local_size, local_mtime, sha256, remote_entry_id, uploaded_at
                    FROM items WHERE remote_entry_id IS NOT NULL AND remote_entry_id <> '' AND sha256 IS NOT NULL
                    """.trimIndent(),
                )
            }
            db.execSQL("DROP TABLE IF EXISTS items")
            db.execSQL("DROP TABLE IF EXISTS remote_deleted")
            db.execSQL("DROP TABLE IF EXISTS ops")
            db.execSQL(
                """
                CREATE TABLE ops(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  job_id INTEGER NOT NULL,
                  rel_path TEXT NOT NULL,
                  upload_id TEXT,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT,
                  next_attempt_at INTEGER NOT NULL DEFAULT 0,
                  created_at INTEGER NOT NULL
                )
                """.trimIndent(),
            )
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS ops_unique ON ops(job_id, rel_path)")
            db.execSQL("CREATE INDEX IF NOT EXISTS ops_ready ON ops(next_attempt_at)")
        }
    }

    // ===== задачи =====

    fun addJob(
        sourceDir: String,
        targetFolderId: String,
        targetPath: String,
        zone: String,
        wifiOnly: Boolean = false,
        includeSubfolders: Boolean = true,
    ): Long = writableDatabase.insertOrThrow(
        "jobs",
        null,
        ContentValues().apply {
            put("source_dir", sourceDir)
            put("target_folder_id", targetFolderId)
            put("target_path", targetPath)
            put("zone", zone)
            put("include_subfolders", if (includeSubfolders) 1 else 0)
            put("wifi_only", if (wifiOnly) 1 else 0)
            put("created_at", System.currentTimeMillis())
        },
    )

    fun jobs(enabledOnly: Boolean = false): List<Job> {
        val where = if (enabledOnly) " WHERE enabled = 1" else ""
        return readableDatabase.rawQuery("SELECT * FROM jobs$where ORDER BY id", null).use { c ->
            buildList { while (c.moveToNext()) add(readJob(c)) }
        }
    }

    fun updateJob(id: Long, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("jobs", cv, "id = ?", arrayOf(id.toString()))
    }

    fun deleteJob(id: Long) {
        writableDatabase.delete("jobs", "id = ?", arrayOf(id.toString()))
        writableDatabase.delete("cache", "job_id = ?", arrayOf(id.toString()))
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
        enabled = c.getInt(c.getColumnIndexOrThrow("enabled")) == 1,
    )

    // ===== кэш выгруженного =====

    fun cacheOf(jobId: Long): List<Cached> =
        readableDatabase.rawQuery("SELECT * FROM cache WHERE job_id = ?", arrayOf(jobId.toString())).use { c ->
            buildList { while (c.moveToNext()) add(readCached(c)) }
        }

    fun cacheAll(): List<Cached> =
        readableDatabase.rawQuery("SELECT * FROM cache", null).use { c ->
            buildList { while (c.moveToNext()) add(readCached(c)) }
        }

    fun cacheEntry(jobId: Long, relPath: String): Cached? =
        readableDatabase.rawQuery(
            "SELECT * FROM cache WHERE job_id = ? AND rel_path = ?",
            arrayOf(jobId.toString(), relPath),
        ).use { c -> if (c.moveToFirst()) readCached(c) else null }

    fun putCache(item: Cached) {
        writableDatabase.insertWithOnConflict("cache", null, cachedValues(item), SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun updateCache(jobId: Long, relPath: String, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("cache", cv, "job_id = ? AND rel_path = ?", arrayOf(jobId.toString(), relPath))
    }

    fun deleteCache(jobId: Long, relPath: String) {
        writableDatabase.delete("cache", "job_id = ? AND rel_path = ?", arrayOf(jobId.toString(), relPath))
    }

    private fun cachedValues(i: Cached) = ContentValues().apply {
        put("job_id", i.jobId)
        put("rel_path", i.relPath)
        put("local_path", i.localPath)
        put("local_size", i.localSize)
        put("local_mtime", i.localMtime)
        put("sha256", i.sha256)
        put("entry_id", i.entryId)
        put("uploaded_at", i.uploadedAt)
    }

    private fun readCached(c: Cursor) = Cached(
        jobId = c.getLong(c.getColumnIndexOrThrow("job_id")),
        relPath = c.getString(c.getColumnIndexOrThrow("rel_path")),
        localPath = c.getString(c.getColumnIndexOrThrow("local_path")),
        localSize = c.getLong(c.getColumnIndexOrThrow("local_size")),
        localMtime = c.getLong(c.getColumnIndexOrThrow("local_mtime")),
        sha256 = c.getString(c.getColumnIndexOrThrow("sha256")),
        entryId = c.getString(c.getColumnIndexOrThrow("entry_id")),
        uploadedAt = c.getLongOrNull("uploaded_at"),
    )

    /** Сколько уже выгружено: для карточки задачи и экрана «освободить место». */
    fun uploadedCount(jobId: Long? = null): Int {
        val sql = if (jobId == null) {
            "SELECT COUNT(*) FROM cache WHERE entry_id IS NOT NULL AND entry_id <> ''"
        } else {
            "SELECT COUNT(*) FROM cache WHERE job_id = ? AND entry_id IS NOT NULL AND entry_id <> ''"
        }
        val args = if (jobId == null) null else arrayOf(jobId.toString())
        return readableDatabase.rawQuery(sql, args).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }
    }

    fun uploadedBytes(jobId: Long? = null): Long {
        val sql = if (jobId == null) {
            "SELECT COALESCE(SUM(local_size), 0) FROM cache WHERE entry_id IS NOT NULL AND entry_id <> ''"
        } else {
            "SELECT COALESCE(SUM(local_size), 0) FROM cache WHERE job_id = ? AND entry_id IS NOT NULL AND entry_id <> ''"
        }
        val args = if (jobId == null) null else arrayOf(jobId.toString())
        return readableDatabase.rawQuery(sql, args).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }
    }

    // ===== очередь загрузок =====

    fun enqueue(jobId: Long, relPath: String) {
        val now = System.currentTimeMillis()
        // повторная постановка снимает паузу после ошибки, но сохраняет upload_id:
        // частично залитый файл продолжается, а не начинается заново
        writableDatabase.execSQL(
            "INSERT INTO ops(job_id, rel_path, attempts, next_attempt_at, created_at) VALUES(?,?,0,?,?) " +
                "ON CONFLICT(job_id, rel_path) DO UPDATE SET next_attempt_at = 0, last_error = NULL",
            arrayOf(jobId, relPath, now, now),
        )
    }

    fun nextOp(jobId: Long, now: Long): Op? = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE job_id = ? AND next_attempt_at <= ? ORDER BY id LIMIT 1",
        arrayOf(jobId.toString(), now.toString()),
    ).use { c -> if (c.moveToFirst()) readOp(c) else null }

    fun opFor(jobId: Long, relPath: String): Op? = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE job_id = ? AND rel_path = ?",
        arrayOf(jobId.toString(), relPath),
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

    fun opCount(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM ops", null).use { c ->
        if (c.moveToFirst()) c.getInt(0) else 0
    }

    /** Сколько операций ждёт повтора и когда ближайшая: иначе «ничего не происходит» непонятно. */
    fun opSummary(): OpSummary {
        val now = System.currentTimeMillis()
        var ready = 0
        var waiting = 0
        var soonest = 0L
        readableDatabase.rawQuery("SELECT next_attempt_at, COUNT(*) FROM ops GROUP BY next_attempt_at", null).use { c ->
            while (c.moveToNext()) {
                val at = c.getLong(0)
                val count = c.getInt(1)
                if (at <= now) ready += count else {
                    waiting += count
                    if (soonest == 0L || at < soonest) soonest = at
                }
            }
        }
        return OpSummary(ready, waiting, soonest)
    }

    fun failedOps(limit: Int = 5): List<Op> = readableDatabase.rawQuery(
        "SELECT * FROM ops WHERE last_error IS NOT NULL AND last_error <> '' ORDER BY id LIMIT ?",
        arrayOf(limit.toString()),
    ).use { c -> buildList { while (c.moveToNext()) add(readOp(c)) } }

    fun resetOps(jobId: Long? = null) {
        val cv = ContentValues().apply {
            put("attempts", 0)
            put("next_attempt_at", 0)
            putNull("last_error")
        }
        if (jobId == null) writableDatabase.update("ops", cv, null, null)
        else writableDatabase.update("ops", cv, "job_id = ?", arrayOf(jobId.toString()))
    }

    private fun readOp(c: Cursor) = Op(
        id = c.getLong(c.getColumnIndexOrThrow("id")),
        jobId = c.getLong(c.getColumnIndexOrThrow("job_id")),
        relPath = c.getString(c.getColumnIndexOrThrow("rel_path")),
        uploadId = c.getString(c.getColumnIndexOrThrow("upload_id")),
        attempts = c.getInt(c.getColumnIndexOrThrow("attempts")),
        lastError = c.getString(c.getColumnIndexOrThrow("last_error")),
        nextAttemptAt = c.getLong(c.getColumnIndexOrThrow("next_attempt_at")),
    )

    // ===== мелкое хранилище (заметки, прогресс) =====

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
        val enabled: Boolean,
    )

    data class Cached(
        val jobId: Long,
        val relPath: String,
        val localPath: String,
        val localSize: Long,
        val localMtime: Long,
        val sha256: String,
        val entryId: String?,
        val uploadedAt: Long?,
    )

    data class Op(
        val id: Long,
        val jobId: Long,
        val relPath: String,
        val uploadId: String?,
        val attempts: Int,
        val lastError: String?,
        val nextAttemptAt: Long,
    )

    data class OpSummary(val ready: Int, val waiting: Int, val soonestAt: Long)

    companion object {
        const val NAME = "cloudly-sync.db"
        const val VERSION = 3

        private const val CACHE_TABLE = """
            CREATE TABLE cache(
              job_id INTEGER NOT NULL,
              rel_path TEXT NOT NULL,
              local_path TEXT NOT NULL,
              local_size INTEGER NOT NULL,
              local_mtime INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              entry_id TEXT,
              uploaded_at INTEGER,
              PRIMARY KEY(job_id, rel_path)
            )
        """
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
