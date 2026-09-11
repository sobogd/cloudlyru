package ru.cloudly.sync.sync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import ru.cloudly.sync.net.Api
import java.io.File

/**
 * Файлы, сохранённые в облако из другого приложения (через файловый браузер). Если выгрузка
 * не удалась, файл нельзя ни терять, ни оставлять в кэше: `cacheDir` система чистит первой.
 * Поэтому кладём его во внешний каталог приложения рядом с описанием, куда грузить, и догружаем
 * следующим проходом.
 */
object PendingUploads {

    data class Item(val file: File, val meta: File, val folderId: String, val name: String)

    /** Куда складывать: внешний каталог приложения — переживает чистку кэша. */
    private fun dir(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "pending").apply { mkdirs() }

    private fun metaOf(file: File) = File(file.parentFile, "${file.name}.json")

    /**
     * Взять файл на хранение. Описание (папка-получатель и имя) лежит рядом отдельным файлом:
     * без него догрузка не знает, куда его класть.
     */
    fun keep(context: Context, file: File, folderId: String, name: String) {
        val target = File(dir(context), file.name)
        if (!file.renameTo(target)) {
            runCatching { file.copyTo(target, overwrite = true) }
        }
        if (!file.exists() || file.absolutePath != target.absolutePath) file.delete()
        metaOf(target).writeText(JSONObject().put("folderId", folderId).put("name", name).toString())
        Log.w(TAG, "файл ждёт догрузки: ${target.absolutePath}")
    }

    fun list(context: Context): List<Item> {
        val files = dir(context).listFiles()?.filter { it.isFile && !it.name.endsWith(".json") } ?: return emptyList()
        return files.mapNotNull { file ->
            val meta = metaOf(file)
            val json = runCatching { JSONObject(meta.readText()) }.getOrNull()
            val folderId = json?.optString("folderId").orEmpty()
            if (folderId.isBlank()) {
                // описание потерялось — файл всё равно не выбрасываем, но и грузить некуда
                Log.w(TAG, "у ${file.name} нет описания, куда грузить")
                return@mapNotNull null
            }
            Item(file, meta, folderId, json?.optString("name").orEmpty().ifBlank { file.name })
        }
    }

    fun done(item: Item) {
        item.file.delete()
        item.meta.delete()
    }

    /**
     * Одна выгрузка: сначала прямо в хранилище, при неудаче — через сервер.
     * Имя подбираем свободное: занятое чужое содержимым не перезаписываем.
     */
    fun upload(api: Api, folderId: String, file: File, name: String): Uploader.Result {
        val sha = Hasher.sha256(file)
        val taken = runCatching { api.children(folderId).entries.map { it.name }.toHashSet() }
            .getOrDefault(emptySet())
        val freeName = Decisions.freeName(name, taken)
        val local = LocalFile(freeName, file.absolutePath, freeName, file.length(), file.lastModified())
        val attempt: (Boolean) -> Uploader.Result = { viaRelay ->
            Uploader(api).upload(
                folderId = folderId,
                file = local,
                sha256 = sha,
                replace = false,
                expectedSha256 = null,
                uploadIdFromQueue = null,
                onSession = {},
                onProgress = { _, _ -> },
                forceRelay = viaRelay,
            )
        }
        return runCatching { attempt(false) }.getOrElse { first ->
            // прямое подключение к хранилищу могло не сработать (DNS, VPN, блокировщик);
            // на внятную ошибку сервера повтор через него ничего не изменит
            if (!Decisions.shouldRetryViaRelay(first)) throw first
            Log.w(TAG, "прямая выгрузка не удалась (${first.message}) — пробую через сервер")
            attempt(true)
        }
    }

    /**
     * Догрузка всего, что осталось с прошлых раз. Ошибку не глотаем: файл остаётся лежать
     * и попробует уехать на следующем проходе.
     */
    fun retryAll(context: Context, api: Api): Pair<Int, Int> {
        var uploaded = 0
        var failed = 0
        for (item in list(context)) {
            try {
                val result = upload(api, item.folderId, item.file, item.name)
                done(item)
                uploaded += 1
                Log.i(TAG, "догружено из ожидающих: ${result.name}")
            } catch (e: Exception) {
                failed += 1
                Log.w(TAG, "догрузка ${item.name} не прошла: ${e.message}")
            }
        }
        return uploaded to failed
    }

    private const val TAG = "cloudly-sync"
}
