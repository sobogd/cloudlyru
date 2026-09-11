package ru.cloudly.sync.queue

import ru.cloudly.sync.data.Section

/**
 * Кандидат в очередь: файл, который надо выгрузить в конкретную облачную папку.
 * Отдельного типа для очереди нет намеренно — запись в базе отличается только состоянием,
 * а правила отбора работают с этим набором полей.
 */
data class Candidate(
    val path: String,
    val relDir: String,
    val name: String,
    val size: Long,
    val mtime: Long,
    val section: Section,
    /** id облачной папки: у «Файлов» — корень зеркала, у «Фото» — медиатека (плоско). */
    val target: String,
)

/** Что уже лежит в облаке: запись и слепок содержимого, по которому её выгружали. */
data class Uploaded(val entryId: String, val size: Long, val mtime: Long)

/** Ключ выгруженного: файл и облачная папка, в которую он лёг. */
data class UploadedKey(val path: String, val target: String)

/**
 * Правила наполнения очереди. Чистые функции: всё, что зависит от диска и базы, приходит
 * аргументами, поэтому логику проверяют юнит-тесты без устройства.
 *
 * Хэш здесь не считается: очередь заполняется по размеру и дате изменения, иначе первый
 * проход по большой библиотеке читал бы все файлы целиком. Хэш нужен только в момент
 * выгрузки — для дедупа и для записи на сервере.
 */
object QueuePlanner {

    /**
     * Кого ставить в очередь: файл, которого нет в этой облачной папке, или тот, что изменился
     * после выгрузки. Сравниваются размер и дата изменения — читать файлы на этапе наполнения
     * очереди не нужно, иначе первый проход по большой библиотеке читал бы её целиком.
     *
     * Один и тот же файл из двух разделов даёт две записи с разными целями: папка может быть
     * прикреплена и к «Файлам», и к «Фото», и тогда он нужен в обоих местах.
     *
     * Уже стоящий в очереди файл повторно в неё не попадает (в базе уникальность по паре
     * «файл + цель»), поэтому проход можно запускать сколько угодно раз.
     */
    fun plan(candidates: List<Candidate>, uploaded: Map<UploadedKey, Uploaded>): List<Candidate> {
        val out = ArrayList<Candidate>(candidates.size)
        val seen = HashSet<UploadedKey>(candidates.size)
        for (candidate in candidates) {
            val key = UploadedKey(candidate.path, candidate.target)
            if (!seen.add(key)) continue
            val there = uploaded[key]
            val alreadyThere = there != null && there.size == candidate.size && there.mtime == candidate.mtime
            if (alreadyThere) continue
            out.add(candidate)
        }
        return out
    }
}
