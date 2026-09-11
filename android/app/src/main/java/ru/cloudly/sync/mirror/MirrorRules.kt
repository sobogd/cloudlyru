package ru.cloudly.sync.mirror

import ru.cloudly.sync.device.MediaRules
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Правила двустороннего зеркала: сравнение снимка телефона с тем, что уже выгружено.
 * Чистые функции — ни файловой системы, ни сети: всё приходит аргументами, поэтому правила
 * проверяются юнит-тестами без устройства. Ошибка здесь стоит либо не уехавшего файла,
 * либо удаления чужого содержимого в облаке.
 */
object MirrorRules {

    /** Файл, изменённый только что, ещё пишется: пусть устоится до следующего прохода. */
    const val STABLE_MS = 20_000L


    /**
     * Порог «пропало слишком много». Удаления приходят не только от пользователя: отозванное
     * разрешение, отвалившаяся карта памяти, автоочистка загрузок, чужой файловый менеджер.
     * Без предохранителя любой из этих случаев выкашивает облако за один проход.
     */
    const val MASS_DELETE_MIN = 20
    const val MASS_DELETE_MAX = 500
    const val MASS_DELETE_SHARE = 0.25

    /** Что делать в этом проходе. */
    data class Plan(
        /** Новые и изменившиеся файлы: их надо выгрузить. */
        val uploads: List<LocalFile>,
        /** Переименования: файл тот же (совпал inode), а путь другой. */
        val renames: List<Pair<MirrorRow, LocalFile>>,
        /** Файлы, которых на телефоне больше нет: в облаке их надо убрать в корзину. */
        val deletes: List<MirrorRow>,
        /** Удаления приостановлены предохранителем (сколько именно — `deletes.size + blockedCount`). */
        val blocked: Boolean,
        /** Сколько удалений приостановлено, даже если они и не попали в `deletes`. */
        val blockedCount: Int,
    )

    /**
     * Имя, которое обход не показывает (скрытое или служебное). Для сверки это не «файла нет»,
     * а «правило показа»: такие строки не участвуют в удалениях.
     */
    fun excluded(path: String): Boolean {
        val name = path.substringAfterLast('/')
        return MediaRules.isHidden(name) || MediaRules.isJunk(name)
    }

    /**
     * Файл устоялся: с последнего изменения прошло больше окна стабильности. Дата из будущего
     * (кривые часы устройства, распакованный архив) тоже считается устоявшейся: писать файл
     * «в будущем» нельзя, а вот застрять навсегда из-за такой даты он может.
     */
    fun isStable(mtime: Long, now: Long): Boolean = mtime > now || mtime <= now - STABLE_MS

    /**
     * Удаления допустимы только по полному и читаемому снимку: если папка не открылась или обход
     * упёрся в предел, «файла нет» означает «мы его не увидели», а не «его удалили».
     */
    fun deletionsAllowed(snapshot: LocalSnapshot): Boolean = snapshot.unreadable == 0 && !snapshot.capped

    /**
     * Строки, относящиеся к выбранным сейчас папкам. Обязательный шаг перед сверкой: папку могли
     * снять с выбора, и её файлов в снимке нет — без этого фильтра «файла нет в снимке» означало
     * бы удаление всей папки в облаке, хотя пользователь всего лишь снял галочку.
     */
    fun underRoots(known: Map<String, MirrorRow>, roots: Collection<String>): Map<String, MirrorRow> =
        known.filterKeys { path -> roots.any { path == it || path.startsWith("$it/") } }

    /**
     * Слишком много пропало за один проход?
     *
     * @param gone сколько записей облака выглядит удалёнными
     * @param known сколько всего записей знает зеркало
     */
    fun massDelete(gone: Int, known: Int): Boolean {
        if (gone >= MASS_DELETE_MAX) return true
        if (gone < MASS_DELETE_MIN) return false
        return known > 0 && gone.toDouble() / known > MASS_DELETE_SHARE
    }

    /**
     * План прохода.
     *
     * @param local снимок выбранных папок телефона
     * @param known что уже выгружено (ключ — путь файла на телефоне)
     * @param now текущее время: по нему видно, устоялся ли файл
     * @param deletionsAllowed можно ли в этом проходе удалять в облаке (см. `deletionsAllowed`)
     * @param confirmed пользователь подтвердил удаление, приостановленное предохранителем
     */
    fun plan(
        local: List<LocalFile>,
        known: Map<String, MirrorRow>,
        now: Long,
        deletionsAllowed: Boolean,
        confirmed: Boolean = false,
    ): Plan {
        val byPath = local.associateBy { it.path }
        val uploads = ArrayList<LocalFile>()
        val renames = ArrayList<Pair<MirrorRow, LocalFile>>()
        val renamedFrom = HashSet<String>()

        // Записи, чьих файлов на телефоне нет: либо удалены, либо переехали (ниже это видно по inode).
        // Служебные и скрытые имена сюда не попадают: обход их не показывает — значит «файла нет»
        // означает «правило показа», а не «удалён». Иначе облачный `.nomedia` уезжал бы в корзину
        // на следующем же проходе после того, как его скачали.
        val lost = known.values.filter { it.path !in byPath && !excluded(it.path) }
        val byInode = lost.filter { it.inode > 0L }.associateBy { it.inode }

        for (file in local) {
            val row = known[file.path]
            if (row != null) {
                // известный путь: выгружаем заново только если содержимое изменилось
                val changed = row.size != file.size || row.mtime != file.mtime
                if (changed && isStable(file.mtime, now)) uploads += file
                continue
            }
            // пути в известных нет: либо файл новый, либо он переименован.
            // Переименование признаём только при совпадении inode, размера И даты: одного inode
            // мало — ядро отдаёт освободившийся номер новому файлу, и тогда «удалил A, создал B»
            // выглядело бы переименованием, а облачная запись A перезаписывалась бы содержимым B.
            val moved = if (file.inode > 0L) byInode[file.inode] else null
            if (moved != null && moved.path !in renamedFrom && moved.size == file.size && moved.mtime == file.mtime) {
                renamedFrom += moved.path
                renames += moved to file
                continue
            }
            if (isStable(file.mtime, now)) uploads += file
        }

        val gone = lost.filter { it.path !in renamedFrom }
        val blocked = gone.isNotEmpty() &&
            (!deletionsAllowed || (massDelete(gone.size, known.size) && !confirmed))
        return Plan(
            uploads = uploads,
            renames = renames,
            deletes = if (blocked) emptyList() else gone,
            blocked = blocked,
            blockedCount = gone.size,
        )
    }

    /**
     * Имя конфликтной копии: содержимое обеих сторон сохраняется, никто не затирается молча.
     * Так же поступает Google Drive — «конфликтующая копия» вместо тихой потери одной из версий.
     */
    fun conflictName(name: String, at: Long): String {
        val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date(at))
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        return "$base (конфликт $stamp)$ext"
    }

    /** Имя временного файла при скачивании: сканирование такие имена не подхватывает. */
    fun tempName(name: String): String = ".$name.cloudly-tmp"
}
