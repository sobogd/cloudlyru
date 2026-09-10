package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.sync.Decisions

/**
 * Проверки правил синхронизации. Логика решений вынесена в чистые функции именно ради этого:
 * ошибка здесь стоит пользовательских файлов, а не «неудобного интерфейса».
 */
class DecisionsTest {

    @Test
    fun `wifi-only задача ждёт неметрированную сеть`() {
        val job = job(wifiOnly = true)
        assertTrue(Decisions.shouldWaitForWifi(job, unmetered = false))
        assertFalse(Decisions.shouldWaitForWifi(job, unmetered = true))
        assertFalse(Decisions.shouldWaitForWifi(job(wifiOnly = false), unmetered = false))
    }

    @Test
    fun `вытесненное не скачиваем обратно`() {
        assertFalse(
            Decisions.shouldDownload(Db.STATE_EVICTED, false, false, mirror = true, jobPinned = false),
        )
    }

    @Test
    fun `закреплённое возвращаем даже если вытеснено`() {
        assertTrue(
            Decisions.shouldDownload(Db.STATE_EVICTED, true, false, mirror = false, jobPinned = false),
        )
        assertTrue(
            Decisions.shouldDownload(Db.STATE_EVICTED, false, true, mirror = false, jobPinned = false),
        )
        assertTrue(
            Decisions.shouldDownload(Db.STATE_EVICTED, false, false, mirror = false, jobPinned = true),
        )
    }

    @Test
    fun `в папке со сроком хранения обычный файл не скачиваем`() {
        assertFalse(
            Decisions.shouldDownload(Db.STATE_SYNCED, false, false, mirror = false, jobPinned = false),
        )
    }

    @Test
    fun `вытесняем только выгруженное и не закреплённое`() {
        val now = 1_000_000_000_000L
        val day = 24 * 60 * 60 * 1000L
        val grace = 10 * 60 * 1000L
        // 30 дней назад выгружено, срок 7 дней — можно
        assertTrue(Decisions.canEvict(Db.STATE_SYNCED, false, false, true, now - 30 * day, now, 7, grace))
        // закреплённое — нельзя
        assertFalse(Decisions.canEvict(Db.STATE_SYNCED, true, false, true, now - 30 * day, now, 7, grace))
        // папка закреплена — нельзя
        assertFalse(Decisions.canEvict(Db.STATE_SYNCED, false, true, true, now - 30 * day, now, 7, grace))
        // нет подтверждения сервером — нельзя
        assertFalse(Decisions.canEvict(Db.STATE_SYNCED, false, false, false, now - 30 * day, now, 7, grace))
        // ещё не истёк срок — нельзя
        assertFalse(Decisions.canEvict(Db.STATE_SYNCED, false, false, true, now - day, now, 7, grace))
        // «сразу после выгрузки» — только после грейса
        assertFalse(Decisions.canEvict(Db.STATE_SYNCED, false, false, true, now - 60_000, now, 0, grace))
        assertTrue(Decisions.canEvict(Db.STATE_SYNCED, false, false, true, now - grace - 1, now, 0, grace))
        // не синхронизированное не трогаем
        assertFalse(Decisions.canEvict(Db.STATE_NEW, false, false, true, now - 30 * day, now, 0, grace))
    }

    @Test
    fun `предохранитель ловит массовое удаление`() {
        assertFalse(Decisions.looksLikeMassDeletion(5, 1000))
        assertTrue(Decisions.looksLikeMassDeletion(21, 1000))
        assertTrue(Decisions.looksLikeMassDeletion(11, 100))
        assertFalse(Decisions.looksLikeMassDeletion(10, 100))
        assertFalse(Decisions.looksLikeMassDeletion(0, 0))
    }

    @Test
    fun `свободное имя получает суффикс`() {
        assertEquals("IMG_0001 (2).jpg", Decisions.freeName("IMG_0001.jpg", emptySet()))
        assertEquals("IMG_0001 (3).jpg", Decisions.freeName("IMG_0001.jpg", setOf("IMG_0001 (2).jpg")))
        assertEquals("readme (2)", Decisions.freeName("readme", emptySet()))
    }

    @Test
    fun `конфликтная копия сохраняет расширение и содержит устройство`() {
        assertEquals(
            "фото (конфликт 2026-09-10 21-57 Pixel-8).jpg",
            Decisions.conflictName("фото.jpg", "2026-09-10 21-57 Pixel-8"),
        )
        assertEquals("без-точки (конфликт X)", Decisions.conflictName("без-точки", "X"))
    }

    @Test
    fun `свежим считается только недавнее прошлое`() {
        assertTrue(Decisions.isTooFresh(5_000, 30_000))
        assertFalse(Decisions.isTooFresh(60_000, 30_000))
        // дата из будущего: разница отрицательная — файл синхронизируем, а не пропускаем навсегда
        assertFalse(Decisions.isTooFresh(-3_600_000, 30_000))
    }

    @Test
    fun `переименование в том же каталоге распознаётся как move`() {
        val vanished = listOf("a/photo.jpg" to "sha1")
        val appeared = listOf("a/photo-new.jpg" to "sha1")
        assertEquals(listOf("a/photo.jpg" to "a/photo-new.jpg"), Decisions.matchMoves(vanished, appeared))
    }

    @Test
    fun `перенос в другую папку распознаётся как move если совпадение единственное`() {
        val vanished = listOf("a/photo.jpg" to "sha1")
        val appeared = listOf("b/photo.jpg" to "sha1")
        assertEquals(listOf("a/photo.jpg" to "b/photo.jpg"), Decisions.matchMoves(vanished, appeared))
    }

    @Test
    fun `два одинаковых файла в разных папках не путаются`() {
        val vanished = listOf("a/one.jpg" to "sha1", "b/two.jpg" to "sha1")
        val appeared = listOf("c/one.jpg" to "sha1")
        // неоднозначно — перенос не выдумываем, пусть будет удаление и загрузка
        assertEquals(emptyList<Pair<String, String>>(), Decisions.matchMoves(vanished, appeared))
    }

    @Test
    fun `разное содержимое парами не связывается`() {
        val vanished = listOf("a/photo.jpg" to "sha1")
        val appeared = listOf("a/photo.jpg" to "sha2")
        assertEquals(emptyList<Pair<String, String>>(), Decisions.matchMoves(vanished, appeared))
    }

    @Test
    fun `появившийся файл не связывается дважды`() {
        val vanished = listOf("a/one.jpg" to "sha1")
        val appeared = listOf("a/one.jpg" to "sha1", "a/one-copy.jpg" to "sha1")
        val pairs = Decisions.matchMoves(vanished, appeared)
        assertEquals(1, pairs.size)
        assertTrue(pairs[0].second == "a/one.jpg")
    }

    private fun job(wifiOnly: Boolean) = Db.Job(
        id = 1,
        sourceDir = "/storage/emulated/0/DCIM",
        targetFolderId = "folder",
        targetPath = "Фото",
        zone = "PHOTOS",
        includeSubfolders = true,
        wifiOnly = wifiOnly,
        keepDays = -1,
        enabled = true,
    )
}
