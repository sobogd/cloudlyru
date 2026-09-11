package ru.cloudly.sync.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import ru.cloudly.sync.queue.Candidate
import ru.cloudly.sync.queue.QueuePlanner
import ru.cloudly.sync.queue.QueueRow
import ru.cloudly.sync.queue.Uploaded
import ru.cloudly.sync.queue.UploadedKey

/** Состояние файла в очереди. Автоматического запуска нет: пользователь жмёт «play» сам. */
enum class QueueState { PENDING, RUNNING, SKIPPED, DONE, FAILED }

/** Строка очереди: что выгружать, куда и что с этим уже произошло. */
data class QueueItem(
    val id: Long,
    val path: String,
    val relDir: String,
    val name: String,
    val size: Long,
    val mtime: Long,
    val section: Section,
    val target: String,
    val state: QueueState,
    val attempts: Int,
    val lastError: String?,
    val entryId: String?,
    /** Посчитанный хэш содержимого: пока файл не менялся, второй раз не считаем. */
    val sha256: String?,
    val createdAt: Long,
)

/**
 * Локальное состояние очереди. Две таблицы:
 *   • uploaded — что уже лежит в облаке, отдельно для каждой облачной папки: один и тот же
 *                файл может уехать и в «Файлы», и в «Фото», и «уже выгружено» в одной папке
 *                ничего не говорит про другую;
 *   • queue    — сама очередь: файл + цель, состояние, попытки и текст последней ошибки.
 *
 * Очередь переживает перезапуск и обновление приложения: выгрузка ручная, и терять
 * подготовленную работу при каждом запуске нельзя.
 */
class QueueStore(context: Context) : SQLiteOpenHelper(context, NAME, null, VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE uploaded(
              path TEXT NOT NULL,
              target TEXT NOT NULL,
              entry_id TEXT NOT NULL,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              at INTEGER NOT NULL,
              PRIMARY KEY(path, target)
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE queue(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL,
              rel_dir TEXT NOT NULL,
              name TEXT NOT NULL,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              section TEXT NOT NULL,
              target TEXT NOT NULL,
              state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              created_at INTEGER NOT NULL,
              started_at INTEGER,
              finished_at INTEGER,
              entry_id TEXT,
              sha256 TEXT
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE UNIQUE INDEX queue_unique ON queue(path, target)")
        db.execSQL("CREATE INDEX queue_state ON queue(state, id)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Очередь пересобирается проходом, а вот uploaded (что уже выгружено) терять нельзя.
        if (oldVersion < 2) {
            // кэш хэша: считать SHA-256 заново на каждую попытку большого видео — минуты работы
            db.execSQL("ALTER TABLE queue ADD COLUMN sha256 TEXT")
        }
    }

    // ===== что уже выгружено =====

    /** Ключ — файл и облачная папка: одна и та же запись может лежать в двух разделах. */
    fun uploaded(): Map<UploadedKey, Uploaded> =
        readableDatabase.rawQuery("SELECT path, target, entry_id, size, mtime FROM uploaded", null).use { c ->
            buildMap {
                while (c.moveToNext()) {
                    put(
                        UploadedKey(c.getString(0), c.getString(1)),
                        Uploaded(c.getString(2), c.getLong(3), c.getLong(4)),
                    )
                }
            }
        }

    fun markUploaded(path: String, target: String, entryId: String, size: Long, mtime: Long) {
        writableDatabase.insertWithOnConflict(
            "uploaded",
            null,
            ContentValues().apply {
                put("path", path)
                put("target", target)
                put("entry_id", entryId)
                put("size", size)
                put("mtime", mtime)
                put("at", System.currentTimeMillis())
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    // ===== очередь =====

    /**
     * Поставить кандидатов в очередь. Повторная постановка того же файла в ту же папку
     * не плодит строку; уже выгруженный файл, который после этого изменился, снова становится
     * ожидающим — иначе правка на телефоне никогда бы не доехала до облака.
     */
    fun enqueue(items: List<Candidate>): Int {
        if (items.isEmpty()) return 0
        var added = 0
        writableDatabase.beginTransaction()
        try {
            for (item in items) {
                val exists = readableDatabase.rawQuery(
                    "SELECT 1 FROM queue WHERE path = ? AND target = ?",
                    arrayOf(item.path, item.target),
                ).use { it.moveToFirst() }
                if (exists) {
                    writableDatabase.execSQL(
                        """
                        UPDATE queue SET rel_dir = ?, name = ?, size = ?, mtime = ?,
                          state = CASE WHEN state IN ('DONE','SKIPPED') THEN 'PENDING' ELSE state END,
                          last_error = CASE WHEN state IN ('DONE','SKIPPED') THEN NULL ELSE last_error END
                        WHERE path = ? AND target = ?
                        """.trimIndent(),
                        arrayOf(item.relDir, item.name, item.size, item.mtime, item.path, item.target),
                    )
                } else {
                    writableDatabase.execSQL(
                        """
                        INSERT INTO queue(path, rel_dir, name, size, mtime, section, target, state, created_at)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        """.trimIndent(),
                        arrayOf(
                            item.path, item.relDir, item.name, item.size, item.mtime,
                            item.section.name, item.target, QueueState.PENDING.name, System.currentTimeMillis(),
                        ),
                    )
                    added += 1
                }
            }
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
        return added
    }

    fun items(limit: Int = 2000): List<QueueItem> = readableDatabase.rawQuery(
        """
        SELECT * FROM queue
        ORDER BY CASE state WHEN 'RUNNING' THEN 0 WHEN 'PENDING' THEN 1 WHEN 'FAILED' THEN 2 ELSE 3 END, id
        LIMIT ?
        """.trimIndent(),
        arrayOf(limit.toString()),
    ).use { c -> buildList { while (c.moveToNext()) add(readItem(c)) } }

    fun counts(): Map<QueueState, Int> =
        readableDatabase.rawQuery("SELECT state, COUNT(*) FROM queue GROUP BY state", null).use { c ->
            buildMap {
                while (c.moveToNext()) {
                    runCatching { QueueState.valueOf(c.getString(0)) }.getOrNull()?.let { put(it, c.getInt(1)) }
                }
            }
        }

    fun countsFor(target: String): Map<QueueState, Int> =
        readableDatabase.rawQuery("SELECT state, COUNT(*) FROM queue WHERE target = ? GROUP BY state", arrayOf(target)).use { c ->
            buildMap {
                while (c.moveToNext()) {
                    runCatching { QueueState.valueOf(c.getString(0)) }.getOrNull()?.let { put(it, c.getInt(1)) }
                }
            }
        }

    /** Ждут запуска: кнопка «play» и счётчик в боттом-баре смотрят сюда. */
    fun waitingCount(): Int =
        readableDatabase.rawQuery("SELECT COUNT(*) FROM queue WHERE state IN ('PENDING','FAILED')", null).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }

    /** Строка очереди по пути файла: по ней веб просит выгрузить конкретный файл. */
    fun itemByPath(path: String): QueueItem? =
        readableDatabase.rawQuery("SELECT * FROM queue WHERE path = ? ORDER BY id LIMIT 1", arrayOf(path)).use { c ->
            if (c.moveToFirst()) readItem(c) else null
        }

    fun item(id: Long): QueueItem? = readableDatabase.rawQuery("SELECT * FROM queue WHERE id = ?", arrayOf(id.toString())).use { c ->
        if (c.moveToFirst()) readItem(c) else null
    }

    fun markRunning(id: Long) = update(
        id,
        mapOf("state" to QueueState.RUNNING.name, "started_at" to System.currentTimeMillis(), "last_error" to null),
    )

    fun markDone(id: Long, entryId: String) = update(
        id,
        mapOf("state" to QueueState.DONE.name, "entry_id" to entryId, "finished_at" to System.currentTimeMillis()),
    )

    /** Содержимое уже было в облаке: байты не передавались, но запись там есть. */
    fun markSkipped(id: Long, entryId: String) = update(
        id,
        mapOf("state" to QueueState.SKIPPED.name, "entry_id" to entryId, "finished_at" to System.currentTimeMillis()),
    )

    fun markFailed(id: Long, error: String, attempts: Int) = update(
        id,
        mapOf(
            "state" to QueueState.FAILED.name,
            "last_error" to error.take(500),
            "attempts" to attempts,
            "finished_at" to System.currentTimeMillis(),
        ),
    )

    /** Вернуть в ожидание: кнопка повтора на строке с ошибкой. */
    /** Запомнить посчитанный хэш: повторная попытка не должна перечитывать весь файл. */
    fun setSha(id: Long, sha256: String) = update(id, mapOf("sha256" to sha256))

    fun markPending(id: Long) = update(id, mapOf("state" to QueueState.PENDING.name, "last_error" to null))

    private fun update(id: Long, values: Map<String, Any?>) {
        val cv = ContentValues()
        values.forEach { (k, v) -> cv.putAny(k, v) }
        writableDatabase.update("queue", cv, "id = ?", arrayOf(id.toString()))
    }

    /**
     * Убрать из очереди то, чего больше не должно быть: папку отключили от раздела или файл
     * с телефона исчез. Ключи, которые остались кандидатами, и незатронутые разделы
     * остаются на месте.
     */
    fun prune(keep: Set<UploadedKey>, scannedSections: Set<Section>): Int {
        if (scannedSections.isEmpty()) return 0
        val rows = readableDatabase.rawQuery("SELECT id, path, target, section, state FROM queue", null).use { c ->
            buildList {
                while (c.moveToNext()) add(QueueRow(c.getLong(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4)))
            }
        }
        val doomed = QueuePlanner.obsolete(rows, keep, scannedSections)
        if (doomed.isEmpty()) return 0
        writableDatabase.beginTransaction()
        try {
            for (id in doomed) writableDatabase.delete("queue", "id = ?", arrayOf(id.toString()))
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
        return doomed.size
    }

    /** Убрать выполненные строки: очередь не должна превращаться в летопись. */
    fun clearFinished(): Int =
        writableDatabase.delete("queue", "state IN ('DONE','SKIPPED')", null)

    private fun readItem(c: Cursor) = QueueItem(
        id = c.getLong(c.getColumnIndexOrThrow("id")),
        path = c.getString(c.getColumnIndexOrThrow("path")),
        relDir = c.getString(c.getColumnIndexOrThrow("rel_dir")),
        name = c.getString(c.getColumnIndexOrThrow("name")),
        size = c.getLong(c.getColumnIndexOrThrow("size")),
        mtime = c.getLong(c.getColumnIndexOrThrow("mtime")),
        section = runCatching { Section.valueOf(c.getString(c.getColumnIndexOrThrow("section"))) }
            .getOrDefault(Section.FILES),
        target = c.getString(c.getColumnIndexOrThrow("target")),
        state = runCatching { QueueState.valueOf(c.getString(c.getColumnIndexOrThrow("state"))) }
            .getOrDefault(QueueState.PENDING),
        attempts = c.getInt(c.getColumnIndexOrThrow("attempts")),
        lastError = c.getString(c.getColumnIndexOrThrow("last_error")),
        entryId = c.getString(c.getColumnIndexOrThrow("entry_id")),
        sha256 = c.getString(c.getColumnIndexOrThrow("sha256")),
        createdAt = c.getLong(c.getColumnIndexOrThrow("created_at")),
    )

    private companion object {
        const val NAME = "cloudly-queue.db"
        const val VERSION = 2
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
