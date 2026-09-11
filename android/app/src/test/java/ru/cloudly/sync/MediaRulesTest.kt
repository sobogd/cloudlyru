package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.device.MediaRules

/** Разделение на «Фото и видео» и «Файлы» идёт по расширению — эти правила и проверяем. */
class MediaRulesTest {

    @Test
    fun photosGoToPhotosSection() {
        assertTrue(MediaRules.matches(Section.PHOTOS, "IMG_0001.JPG"))
        assertTrue(MediaRules.matches(Section.PHOTOS, "clip.mp4"))
        assertTrue(MediaRules.matches(Section.PHOTOS, "raw.dng"))
        assertTrue(MediaRules.matches(Section.PHOTOS, "IMG_0002.HEIC"))
        assertTrue(MediaRules.matches(Section.PHOTOS, "screencast.mkv"))
    }

    @Test
    fun documentsGoToFilesSection() {
        assertTrue(MediaRules.matches(Section.FILES, "report.pdf"))
        assertTrue(MediaRules.matches(Section.FILES, "archive.zip"))
        assertTrue(MediaRules.matches(Section.FILES, "notes.txt"))
        assertTrue(MediaRules.matches(Section.FILES, "voice.opus"))
        assertTrue(MediaRules.matches(Section.FILES, "backup.tar.gz"))
    }

    @Test
    fun sectionsDoNotOverlap() {
        for (name in listOf("photo.jpg", "video.mp4", "doc.pdf", "noext", "file.zip")) {
            assertFalse(
                "файл $name не должен попадать в оба раздела",
                MediaRules.matches(Section.FILES, name) && MediaRules.matches(Section.PHOTOS, name),
            )
        }
    }

    @Test
    fun fileWithoutExtensionIsAFile() {
        assertFalse(MediaRules.isMedia("noext"))
        assertTrue(MediaRules.matches(Section.FILES, "noext"))
    }

    @Test
    fun hiddenAndHalfWrittenFilesAreNotShown() {
        assertTrue(MediaRules.isHidden(".nomedia"))
        assertTrue(MediaRules.isHidden(".thumbnails"))
        assertTrue(MediaRules.isJunk("video.mp4.part"))
        assertTrue(MediaRules.isJunk("download.crdownload"))
        assertFalse(MediaRules.isJunk("photo.jpg"))
    }

    @Test
    fun serviceDirectoriesAreSkipped() {
        assertTrue(MediaRules.skipDir("data", "Android"))
        assertTrue(MediaRules.skipDir("obb", "Android"))
        assertFalse("медиа приложений показываем", MediaRules.skipDir("media", "Android"))
        assertTrue(MediaRules.skipDir(".thumbnails", "DCIM"))
        assertTrue(MediaRules.skipDir(".trashed", "Pictures"))
        assertFalse(MediaRules.skipDir("Camera", "DCIM"))
        assertFalse("каталог Android на верхнем уровне не пропускаем", MediaRules.skipDir("Android", "0"))
    }

    @Test
    fun sizeIsHumanReadable() {
        assertEquals("512 Б", MediaRules.formatSize(512))
        assertEquals("1.0 КБ", MediaRules.formatSize(1024))
        assertEquals("1.5 МБ", MediaRules.formatSize(1024L * 1024 * 3 / 2))
        assertEquals("2.0 ГБ", MediaRules.formatSize(2L * 1024 * 1024 * 1024))
    }
}
