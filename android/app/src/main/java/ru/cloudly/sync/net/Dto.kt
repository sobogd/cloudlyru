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
    val clientMtime: Long?,
    /** Папка, в которой лежит запись — нужна для сопоставления при зеркале вниз. */
    val folderId: String? = null,
)

data class FolderChildren(val folderIds: Map<String, String>, val entries: List<RemoteEntry>)

/** Системные папки владельца (GET /auth/me). */
data class SystemFolders(
    val photoFolderId: String?,
    val phoneFolderId: String?,
    /** Корень зеркала этого устройства («<Имя устройства> - Файлы»): сервер заводит его сам. */
    val mirrorFolderId: String? = null,
)

/** Ответ GET /auth/me целиком: кроме папок — личность этого устройства. */
data class MeInfo(
    val login: String,
    val photoFolderId: String?,
    val phoneFolderId: String?,
    val mirrorFolderId: String?,
    /**
     * id устройства в журнале изменений. По нему клиент отличает свои же правки от чужих:
     * своя выгрузка не должна приезжать назад и зацикливать догон.
     */
    val deviceId: String?,
)

/**
 * Строка журнала изменений (GET /sync/changes). Журнал append-only: клиент держит курсор
 * по `seq` и применяет строки по порядку, а снимок в строке избавляет от запросов за деталями.
 */
data class CloudChange(
    val seq: Long,
    /** entry | folder */
    val target: String,
    /** create | update | move | delete | restore (в старых строках журнала встречается pin) */
    val op: String,
    val targetId: String,
    /** родительская папка цели на момент события: по ней правка находится в зеркале */
    val folderId: String?,
    val name: String,
    val sha256: String?,
    val size: Long,
    val mime: String?,
    val clientMtime: Long?,
    /** какое устройство сделало изменение; null — изменение из веба или от сервера */
    val deviceId: String?,
)

/** Страница журнала: `hasMore` — догонять сразу, не дожидаясь следующего прохода. */
data class ChangesPage(
    val nextSeq: Long,
    val hasMore: Boolean,
    /** Курсор старше журнала (или впереди него): нужен полный проход по содержимому папки. */
    val resetRequired: Boolean,
    val changes: List<CloudChange>,
)

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
