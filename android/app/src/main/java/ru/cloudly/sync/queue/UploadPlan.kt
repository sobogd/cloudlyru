package ru.cloudly.sync.queue

/**
 * Решения выгрузки, вынесенные в чистые функции: их проверяют юнит-тесты без устройства.
 * Ошибка здесь стоит либо не уехавшего файла, либо затирания чужой версии в облаке.
 */
object UploadPlan {

    /** Что делать с файлом, если знать, что уже лежит на сервере. */
    enum class Action { CREATE, REPLACE, SKIP }

    /**
     * @param serverSha содержимое, которое лежит в облаке по этому имени (null — ничего нет)
     */
    fun decide(localSha: String, serverSha: String?): Action = when {
        serverSha == null -> Action.CREATE
        // содержимое уже там: байты не передаём вовсе, сервер сообщит это и сам
        serverSha == localSha -> Action.SKIP
        else -> Action.REPLACE
    }

    /**
     * Свободное имя с суффиксом: `отчёт (2).pdf`. Нужно, когда в облачной папке уже лежит
     * **чужой** файл с таким именем — перезаписывать не своё нельзя, добавляем рядом.
     */
    fun freeName(name: String, taken: Set<String>): String {
        if (name !in taken) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 2 until 1000) {
            val candidate = "$base ($i)$ext"
            if (candidate !in taken) return candidate
        }
        return "$base (${System.currentTimeMillis()})$ext"
    }
}
