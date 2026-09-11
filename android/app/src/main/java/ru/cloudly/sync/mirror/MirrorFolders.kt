package ru.cloudly.sync.mirror

import android.util.Log
import ru.cloudly.sync.net.Api
import ru.cloudly.sync.net.ApiException

/**
 * Папки зеркала: соответствие путей на телефоне и папок в облаке.
 *
 * Путь в облаке повторяет путь на телефоне внутри корня зеркала: выбрали `Download` — в облаке
 * появится `<Имя устройства> - Файлы/Download`, вместе со всей структурой внутри. Папки заводятся
 * идемпотентным `ensure-path`, поэтому проход можно повторять сколько угодно раз.
 *
 * Соответствие кэшируется и в памяти, и в базе: правка из журнала знает только `folderId`,
 * и без обратного перевода её некуда положить на телефоне.
 */
class MirrorFolders(private val api: Api, private val store: MirrorStore) {

    /** Ключ — путь на телефоне: две папки с одинаковым именем на разных томах дают разные записи. */
    private val byLocalPath = HashMap<String, String>()

    /** Папка для относительного пути (`Download/Telegram`) внутри корня зеркала. */
    fun ensure(relDir: String, localPath: String, mirrorRootId: String): String {
        byLocalPath[localPath]?.let {
            store.registerDir(it, localPath)
            return it
        }
        val id = ensurePath(relDir, mirrorRootId)
        byLocalPath[localPath] = id
        store.registerDir(id, localPath)
        return id
    }

    /**
     * Сервер ограничивает частоту (429). Первый проход по дереву заводит десятки папок, и
     * упереться в лимит на середине — значит уронить проход на ровном месте.
     */
    private fun ensurePath(path: String, parentId: String): String {
        var waitMs = 2_000L
        for (attempt in 0 until 4) {
            try {
                return api.ensurePath(path, parentId)
            } catch (e: ApiException) {
                if (e.status != 429 || attempt == 3) throw e
                Log.w(TAG, "папка $path: сервер просит подождать — пауза ${waitMs / 1000} с")
                Thread.sleep(waitMs)
                waitMs *= 2
            }
        }
        throw IllegalStateException("папку $path сервер так и не принял")
    }

    private companion object {
        const val TAG = "cloudly-mirror"
    }
}
