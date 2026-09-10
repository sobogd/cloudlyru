package ru.cloudly.sync.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import ru.cloudly.sync.data.Prefs
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit

/** Ошибка сервера с кодом из тела ответа (409 stale_version, 429 и т.п.). */
class ApiException(val status: Int, val code: String, message: String, val body: JSONObject?) :
    IOException(message)

/**
 * Клиент REST API облака. Авторизация — ApiToken в Bearer (не cookie-сессия: телефон
 * не должен хранить логин с паролем). Все методы бросают ApiException/IOException,
 * повторями занимается движок синхронизации.
 */
class Api(private val prefs: Prefs) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    private val json = "application/json; charset=utf-8".toMediaType()

    private fun url(path: String) = prefs.serverUrl.trimEnd('/') + "/api/v1" + path

    private fun request(path: String, method: String = "GET", body: JSONObject? = null, urlOverride: String? = null): Response {
        val builder = Request.Builder().url(urlOverride ?: url(path))
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((body ?: JSONObject()).toString().toRequestBody(json))
            "PATCH" -> builder.patch((body ?: JSONObject()).toString().toRequestBody(json))
            "DELETE" -> builder.delete()
        }
        builder.header("Authorization", "Bearer ${prefs.token}")
        builder.header("Accept", "application/json")
        return http.newCall(builder.build()).execute()
    }

    private fun parse(response: Response): JSONObject {
        val text = response.body?.string().orEmpty()
        if (!response.isSuccessful) {
            val obj = runCatching { JSONObject(text) }.getOrNull()
            throw ApiException(
                response.code,
                obj?.optString("code").orEmpty(),
                obj?.optString("message").orEmpty().ifBlank { "HTTP ${response.code}" },
                obj,
            )
        }
        return if (text.isBlank()) JSONObject() else JSONObject(text)
    }

    /** Проверка токена и адреса сервера. */
    fun me(): String = parse(request("/auth/me")).optJSONObject("user")?.optString("login").orEmpty()

    fun changes(since: String, limit: Int = 200): ChangesPage {
        val o = parse(request("/sync/changes?since=$since&limit=$limit"))
        val arr = o.optJSONArray("changes") ?: JSONArray()
        val list = ArrayList<Change>(arr.length())
        for (i in 0 until arr.length()) list.add(Change.from(arr.getJSONObject(i)))
        return ChangesPage(
            nextSeq = o.optString("nextSeq", since).toLong(),
            hasMore = o.optBoolean("hasMore", false),
            resetRequired = o.optBoolean("resetRequired", false),
            minSeq = if (o.isNull("minSeq")) null else o.optString("minSeq").toLong(),
            changes = list,
        )
    }

    /** Что из содержимого уже есть на сервере (батч до 500). */
    fun have(shas: List<String>): Set<String> {
        if (shas.isEmpty()) return emptySet()
        val body = JSONObject().put("sha256", JSONArray(shas))
        val o = parse(request("/sync/have", "POST", body))
        val present = o.optJSONArray("present") ?: JSONArray()
        val out = HashSet<String>(present.length())
        for (i in 0 until present.length()) out.add(present.getJSONObject(i).optString("sha256"))
        return out
    }

    /** Идемпотентный mkdir: возвращает id папки по пути от корня. */
    fun ensurePath(path: String, parentId: String? = null): String {
        val body = JSONObject().put("path", path)
        if (parentId != null) body.put("parentId", parentId)
        return parse(request("/folders/ensure-path", "POST", body)).optString("id")
    }

    /** Дерево папки: имена подпапок и записи (нужно для первичного сопоставления). */
    fun children(folderId: String): FolderChildren {
        val o = parse(request("/folders/$folderId/children"))
        val folders = o.optJSONArray("folders") ?: JSONArray()
        val map = HashMap<String, String>()
        for (i in 0 until folders.length()) {
            val f = folders.getJSONObject(i)
            map[f.optString("name")] = f.optString("id")
        }
        val entries = o.optJSONArray("entries") ?: JSONArray()
        val list = ArrayList<RemoteEntry>(entries.length())
        for (i in 0 until entries.length()) {
            val e = entries.getJSONObject(i)
            list.add(
                RemoteEntry(
                    id = e.optString("id"),
                    name = e.optString("name"),
                    size = e.optLong("size"),
                    mime = e.optString("mime"),
                    sha256 = e.optString("sha256"),
                    keepOffline = e.optBoolean("keepOffline", false),
                    clientMtime = if (e.isNull("clientMtime")) null else parseIsoMillis(e.optString("clientMtime")),
                ),
            )
        }
        return FolderChildren(map, list)
    }

    /**
     * Начать загрузку. `expectedSha256` — оптимистичная блокировка: сервер откажет (409
     * stale_version), если на его стороне уже другая версия файла.
     */
    fun initUpload(
        folderId: String,
        name: String,
        size: Long,
        mime: String,
        sha256: String?,
        replace: Boolean,
        clientMtime: Long,
        expectedSha256: String?,
    ): UploadInit {
        val body = JSONObject().apply {
            put("folderId", folderId)
            put("name", name)
            put("size", size)
            put("mime", mime)
            put("mode", "direct")
            put("replace", replace)
            put("clientMtime", isoOf(clientMtime))
            if (sha256 != null) put("sha256", sha256)
            if (replace && expectedSha256 != null) put("expectedSha256", expectedSha256)
        }
        val response = request("/uploads", "POST", body)
        if (response.code == 409) {
            val obj = runCatching { JSONObject(response.body?.string().orEmpty()) }.getOrNull()
            return UploadInit(
                uploadId = null,
                deduped = false,
                replaced = false,
                direct = false,
                partSize = 0,
                nextPart = 0,
                partUrlTtlSec = 0,
                stale = true,
                currentSha256 = obj?.optString("sha256")?.takeIf { it.isNotBlank() && it != "null" },
            )
        }
        val o = parse(response)
        return UploadInit(
            uploadId = if (o.isNull("uploadId")) null else o.optString("uploadId"),
            deduped = o.optBoolean("deduped", false),
            replaced = o.optBoolean("replaced", false),
            direct = o.optBoolean("direct", false),
            partSize = o.optInt("partSize", 16 * 1024 * 1024),
            nextPart = o.optInt("nextPart", 1),
            partUrlTtlSec = o.optInt("partUrlTtlSec", 900),
        )
    }

    /** Состояние сессии: с какой части продолжать после обрыва. */
    fun uploadStatus(uploadId: String): Pair<Int, Int> {
        val o = parse(request("/uploads/$uploadId"))
        return o.optInt("nextPart", 1) to o.optInt("partSize", 16 * 1024 * 1024)
    }

    fun partUrl(uploadId: String, part: Int): String =
        parse(request("/uploads/$uploadId/url/$part")).optString("url")

    fun registerPart(uploadId: String, part: Int, etag: String, size: Int) {
        parse(request("/uploads/$uploadId/parts/$part", "PUT", JSONObject().put("etag", etag).put("size", size)))
    }

    fun relayChunk(uploadId: String, part: Int, bytes: ByteArray, offset: Int, length: Int) {
        val req = Request.Builder()
            .url(url("/uploads/$uploadId/chunks/$part"))
            .put(bytes.toRequestBody("application/octet-stream".toMediaType(), offset, length))
            .header("Authorization", "Bearer ${prefs.token}")
            .build()
        http.newCall(req).execute().use { parse(it) }
    }

    fun complete(uploadId: String, sha256: String): EntryRef {
        val o = parse(request("/uploads/$uploadId/complete", "POST", JSONObject().put("sha256", sha256)))
        val entry = o.optJSONObject("entry") ?: JSONObject()
        return EntryRef(entry.optString("id"), entry.optString("name"))
    }

    fun abort(uploadId: String) {
        runCatching { request("/uploads/$uploadId", "DELETE").close() }
    }

    /** Заливка одной части напрямую в S3 по presigned-ссылке (мимо VPS). */
    fun putPartToS3(presignedUrl: String, bytes: ByteArray, offset: Int, length: Int): String {
        val req = Request.Builder()
            .url(presignedUrl)
            .put(bytes.toRequestBody("application/octet-stream".toMediaType(), offset, length))
            .build()
        // свой клиент без Authorization: ссылка уже подписана, лишние заголовки ломают подпись
        Oks3.client.newCall(req).execute().use { res ->
            if (!res.isSuccessful) throw IOException("S3 ответил ${res.code}")
            return res.header("ETag")?.trim('"') ?: throw IOException("S3 не отдал ETag")
        }
    }

    fun patchFile(entryId: String, body: JSONObject) {
        parse(request("/files/$entryId", "PATCH", body))
    }

    fun patchFolder(folderId: String, body: JSONObject) {
        parse(request("/folders/$folderId", "PATCH", body))
    }

    fun deleteFile(entryId: String) {
        parse(request("/files/$entryId", "DELETE"))
    }

    fun moveFile(entryId: String, folderId: String, name: String) {
        parse(request("/files/$entryId", "PATCH", JSONObject().put("folderId", folderId).put("name", name)))
    }

    fun downloadStream(entryId: String): InputStream {
        val response = request("/files/$entryId/content")
        if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        return response.body!!.byteStream()
    }

    fun ping(): Boolean = runCatching { me(); true }.getOrDefault(false)
}

private object Oks3 {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(300, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
}
