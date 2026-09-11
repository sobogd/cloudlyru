package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Test
import ru.cloudly.sync.queue.UploadPlan

/**
 * Решения выгрузки: ошибка здесь стоит либо не уехавшего файла, либо затёртой чужой версии
 * в облаке. Оба случая дорогие, поэтому правила проверяются без устройства.
 */
class UploadPlanTest {

    private val sha = "a".repeat(64)
    private val other = "b".repeat(64)

    @Test
    fun nothingOnServerMeansCreate() {
        assertEquals(UploadPlan.Action.CREATE, UploadPlan.decide(sha, null))
    }

    @Test
    fun sameContentMeansSkip() {
        // содержимое уже в облаке: байты не передаются вовсе
        assertEquals(UploadPlan.Action.SKIP, UploadPlan.decide(sha, sha))
    }

    @Test
    fun differentContentMeansReplace() {
        assertEquals(UploadPlan.Action.REPLACE, UploadPlan.decide(sha, other))
    }

    @Test
    fun freeNameKeepsNameWhenItIsFree() {
        assertEquals("отчёт.pdf", UploadPlan.freeName("отчёт.pdf", emptySet()))
    }

    @Test
    fun freeNameAddsSuffixBeforeExtension() {
        assertEquals("IMG_0001 (2).jpg", UploadPlan.freeName("IMG_0001.jpg", setOf("IMG_0001.jpg")))
        assertEquals(
            "IMG_0001 (3).jpg",
            UploadPlan.freeName("IMG_0001.jpg", setOf("IMG_0001.jpg", "IMG_0001 (2).jpg")),
        )
    }

    @Test
    fun freeNameHandlesFileWithoutExtension() {
        assertEquals("backup (2)", UploadPlan.freeName("backup", setOf("backup")))
    }
}
