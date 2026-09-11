package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.mirror.LocalDir
import ru.cloudly.sync.mirror.LocalFile
import ru.cloudly.sync.mirror.LocalSnapshot
import ru.cloudly.sync.mirror.MirrorRow
import ru.cloudly.sync.mirror.MirrorRules

/**
 * Сверка зеркала: ошибка здесь означает либо потерянный файл, либо удаление чужого содержимого
 * в облаке. Обе крайности дорогие, поэтому правила проверяются без устройства.
 */
class MirrorRulesTest {

    private val now = 1_000_000L

    private fun local(
        path: String = "/s/Download/doc.pdf",
        size: Long = 100,
        mtime: Long = now - 60_000,
        inode: Long = 42,
    ) = LocalFile(
        path = path,
        name = path.substringAfterLast('/'),
        dir = path.substringBeforeLast('/'),
        relDir = "Download",
        root = "/s/Download",
        size = size,
        mtime = mtime,
        inode = inode,
    )

    private fun row(
        path: String = "/s/Download/doc.pdf",
        entryId: String = "entry-1",
        size: Long = 100,
        mtime: Long = now - 60_000,
        inode: Long = 42,
        sha256: String? = "aa",
    ) = MirrorRow(path, "cloud-dir", entryId, inode, size, mtime, sha256)

    private fun snapshot(files: List<LocalFile>, unreadable: Int = 0, capped: Boolean = false) =
        LocalSnapshot(files, listOf(LocalDir("/s/Download", "Download")), unreadable, capped)

    @Test
    fun newFileIsUploaded() {
        val plan = MirrorRules.plan(listOf(local()), emptyMap(), now, deletionsAllowed = true)
        assertEquals(listOf("/s/Download/doc.pdf"), plan.uploads.map { it.path })
        assertTrue(plan.renames.isEmpty())
        assertTrue(plan.deletes.isEmpty())
    }

    @Test
    fun fileStillBeingWrittenWaits() {
        // файл изменился только что: его ещё пишут, выгружать нельзя
        val fresh = local(mtime = now - 1_000)
        val plan = MirrorRules.plan(listOf(fresh), emptyMap(), now, deletionsAllowed = true)
        assertTrue(plan.uploads.isEmpty())
    }

    @Test
    fun unchangedFileIsNotUploadedAgain() {
        val plan = MirrorRules.plan(listOf(local()), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertTrue(plan.uploads.isEmpty())
        assertTrue(plan.deletes.isEmpty())
    }

    @Test
    fun changedContentIsUploadedAgain() {
        val edited = local(size = 200)
        val plan = MirrorRules.plan(listOf(edited), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertEquals(listOf("/s/Download/doc.pdf"), plan.uploads.map { it.path })
        assertTrue(plan.deletes.isEmpty())
    }

    @Test
    fun renameIsNotDeleteAndUpload() {
        // тот же inode, другой путь: байты передавать не нужно, содержимое в облаке уже есть
        val moved = local(path = "/s/Download/отчёт.pdf", inode = 42)
        val plan = MirrorRules.plan(listOf(moved), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertEquals(1, plan.renames.size)
        assertEquals("/s/Download/doc.pdf", plan.renames.first().first.path)
        assertEquals("/s/Download/отчёт.pdf", plan.renames.first().second.path)
        assertTrue(plan.uploads.isEmpty())
        assertTrue(plan.deletes.isEmpty())
    }

    @Test
    fun renameWithEditIsNotRename() {
        // переименование и правка разом: размер разошёлся, значит это не переименование,
        // а «пропал старый + появился новый» — так облачное содержимое не перезаписывается
        val moved = local(path = "/s/Download/отчёт.pdf", size = 200, inode = 42)
        val plan = MirrorRules.plan(listOf(moved), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertTrue(plan.renames.isEmpty())
        assertEquals(listOf("/s/Download/отчёт.pdf"), plan.uploads.map { it.path })
        assertEquals(listOf("entry-1"), plan.deletes.map { it.entryId })
    }

    @Test
    fun reusedInodeWithOtherDateIsNotRename() {
        // ядро отдало освободившийся inode новому файлу: размер совпал, дата нет — не переименование
        val fresh = local(path = "/s/Download/new.pdf", size = 100, mtime = now - 5_000, inode = 42)
        val plan = MirrorRules.plan(listOf(fresh), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertTrue(plan.renames.isEmpty())
        assertEquals(listOf("entry-1"), plan.deletes.map { it.entryId })
    }

    @Test
    fun hiddenAndJunkRowsAreNeverDeletedInCloud() {
        // обход такие имена не показывает: «файла нет в снимке» — это правило показа, а не удаление
        val known = mapOf(
            "/s/Download/.nomedia" to row(path = "/s/Download/.nomedia", entryId = "hidden"),
            "/s/Download/movie.mp4.part" to row(path = "/s/Download/movie.mp4.part", entryId = "junk"),
            "/s/Download/doc.pdf" to row(path = "/s/Download/doc.pdf", entryId = "real"),
        )
        val plan = MirrorRules.plan(listOf(local()), known, now, deletionsAllowed = true)
        assertTrue(plan.deletes.none { it.entryId == "hidden" || it.entryId == "junk" })
        assertTrue(plan.deletes.isEmpty())
    }

    @Test
    fun futureMtimeIsStable() {
        // файл из архива с датой в будущем не должен застрять навсегда
        assertTrue(MirrorRules.isStable(now + 5_000, now))
    }

    @Test
    fun missingFileIsDeletedInCloud() {
        val plan = MirrorRules.plan(emptyList(), mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = true)
        assertEquals(listOf("entry-1"), plan.deletes.map { it.entryId })
        assertFalse(plan.blocked)
    }

    @Test
    fun unknownInodeFallsBackToDeleteAndUpload() {
        // inode узнать не удалось: переименование неотличимо от «удалили и создали»
        val fresh = local(path = "/s/Download/отчёт.pdf", inode = 0)
        val plan = MirrorRules.plan(listOf(fresh), mapOf("/s/Download/doc.pdf" to row(inode = 0)), now, deletionsAllowed = true)
        assertTrue(plan.renames.isEmpty())
        assertEquals(listOf("/s/Download/отчёт.pdf"), plan.uploads.map { it.path })
        assertEquals(listOf("entry-1"), plan.deletes.map { it.entryId })
    }

    @Test
    fun unreadableFolderBlocksDeletions() {
        // папка не читается — «файла нет» означает «мы его не увидели», а не «его удалили»
        val snap = snapshot(emptyList(), unreadable = 3)
        assertFalse(MirrorRules.deletionsAllowed(snap))
        val plan = MirrorRules.plan(snap.files, mapOf("/s/Download/doc.pdf" to row()), now, deletionsAllowed = false)
        assertTrue(plan.deletes.isEmpty())
        assertTrue(plan.blocked)
        assertEquals(1, plan.blockedCount)
    }

    @Test
    fun incompleteScanBlocksDeletions() {
        assertFalse(MirrorRules.deletionsAllowed(snapshot(emptyList(), capped = true)))
    }

    @Test
    fun massDeleteNeedsConfirmation() {
        // пропало 30 из 100 — четверть и больше порога: удалять нельзя без подтверждения
        assertTrue(MirrorRules.massDelete(30, 100))
        val known = (1..100).associate { "/s/Download/f$it" to row(path = "/s/Download/f$it") }
        val plan = MirrorRules.plan(emptyList(), known, now, deletionsAllowed = true)
        assertTrue(plan.deletes.isEmpty())
        assertTrue(plan.blocked)
        assertEquals(100, plan.blockedCount)
    }

    @Test
    fun smallShareOfLargeLibraryIsFine() {
        // 25 файлов из 1000 — обычное дело (чистка загрузок), предохранитель не мешает
        assertFalse(MirrorRules.massDelete(25, 1000))
    }

    @Test
    fun hugeDeletionIsBlockedEvenInSmallLibrary() {
        assertTrue(MirrorRules.massDelete(MirrorRules.MASS_DELETE_MAX, 100_000))
    }

    @Test
    fun confirmedDeletionGoesThrough() {
        val known = (1..100).associate { "/s/Download/f$it" to row(path = "/s/Download/f$it", entryId = "e$it") }
        val plan = MirrorRules.plan(emptyList(), known, now, deletionsAllowed = true, confirmed = true)
        assertEquals(100, plan.deletes.size)
        assertFalse(plan.blocked)
    }

    @Test
    fun emptyLibraryDoesNotTripTheGuard() {
        assertFalse(MirrorRules.massDelete(0, 0))
        val plan = MirrorRules.plan(emptyList(), emptyMap(), now, deletionsAllowed = true)
        assertTrue(plan.deletes.isEmpty())
        assertFalse(plan.blocked)
    }

    @Test
    fun conflictCopyKeepsBothVersions() {
        val name = MirrorRules.conflictName("отчёт.pdf", 1_700_000_000_000L)
        assertTrue(name.startsWith("отчёт (конфликт "))
        assertTrue(name.endsWith(".pdf"))
        // файл без расширения тоже получает осмысленное имя
        assertTrue(MirrorRules.conflictName("README", 1_700_000_000_000L).startsWith("README (конфликт "))
    }

    @Test
    fun rowsOfUnselectedFolderAreLeftAlone() {
        // папку сняли с выбора: её файлов в снимке нет, и удалять их в облаке нельзя —
        // пользователь всего лишь снял галочку, а не удалил данные
        val known = mapOf(
            "/s/Download/doc.pdf" to row(path = "/s/Download/doc.pdf", entryId = "in-mirror"),
            "/s/DCIM/old.jpg" to row(path = "/s/DCIM/old.jpg", entryId = "not-selected"),
        )
        val inRoots = MirrorRules.underRoots(known, listOf("/s/Download"))
        assertEquals(setOf("/s/Download/doc.pdf"), inRoots.keys)
        val plan = MirrorRules.plan(emptyList(), inRoots, now, deletionsAllowed = true)
        assertEquals(listOf("in-mirror"), plan.deletes.map { it.entryId })
    }

    @Test
    fun stabilityWindow() {
        assertTrue(MirrorRules.isStable(now - MirrorRules.STABLE_MS, now))
        assertFalse(MirrorRules.isStable(now - MirrorRules.STABLE_MS + 1, now))
    }
}
