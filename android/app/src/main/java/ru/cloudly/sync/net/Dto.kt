package ru.cloudly.sync.net

import org.json.JSONObject

/** Строка журнала изменений: снимок цели на момент события. */
data class Change(
    val seq: Long,
    val target: String,
    val op: String,
    val targetId: String,
    val folderId: String?,
    val name: String,
    val zone: String?,
    val sha256: String?,
    val size: Long?,
    val mime: String?,
    val clientMtime: Long?,
    val keepOffline: Boolean,
) {
    companion object {
        fun from(o: JSONObject) = Change(
            seq = o.getString("seq").toLong(),
            target = o.optString("target", "entry"),
            op = o.optString("op", "update"),
            targetId = o.optString("targetId"),
            folderId = if (o.isNull("folderId")) null else o.optString("folderId"),
            name = o.optString("name"),
            zone = if (o.isNull("zone")) null else o.optString("zone"),
            sha256 = if (o.isNull("sha256")) null else o.optString("sha256"),
            size = if (o.isNull("size")) null else o.optLong("size"),
            mime = if (o.isNull("mime")) null else o.optString("mime"),
            clientMtime = if (o.isNull("clientMtime")) null else o.optString("clientMtime").let(::parseIsoMillis),
            keepOffline = o.optBoolean("keepOffline", false),
        )
    }
}

data class ChangesPage(
    val nextSeq: Long,
    val hasMore: Boolean,
    val resetRequired: Boolean,
    val minSeq: Long?,
    val changes: List<Change>,
)

/** Что вернул сервер на попытку начать загрузку. */
data class UploadInit(
    val uploadId: String?,
    val deduped: Boolean,
    val replaced: Boolean,
    val direct: Boolean,
    val partSize: Int,
    val nextPart: Int,
    val partUrlTtlSec: Int,
    /** 409 stale_version: на сервере другая версия — клиент делает конфликтную копию. */
    val stale: Boolean = false,
    /** 409 in_trash: имя занято записью из корзины — сами не воскрешаем. */
    val inTrash: Boolean = false,
    /** 409 «имя уже существует»: запись есть, движок сверит хэш и решит. */
    val nameTaken: Boolean = false,
    val currentSha256: String? = null,
)

data class EntryRef(val id: String, val name: String)

data class RemoteEntry(
    val id: String,
    val name: String,
    val size: Long,
    val mime: String,
    val sha256: String,
    val keepOffline: Boolean,
    val clientMtime: Long?,
    /** Папка, в которой лежит запись — нужна для сопоставления при зеркале вниз. */
    val folderId: String? = null,
)

data class FolderChildren(val folderIds: Map<String, String>, val entries: List<RemoteEntry>)

/** ISO-8601 из сервера → миллисекунды (для сравнения с локальным mtime). */
fun parseIsoMillis(iso: String): Long = runCatching {
    java.time.Instant.parse(iso).toEpochMilli()
}.getOrElse { 0L }

fun isoOf(millis: Long): String = java.time.Instant.ofEpochMilli(millis).toString()
