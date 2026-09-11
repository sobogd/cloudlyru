package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.data.SelectionRules

/**
 * Выбор папок: отметка вбирает поддерево, снятие отметки внутри выбранной папки раскрывает
 * предка. Ошибка здесь означает либо потерянный выбор, либо папку, которую невозможно снять.
 */
class SelectionRulesTest {

    /** Заглушка файловой системы: у каждой папки ровно те подпапки, что перечислены. */
    private val childDirs: (String) -> List<String> = { path ->
        when (path) {
            "/s/DCIM" -> listOf("/s/DCIM/Camera", "/s/DCIM/Screenshots")
            "/s/DCIM/Camera" -> listOf("/s/DCIM/Camera/raw")
            "/s/Download" -> listOf("/s/Download/Telegram")
            else -> emptyList()
        }
    }

    @Test
    fun chosenFolderCoversItsSubtree() {
        val chosen = SelectionRules.choose(setOf("/s/DCIM/Camera"), "/s/DCIM")
        // подпапка уходит из набора: она и так покрыта, а два ответа на один вопрос — это баг
        assertEquals(setOf("/s/DCIM"), chosen)
        assertTrue(SelectionRules.isCovered(chosen, "/s/DCIM/Camera/raw"))
        assertFalse(SelectionRules.hasInside(chosen, "/s/DCIM"))
    }

    @Test
    fun partlyChosenFolderIsNotCovered() {
        val chosen = setOf("/s/DCIM/Camera")
        assertFalse(SelectionRules.isCovered(chosen, "/s/DCIM"))
        assertTrue(SelectionRules.hasInside(chosen, "/s/DCIM"))
        assertTrue(SelectionRules.isCovered(chosen, "/s/DCIM/Camera"))
    }

    @Test
    fun unchoosingInsideChosenFolderSplitsIt() {
        val chosen = SelectionRules.unchoose(setOf("/s/DCIM"), "/s/DCIM/Camera", childDirs)
        // «DCIM» раскрылся, камера выпала, скриншоты остались выбранными
        assertEquals(setOf("/s/DCIM/Screenshots"), chosen)
        assertFalse(SelectionRules.isCovered(chosen, "/s/DCIM/Camera"))
        assertTrue(SelectionRules.isCovered(chosen, "/s/DCIM/Screenshots"))
    }

    @Test
    fun unchoosingDeepFolderKeepsSiblings() {
        val chosen = SelectionRules.unchoose(setOf("/s/DCIM"), "/s/DCIM/Camera/raw", childDirs)
        assertEquals(setOf("/s/DCIM/Screenshots"), chosen)
    }

    @Test
    fun unchoosingItselfJustRemovesIt() {
        assertEquals(emptySet<String>(), SelectionRules.unchoose(setOf("/s/DCIM/Camera"), "/s/DCIM/Camera", childDirs))
    }

    @Test
    fun unchoosingUnreadableFolderDoesNotLoop() {
        // подпапки неизвестны — раскрывать нечем, но и зацикливаться нельзя
        val chosen = SelectionRules.unchoose(setOf("/s/DCIM"), "/s/DCIM/Camera", { emptyList() })
        assertEquals(emptySet<String>(), chosen)
    }

    @Test
    fun scanRootsDropsFoldersInsideOtherChosenFolders() {
        val roots = SelectionRules.scanRoots(setOf("/s/DCIM/Camera", "/s/DCIM", "/s/Download"))
        assertEquals(listOf("/s/DCIM", "/s/Download"), roots)
    }
}
