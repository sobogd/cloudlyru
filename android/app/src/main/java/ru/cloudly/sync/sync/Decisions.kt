package ru.cloudly.sync.sync

import ru.cloudly.sync.data.Db

/**
 * Решения синхронизации, вынесенные в чистые функции: их проверяют юнит-тесты без Android,
 * а движок остаётся тонким. Здесь нет ни сети, ни файловой системы — только правила.
 */
object Decisions {

    /** Ждать ли Wi-Fi для задачи. */
    fun shouldWaitForWifi(job: Db.Job, unmetered: Boolean): Boolean = job.wifiOnly && !unmetered

    /**
     * Нужно ли догонять файл из облака: зеркало (папка без вытеснения) или закрепление.
     * Вытесненное обратно не тянем — иначе смысл вытеснения теряется.
     */
    fun shouldDownload(
        state: String,
        entryKeepOffline: Boolean,
        itemKeepOffline: Boolean,
        mirror: Boolean,
        jobPinned: Boolean,
    ): Boolean {
        if (!mirror && !jobPinned && !entryKeepOffline && !itemKeepOffline) return false
        // Закрепление перекрывает вытеснение: у закреплённой папки вытесненное возвращается,
        // у обычной папки со сроком хранения — нет, иначе смысл вытеснения теряется
        if (state == Db.STATE_EVICTED && !entryKeepOffline && !itemKeepOffline && !jobPinned) return false
        return true
    }

    /** Можно ли вытеснять файл: только подтверждённое сервером содержимое и не закреплённое. */
    fun canEvict(
        state: String,
        keepOffline: Boolean,
        folderPinned: Boolean,
        hasRemoteSha: Boolean,
        uploadedAt: Long?,
        now: Long,
        keepDays: Int,
        graceMs: Long,
    ): Boolean {
        if (state != Db.STATE_SYNCED) return false
        if (keepOffline || folderPinned) return false
        if (!hasRemoteSha || uploadedAt == null) return false
        return now - uploadedAt >= keepDays.coerceAtLeast(0).toLong() * 24 * 60 * 60 * 1000 + graceMs
    }

    /**
     * Предохранитель от массового удаления: больше 20 файлов или больше 10 % базы —
     * это почти всегда сбой чтения, а не воля пользователя.
     */
    fun looksLikeMassDeletion(toDelete: Int, base: Int): Boolean =
        toDelete > 20 || (base > 0 && toDelete * 100 / base > 10)

    /** Свободное имя с суффиксом: `IMG_0001 (2).jpg`. */
    fun freeName(name: String, taken: Set<String>): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 2 until 1000) {
            val candidate = "$base ($i)$ext"
            if (candidate !in taken) return candidate
        }
        return "$base (${System.currentTimeMillis()})$ext"
    }

    /** Имя конфликтной копии: «файл (конфликт 2026-09-10 21-57 Pixel-8).jpg». */
    fun conflictName(name: String, stamp: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) {
            "${name.substring(0, dot)} (конфликт $stamp)${name.substring(dot)}"
        } else {
            "$name (конфликт $stamp)"
        }
    }

    /** Считать ли файл «свежим» (ещё пишется прямо сейчас). Дату из будущего свежей не считаем. */
    fun isTooFresh(ageMs: Long, thresholdMs: Long): Boolean = ageMs in 0 until thresholdMs

    /**
     * Пары «исчезло/появилось» по содержимому: сначала внутри каталога (переименование),
     * потом единственное совпадение по всему дереву (перенос в другую папку).
     */
    fun matchMoves(
        vanished: List<Pair<String, String>>, // relPath → sha256
        appeared: List<Pair<String, String>>, // relPath → sha256
    ): List<Pair<String, String>> {
        val usedOld = HashSet<String>()
        val result = ArrayList<Pair<String, String>>()
        for (pass in 0..1) {
            for ((newPath, sha) in appeared) {
                if (result.any { it.second == newPath }) continue
                val dir = newPath.substringBeforeLast('/', "")
                val candidates = vanished.filter { (oldPath, oldSha) ->
                    oldPath !in usedOld && oldSha == sha &&
                        (pass == 1 || oldPath.substringBeforeLast('/', "") == dir)
                }
                if (pass == 1 && candidates.size != 1) continue
                val pick = candidates.firstOrNull() ?: continue
                usedOld.add(pick.first)
                result.add(pick.first to newPath)
            }
        }
        return result
    }
}
