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
 * `FileObserver` не рекурсивный и занимает один inotify-наблюдатель на папку, а их у процесса
 * ограниченное число: дерево обходится в ширину до предела, остальное достаётся периодике.
 */
class MirrorWatcher(private val onChange: () -> Unit) {

    private val observers = HashMap<String, FileObserver>()

    /** Поставить наблюдение за деревом (в ширину, до предела). Повторный вызов пересобирает набор. */
    fun watch(roots: Collection<String>) {
        stop()
        val queue = ArrayDeque<String>()
        roots.forEach { queue.addLast(it) }
        while (queue.isNotEmpty() && observers.size < MAX_WATCHED) {
            val path = queue.removeFirst()
            if (observers.containsKey(path)) continue
            val dir = File(path)
            if (!dir.isDirectory) continue
            // имя события не нужно: по любому изменению просто просим проход,
            // а что именно поменялось — сверка увидит сама
            val observer = runCatching {
                object : FileObserver(dir, MASK) {
                    override fun onEvent(event: Int, name: String?) {
                        onChange()
                    }
                }.also { it.startWatching() }
            }.getOrNull()
            if (observer == null) {
                Log.w(TAG, "наблюдение за $path не поставилось")
                continue
            }
            observers[path] = observer
            dir.listFiles()?.forEach { child ->
                if (child.isDirectory && !MediaRules.skipDir(child.name, dir.name)) {
                    queue.addLast(child.absolutePath)
                }
            }
        }
        Log.i(TAG, "наблюдение за папками: ${observers.size}")
    }

    fun stop() {
        observers.values.forEach { runCatching { it.stopWatching() } }
        observers.clear()
    }

    private companion object {
        const val TAG = "cloudly-mirror"

        /** Что считается изменением: создание, удаление, переименование и конец записи файла. */
        const val MASK = FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or
            FileObserver.CLOSE_WRITE or FileObserver.DELETE_SELF or FileObserver.MOVE_SELF

        /** Предел числа наблюдателей: дерево на телефоне легко даёт тысячи папок. */
        const val MAX_WATCHED = 256
    }
}
