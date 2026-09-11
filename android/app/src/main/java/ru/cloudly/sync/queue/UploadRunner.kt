package ru.cloudly.sync.queue

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.data.QueueItem
import ru.cloudly.sync.data.QueueState
import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.device.Hasher
import ru.cloudly.sync.device.MediaRules
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Выгрузка одного файла из очереди. Запускается вручную — кнопкой на строке, — и строго
 * по одному: пока идёт выгрузка, остальные кнопки неактивны.
 *
 * Порядок работы:
 *   1. файл на месте? если исчез — строка помечается ошибкой и ждёт следующего прохода;
 *   2. SHA-256 содержимого (из кэша, если файл не менялся) — им сервер отличает дубли;
 *   3. что уже лежит в облаке по этому имени: тот же хэш → выгрузка не нужна вовсе,
 *      другой → перезапись с проверкой версии (сервер откажет, если там уже чужое);
 *   4. папка получателя: для «Файлов» — структура папок телефона через `ensure-path`,
 *      для «Фото» — медиатека (плоско);
 *   5. заливка частями прямо в S3, при недоступности хранилища — через сервер.
 */
class UploadRunner(
    private val api: Api,
    private val store: QueueStore,
    private val scope: CoroutineScope,
) {

    /** Что происходит прямо сейчас: имя файла и сколько байт ушло. */
    data class Progress(val id: Long, val name: String, val sent: Long, val total: Long) {
        val percent: Int get() = if (total > 0) ((sent * 100) / total).toInt() else 0
    }

    private val busy = AtomicBoolean(false)
    private val folders = ConcurrentHashMap<String, String>()

    private val _progress = MutableStateFlow<Progress?>(null)
    val progress: StateFlow<Progress?> = _progress

    fun isBusy(): Boolean = busy.get()

    /** Кнопка «play» на строке: одна выгрузка за раз, интерфейс при этом не блокируется. */
    fun start(itemId: Long) {
        if (!busy.compareAndSet(false, true)) return
        scope.launch {
            try {
                upload(itemId)
            } catch (e: Exception) {
                Log.w(TAG, "выгрузка $itemId: ${e.message}")
                withContext(Dispatchers.IO) {
                    val item = store.item(itemId)
                    store.markFailed(itemId, e.message ?: "ошибка выгрузки", (item?.attempts ?: 0) + 1)
                }
            } finally {
                _progress.value = null
                busy.set(false)
            }
        }
    }

    private suspend fun upload(itemId: Long) {
        val item = withContext(Dispatchers.IO) { store.item(itemId) } ?: return
        val file = File(item.path)
        if (!file.isFile) {
            withContext(Dispatchers.IO) {
                store.markFailed(itemId, "файла больше нет на телефоне", item.attempts + 1)
            }
            return
        }

        val size = file.length()
        val mtime = file.lastModified()
        withContext(Dispatchers.IO) { store.markRunning(itemId) }
        _progress.value = Progress(itemId, item.name, 0, size)

        val sha = shaOf(item, file, size, mtime)
        val alreadyUploaded = withContext(Dispatchers.IO) {
            store.uploaded()[UploadedKey(item.path, item.target)]
        }
        // что лежит на сервере сейчас: этим же отличается «уже там» от «надо перезаписать»
        val serverSha = alreadyUploaded?.let { uploaded ->
            withContext(Dispatchers.IO) { runCatching { api.entryMeta(uploaded.entryId).sha256 }.getOrNull() }
        }

        when (UploadPlan.decide(sha, serverSha)) {
            UploadPlan.Action.SKIP -> {
                val entryId = alreadyUploaded?.entryId ?: return
                withContext(Dispatchers.IO) {
                    store.markSkipped(itemId, entryId)
                    store.markUploaded(item.path, item.target, entryId, size, mtime)
                }
                Log.i(TAG, "уже в облаке: ${item.name}")
                return
            }

            UploadPlan.Action.CREATE, UploadPlan.Action.REPLACE -> {
                val replace = serverSha != null
                val folderId = resolveFolder(item)
                val result = send(item, folderId, file, sha, replace, serverSha?.takeIf { replace })
                withContext(Dispatchers.IO) {
                    if (result.deduped) store.markSkipped(itemId, result.entryId) else store.markDone(itemId, result.entryId)
                    store.markUploaded(item.path, item.target, result.entryId, size, mtime)
                }
                Log.i(TAG, "выгружено ${item.name}${if (result.deduped) " (содержимое уже было)" else ""}")
            }
        }
    }

    /** Хэш содержимого: из кэша строки, если размер и дата не менялись с прошлой попытки. */
    private suspend fun shaOf(item: QueueItem, file: File, size: Long, mtime: Long): String {
        val cached = item.sha256?.takeIf { it.isNotBlank() && item.size == size && item.mtime == mtime }
        if (cached != null) return cached
        val sha = withContext(Dispatchers.IO) { Hasher.sha256(file) }
        withContext(Dispatchers.IO) { store.setSha(item.id, sha) }
        return sha
    }

    /**
     * Заливка с откатом на сервер: прямое подключение к хранилищу может не работать
     * (DNS, блокировщик, VPN). Внятный ответ сервера (4xx) — не повод менять способ:
     * режим запомнился бы навсегда и спрятал настоящую причину.
     */
    private suspend fun send(
        item: QueueItem,
        folderId: String,
        file: File,
        sha: String,
        replace: Boolean,
        expectedSha256: String?,
    ): Uploader.Result {
        val mime = MediaRules.mimeOf(item.name)
        val progress: (Long, Long) -> Unit = { sent, total -> _progress.value = Progress(item.id, item.name, sent, total) }

        suspend fun attempt(cloudName: String, viaRelay: Boolean): Uploader.Result = withContext(Dispatchers.IO) {
            Uploader(api).upload(
                folderId = folderId,
                file = file,
                cloudName = cloudName,
                mime = mime,
                sha256 = sha,
                replace = replace,
                expectedSha256 = expectedSha256,
                onSession = {},
                onProgress = progress,
                forceRelay = viaRelay,
            )
        }

        val first = runCatching { attempt(item.name, viaRelay = false) }
        if (first.isSuccess) return first.getOrThrow()

        val error = first.exceptionOrNull()!!
        if (error is ApiException && error.code == "conflict") {
            // в облаке чужой файл с таким именем: не затираем, кладём рядом под свободным именем
            val taken = withContext(Dispatchers.IO) {
                runCatching { api.children(folderId).entries.map { it.name }.toHashSet() }.getOrDefault(emptySet())
            }
            val free = UploadPlan.freeName(item.name, taken)
            Log.i(TAG, "имя ${item.name} занято — в облако уйдёт как $free")
            return attempt(free, viaRelay = false)
        }
        if (error !is ApiException && error !is IOException) throw error
        if (error is ApiException && error.status < 500) throw error

        // разовый обрыв не повод считать хранилище мёртвым: вторая попытка стоит секунд
        val second = runCatching { attempt(item.name, viaRelay = false) }
        if (second.isSuccess) return second.getOrThrow()
        Log.w(TAG, "прямая выгрузка не удалась дважды — пробую через сервер")
        return attempt(item.name, viaRelay = true)
    }

    /** Папка получателя: у «Фото» — медиатека (плоско), у «Файлов» — структура папок телефона. */
    private suspend fun resolveFolder(item: QueueItem): String {
        if (item.section != Section.FILES || item.relDir.isBlank()) return item.target
        folders[item.relDir]?.let { return it }
        val id = withContext(Dispatchers.IO) { ensurePath(item.relDir, item.target) }
        folders[item.relDir] = id
        return id
    }

    /**
     * Сервер ограничивает частоту запросов (429). Первый проход по дереву заводит папки
     * десятками, и упереться в лимит на середине — значит уронить выгрузку на ровном месте.
     */
    private fun ensurePath(path: String, parentId: String): String {
        var waitMs = 2_000L
        for (attempt in 0 until 4) {
            try {
                return api.ensurePath(path, parentId)
            } catch (e: ApiException) {
                if (e.status != 429 || attempt == 3) throw e
                Log.w(TAG, "создание папки $path: сервер просит подождать — пауза ${waitMs / 1000} с")
                Thread.sleep(waitMs)
                waitMs *= 2
            }
        }
        throw IllegalStateException("папку $path сервер так и не принял")
    }

    private companion object {
        const val TAG = "cloudly-sync"
    }
}
