package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.queue.Candidate
import ru.cloudly.sync.queue.Known
import ru.cloudly.sync.queue.QueuePlanner
import ru.cloudly.sync.queue.UploadedKey

/**
 * Наполнение очереди: ошибка здесь означает либо потерянный файл (не поставили в очередь),
 * либо бесконечную перезаливку одного и того же. Обе крайности дорогие, поэтому правила
 * проверяются без устройства.
 */
class QueuePlannerTest {

    private fun candidate(
        path: String = "/s/Download/doc.pdf",
        relDir: String = "Download",
        size: Long = 100,
        mtime: Long = 1000,
        section: Section = Section.FILES,
        target: String = "phone",
    ) = Candidate(path, relDir, path.substringAfterLast('/'), size, mtime, section, target)

    @Test
    fun newFileGoesToQueue() {
        val planned = QueuePlanner.plan(listOf(candidate()), uploaded = emptyMap())
        assertEquals(1, planned.size)
    }

    @Test
    fun unchangedAndAlreadyUploadedFileIsSkipped() {
        val item = candidate()
        val planned = QueuePlanner.plan(
            candidates = listOf(item),
            uploaded = mapOf(UploadedKey(item.path, item.target) to Known(item.size, item.mtime)),
        )
        assertTrue(planned.isEmpty())
    }

    @Test
    fun changedFileGoesToQueueAgain() {
        val item = candidate(size = 200, mtime = 2000)
        val planned = QueuePlanner.plan(
            candidates = listOf(item),
            uploaded = mapOf(UploadedKey(item.path, item.target) to Known(100, 1000)),
        )
        // правка на телефоне должна доехать до облака, иначе перезаписи не будет никогда
        assertEquals(1, planned.size)
    }

    @Test
    fun sameFileForTwoTargetsIsQueuedTwice() {
        val planned = QueuePlanner.plan(
            candidates = listOf(candidate(target = "phone"), candidate(target = "photos", relDir = "")),
            uploaded = emptyMap(),
        )
        // папка прикреплена и к «Файлам», и к «Фото» — файл нужен в обоих местах
        assertEquals(2, planned.size)
        assertEquals(setOf("phone", "photos"), planned.map { it.target }.toSet())
    }

    @Test
    fun uploadedToOtherTargetIsStillQueued() {
        val item = candidate(target = "photos", relDir = "")
        val planned = QueuePlanner.plan(
            candidates = listOf(item),
            uploaded = mapOf(UploadedKey(item.path, "phone") to Known(item.size, item.mtime)),
        )
        // «уже в облаке» в разделе «Файлы» не значит, что файл есть в медиатеке
        assertEquals(1, planned.size)
    }

    @Test
    fun sameFileTwiceInOnePassIsQueuedOnce() {
        val planned = QueuePlanner.plan(
            candidates = listOf(candidate(), candidate()),
            uploaded = emptyMap(),
        )
        assertEquals(1, planned.size)
    }
}
