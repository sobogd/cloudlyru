package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.data.Db
import ru.cloudly.sync.net.ApiException
import ru.cloudly.sync.sync.Decisions

/**
 * Проверки правил синхронизации. Логика вынесена в чистые функции именно ради этого: ошибка
 * здесь стоит пользовательских файлов, а не «неудобного интерфейса». Модель односторонняя,
 * поэтому проверяем только то, что решает: когда молчать, как не перезаписать чужое имя
 * и как узнать переименование.
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
    fun `свободное имя получает суффикс`() {
        assertEquals("IMG_0001 (2).jpg", Decisions.freeName("IMG_0001.jpg", emptySet()))
        assertEquals("IMG_0001 (3).jpg", Decisions.freeName("IMG_0001.jpg", setOf("IMG_0001 (2).jpg")))
        assertEquals("readme (2)", Decisions.freeName("readme", emptySet()))
        // имя с точкой в начале — расширением не считается, суффикс идёт в конец
        assertEquals(".hidden (2)", Decisions.freeName(".hidden", emptySet()))
    }

    @Test
    fun `имя из внешнего источника теряет путь и управляющие символы`() {
        assertEquals("photo.jpg", Decisions.cleanFileName("/etc/passwd/photo.jpg"))
        assertEquals("app.db", Decisions.cleanFileName("../../databases/app.db"))
        assertEquals("photo.jpg", Decisions.cleanFileName("C:\\Users\\me\\photo.jpg"))
        assertEquals("_", Decisions.cleanFileName("\u0000"))
        assertEquals("", Decisions.cleanFileName("..."))
        assertEquals("", Decisions.cleanFileName("  "))
        assertEquals(160, Decisions.cleanFileName("x".repeat(500)).length)
    }

    @Test
    fun `уже выгруженным считается только совпадение содержимого и размера`() {
        assertTrue(Decisions.isAlreadyUploaded("sha1", 100, "sha1", 100))
        assertFalse(Decisions.isAlreadyUploaded("sha1", 100, "sha1", 101))
        assertFalse(Decisions.isAlreadyUploaded("sha1", 100, "sha2", 100))
        assertFalse(Decisions.isAlreadyUploaded(null, 100, "sha1", 100))
    }

    @Test
    fun `через сервер повторяем только сетевые сбои и 5xx`() {
        // не доехали байты: нет сети, не разрешается имя хранилища, отказ S3
        assertTrue(Decisions.shouldRetryViaRelay(java.io.IOException("nbg1.your-objectstorage.com: timeout")))
        assertTrue(Decisions.shouldRetryViaRelay(ApiException(500, "", "внутренняя ошибка", null)))
        assertTrue(Decisions.shouldRetryViaRelay(ApiException(429, "", "слишком часто", null)))
        // сервер ответил внятно: повтор через сервер не поможет, а режим спрячет причину
        assertFalse(Decisions.shouldRetryViaRelay(ApiException(404, "upload_session_lost", "нет сессии", null)))
        assertFalse(Decisions.shouldRetryViaRelay(ApiException(401, "", "нет доступа", null)))
        assertFalse(Decisions.shouldRetryViaRelay(ApiException(409, "conflict", "имя занято", null)))
        assertFalse(Decisions.shouldRetryViaRelay(IllegalStateException("что-то своё")))
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
        // неоднозначно — перенос не выдумываем, файл просто уедет в облако ещё раз
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
        assertEquals("a/one.jpg", pairs[0].second)
    }

    private fun job(wifiOnly: Boolean) = Db.Job(
        id = 1,
        sourceDir = "/storage/emulated/0/DCIM",
        targetFolderId = "folder",
        targetPath = "Фото",
        zone = "PHOTOS",
        includeSubfolders = true,
        wifiOnly = wifiOnly,
        enabled = true,
    )
}
