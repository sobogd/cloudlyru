package ru.cloudly.sync.mirror

import android.os.FileObserver
import android.util.Log
import ru.cloudly.sync.device.MediaRules
import java.io.File

/**
 * Наблюдение за выбранными папками: событие файловой системы — повод запустить проход почти
 * сразу, а не ждать пятнадцати минут.
 *
 * Это только ускоритель. События теряются при перезапуске процесса, после перезагрузки и в Doze,
 * поэтому истина — периодический проход, а наблюдатель лишь сокращает задержку.
 *
 * Один наблюдатель на все папки сразу. `FileObserver` не рекурсивный, и раньше на каждую папку
 * заводился свой экземпляр: у системы ограничено число не только наблюдаемых папок, но и самих
 * наблюдателей на процесс, поэтому часть дерева молча оставалась без присмотра.
 */
class MirrorWatcher(private val onChange: () -> Unit) {

    private var observer: FileObserver? = null

    /** За какими папками наблюдаем сейчас: набор не менялся — не трогаем наблюдателя зря. */
    private var watched = emptySet<String>()

    /** Поставить наблюдение за деревом (в ширину, до предела). Повторный вызов пересобирает набор. */
    fun watch(roots: Collection<String>) {
        val wanted = roots.toSet()
        if (wanted == watched && observer != null) return
        stop()
        watched = wanted
        if (wanted.isEmpty()) return

        val queue = ArrayDeque<String>()
        roots.forEach { queue.addLast(it) }
        val dirs = ArrayList<File>()
        while (queue.isNotEmpty() && dirs.size < MAX_WATCHED) {
            val dir = File(queue.removeFirst())
            if (!dir.isDirectory) continue
            dirs.add(dir)
            dir.listFiles()?.forEach { child ->
                if (child.isDirectory && !MediaRules.skipDir(child.name, dir.name)) {
                    queue.addLast(child.absolutePath)
                }
            }
        }
        if (dirs.isEmpty()) return

        // имя события не нужно: по любому изменению просто просим проход,
        // а что именно поменялось — сверка увидит сама
        val created = runCatching {
            object : FileObserver(dirs, MASK) {
                override fun onEvent(event: Int, name: String?) {
                    onChange()
                }
            }.also { it.startWatching() }
        }.getOrNull()
        if (created == null) {
            Log.w(TAG, "наблюдение за папками не поставилось (папок: ${dirs.size})")
            return
        }
        observer = created
        Log.i(TAG, "наблюдение за папками: ${dirs.size}")
    }

    fun stop() {
        observer?.let { runCatching { it.stopWatching() } }
        observer = null
        watched = emptySet()
    }

    private companion object {
        const val TAG = "cloudly-mirror"

        /** Что считается изменением: создание, удаление, переименование и конец записи файла. */
        const val MASK = FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or
            FileObserver.CLOSE_WRITE or FileObserver.DELETE_SELF or FileObserver.MOVE_SELF

        /**
         * Предел числа наблюдаемых папок: один наблюдатель держит по одной «записи» на папку,
         * а их у системы тоже конечное число. Остальное достаётся периодике.
         */
        const val MAX_WATCHED = 4096
    }
}
