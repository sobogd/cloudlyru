package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Test
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.queue.QueuePlanner
import ru.cloudly.sync.queue.QueueRow
import ru.cloudly.sync.queue.UploadedKey

/**
 * Уборка очереди: папку отключили от раздела — её файлы должны уйти из очереди, но чужие
 * разделы и уже запущенная выгрузка трогать нельзя. Ошибка здесь либо копит мусор,
 * либо выкашивает очередь целиком.
 */
class QueuePruneTest {

    private fun row(
        id: Long,
        path: String = "/s/Download/a.pdf",
        target: String = "phone",
        section: Section = Section.FILES,
        state: String = "PENDING",
    ) = QueueRow(id, path, target, section.name, state)

    private val download = "/s/Download/a.pdf"

    @Test
    fun fileOfDisabledFolderIsRemoved() {
        val doomed = QueuePlanner.obsolete(
            rows = listOf(row(1, path = "/s/Old/gone.pdf")),
            keep = setOf(UploadedKey(download, "phone")),
            scannedSections = setOf(Section.FILES),
        )
        assertEquals(listOf(1L), doomed)
    }

    @Test
    fun fileThatIsStillACandidateStays() {
        val doomed = QueuePlanner.obsolete(
            rows = listOf(row(1)),
            keep = setOf(UploadedKey(download, "phone")),
            scannedSections = setOf(Section.FILES),
        )
        assertEquals(emptyList<Long>(), doomed)
    }

    @Test
    fun untouchedSectionIsNotPruned() {
        // «Фото» в этом проходе не сканировался: цель неизвестна — трогать его нельзя
        val doomed = QueuePlanner.obsolete(
            rows = listOf(row(1, path = "/s/DCIM/IMG.jpg", target = "photos", section = Section.PHOTOS)),
            keep = emptySet(),
            scannedSections = setOf(Section.FILES),
        )
        assertEquals(emptyList<Long>(), doomed)
    }

    @Test
    fun runningUploadIsNotPruned() {
        val doomed = QueuePlanner.obsolete(
            rows = listOf(row(1, state = "RUNNING")),
            keep = emptySet(),
            scannedSections = setOf(Section.FILES),
        )
        assertEquals(emptyList<Long>(), doomed)
    }

    @Test
    fun doneRowOfDisabledFolderIsRemovedToo() {
        // запись осталась как «выгружен» от прежнего выбора папок: в очереди ей делать нечего
        val doomed = QueuePlanner.obsolete(
            rows = listOf(row(1, path = "/s/Old/done.pdf", state = "DONE")),
            keep = emptySet(),
            scannedSections = setOf(Section.FILES),
        )
        assertEquals(listOf(1L), doomed)
    }
}
