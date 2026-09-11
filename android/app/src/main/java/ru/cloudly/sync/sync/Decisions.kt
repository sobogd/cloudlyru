package ru.cloudly.sync.sync

import ru.cloudly.sync.data.Db

/**
 * Решения, вынесенные в чистые функции: их проверяют юнит-тесты без Android.
 * Модель односторонняя (только выгрузка), поэтому здесь нет ни вытеснения,
 * ни конфликтов — приложение ничего не удаляет и ничего не перезаписывает.
 */
object Decisions {

    /** Ждать ли Wi-Fi для задачи. */
    fun shouldWaitForWifi(job: Db.Job, unmetered: Boolean): Boolean = job.wifiOnly && !unmetered

    /** Файл, изменённый только что, может ещё дописываться — берём его следующим проходом. */
    fun isTooFresh(ageMs: Long, thresholdMs: Long): Boolean = ageMs in 0 until thresholdMs

    /**
     * Свободное имя с суффиксом: `IMG_0001 (2).jpg`. Нужно, когда в целевой папке облака
     * уже лежит другой файл с таким именем — перезаписывать чужое нельзя, добавляем рядом.
     */
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

    /**
     * Пары «исчезло на телефоне / появилось на телефоне» с одинаковым содержимым:
     * это переименование, а не новый файл. Отправляем серверу move, чтобы в облаке
     * не появлялась вторая запись с тем же содержимым.
     *
     * Сначала ищем пару в том же каталоге (обычное переименование), потом — единственное
     * совпадение по всему дереву (перенос в другую папку). Неоднозначные не связываем.
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

    /**
     * Имя файла из внешнего источника — система «Поделиться», файловый браузер, чужое приложение.
     * Оставляем только базовое имя: без разделителей, «..» и управляющих символов и с ограничением
     * длины. Без этого имя «../../databases/app.db» записало бы или удалило файл вне каталога кэша.
     */
    fun cleanFileName(raw: String): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\').trim().trimStart('.')
        val cleaned = base.replace(Regex("[\\u0000-\\u001f]"), "_")
        return if (cleaned.length > 160) cleaned.take(160) else cleaned
    }

    /** Можно ли считать файл уже выгруженным: совпало содержимое и размер. */
    fun isAlreadyUploaded(cachedSha: String?, cachedSize: Long, sha256: String, size: Long): Boolean =
        cachedSha == sha256 && cachedSize == size
}
