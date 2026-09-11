package ru.cloudly.sync.net

import org.json.JSONObject

/** Что вернул сервер на попытку начать загрузку. */
data class UploadInit(
    /** id записи в дереве: сервер отдаёт его и при дедупе (байты не передавались) */
    val entryId: String = "",
    val uploadId: String?,
    val deduped: Boolean,
    val replaced: Boolean,
    val direct: Boolean,
    val partSize: Int,
    val nextPart: Int,
    val partUrlTtlSec: Int,
    /** Хост хранилища с сервера — для диагностики сети на телефоне. */
    val storageHost: String? = null,
    /** 409 stale_version: на сервере другая версия — клиент делает конфликтную копию. */
    val stale: Boolean = false,
    /** 409 in_trash: имя занято записью из корзины — сами не воскрешаем. */
    val inTrash: Boolean = false,
    /** 409 «имя уже существует»: запись есть, движок сверит хэш и решит. */
    val nameTaken: Boolean = false,
    val currentSha256: String? = null,
)

data class EntryRef(val id: String, val name: String)

/** Ответ GET /uploads/:id — с какой части продолжать и каким способом лить дальше. */
data class UploadStatus(val nextPart: Int, val partSize: Int, val direct: Boolean)

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

/** Команда сервера телефону (GET /devices/:id/commands). */
data class DeviceCommand(val id: String, val kind: String, val payload: JSONObject?)

/** Системные папки владельца (GET /auth/me). */
data class SystemFolders(val photoFolderId: String?, val phoneFolderId: String?)

/** Последняя опубликованная сборка приложения (GET /app/android). */
data class AppRelease(
    val versionCode: Long,
    val versionName: String,
    val size: Long,
    val sha256: String,
    /** Постоянная ссылка на APK: https://<сервер>/apk */
    val url: String,
)

/** ISO-8601 из сервера → миллисекунды (для сравнения с локальным mtime). */
fun parseIsoMillis(iso: String): Long = runCatching {
    java.time.Instant.parse(iso).toEpochMilli()
}.getOrElse { 0L }

fun isoOf(millis: Long): String = java.time.Instant.ofEpochMilli(millis).toString()
