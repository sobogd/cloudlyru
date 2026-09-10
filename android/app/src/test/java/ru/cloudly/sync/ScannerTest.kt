package ru.cloudly.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import ru.cloudly.sync.sync.Scanner
import java.io.File

/** Обход папки: именно здесь терялись «вложенные файлы и папки», если что-то не так. */
class ScannerTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** Сканер пропускает файлы, изменённые только что (могут ещё дописываться) — в тестах это не нужно. */
    private fun aged(file: File): File {
        file.setLastModified(System.currentTimeMillis() - 3_600_000)
        return file
    }

    @Test
    fun `находит файлы во вложенных папках`() {
        val root = tmp.newFolder("root")
        aged(File(root, "a.txt").apply { writeText("one") })
        val sub = File(root, "sub/inner").apply { mkdirs() }
        aged(File(sub, "b.jpg").apply { writeText("two") })
        aged(File(root, "sub/c.bin").apply { writeText("three") })

        val result = Scanner.scan(root.absolutePath, includeSubfolders = true)
        val paths = result.files.map { it.relPath }.sorted()
        assertEquals(listOf("a.txt", "sub/c.bin", "sub/inner/b.jpg"), paths)
    }

    @Test
    fun `без подпапок видит только верхний уровень`() {
        val root = tmp.newFolder("root2")
        aged(File(root, "top.txt").apply { writeText("one") })
        File(root, "sub").mkdirs()
        aged(File(root, "sub/deep.txt").apply { writeText("two") })

        val result = Scanner.scan(root.absolutePath, includeSubfolders = false)
        assertEquals(listOf("top.txt"), result.files.map { it.relPath })
    }

    @Test
    fun `служебные и скрытые каталоги пропускаются`() {
        val root = tmp.newFolder("root3")
        aged(File(root, "keep.txt").apply { writeText("one") })
        aged(File(root, ".hidden/secret.txt").also { it.parentFile!!.mkdirs() }.apply { writeText("x") })
        aged(File(root, "Android/data/app/cache.bin").also { it.parentFile!!.mkdirs() }.apply { writeText("x") })
        aged(File(root, ".cloudly-part").apply { writeText("x") })

        val paths = Scanner.scan(root.absolutePath, true).files.map { it.relPath }
        assertEquals(listOf("keep.txt"), paths)
    }

    @Test
    fun `только что изменённый файл помечается пропущенным, а не исчезнувшим`() {
        val root = tmp.newFolder("root4")
        val fresh = File(root, "fresh.txt").apply { writeText("x") }
        fresh.setLastModified(System.currentTimeMillis())

        val result = Scanner.scan(root.absolutePath, true)
        assertTrue(result.files.isEmpty())
        assertTrue(result.skipped.contains("fresh.txt"))
    }

    @Test
    fun `файл с датой из будущего синхронизируется, а не пропускается навсегда`() {
        val root = tmp.newFolder("root5")
        val future = File(root, "future.txt").apply { writeText("x") }
        future.setLastModified(System.currentTimeMillis() + 3_600_000)

        val result = Scanner.scan(root.absolutePath, true)
        assertEquals(listOf("future.txt"), result.files.map { it.relPath })
        assertFalse(result.skipped.contains("future.txt"))
    }

    @Test
    fun `нечитаемая папка не превращается в пустую`() {
        val root = tmp.newFolder("root6")
        aged(File(root, "file.txt").apply { writeText("x") })
        // путь, которого нет: сканер должен честно сказать, что ничего не видит
        val result = Scanner.scan(File(root, "нет-такой").absolutePath, true)
        assertTrue(result.files.isEmpty())
    }
}
