package ru.cloudly.sync.sync

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/** Хэш содержимого файла: он и есть идентичность в облаке (ключ объекта = sha256). */
object Hasher {
    private const val BUF = 1 shl 20

    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buf = ByteArray(BUF)
            while (true) {
                val read = input.read(buf)
                if (read <= 0) break
                md.update(buf, 0, read)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

/** Файл, найденный на телефоне: путь относительно корня задачи, размер и mtime. */
data class LocalFile(val relPath: String, val path: String, val name: String, val size: Long, val mtime: Long)

/**
 * Обход папки задачи. Работает с обычными путями (MANAGE_EXTERNAL_STORAGE), поэтому
 * не требует диалогов выбора папок и перечисления через DocumentsContract.
 */
object Scanner {
    /** Служебные каталоги и мусор: в облако не отправляем. */
    val SKIP_DIRS = setOf("Android/data", "Android/obb", ".thumbnails", ".trashed", "LOST.DIR", ".cloudly-trash")
    private val SKIP_SUFFIX = listOf(".tmp", ".part", ".crdownload")
    /** Файл, изменённый только что, может ещё дописываться — берём его следующим проходом. */
    private const val TOO_FRESH_MS = 30_000L

    fun scan(rootDir: String, includeSubfolders: Boolean, now: Long = System.currentTimeMillis()): List<LocalFile> {
        val root = File(rootDir)
        if (!root.isDirectory) return emptyList()
        val out = ArrayList<LocalFile>()
        walk(root, root, includeSubfolders, now, out)
        return out
    }

    private fun walk(root: File, dir: File, recurse: Boolean, now: Long, out: MutableList<LocalFile>) {
        val children = dir.listFiles() ?: return
        for (child in children) {
            val rel = child.absolutePath.removePrefix(root.absolutePath).trimStart('/')
            if (child.isDirectory) {
                if (!recurse) continue
                if (SKIP_DIRS.any { rel == it || rel.startsWith("$it/") }) continue
                if (child.name.startsWith(".")) continue
                walk(root, child, recurse = true, now = now, out = out)
                continue
            }
            if (!child.isFile) continue
            if (child.name.startsWith(".")) continue
            if (SKIP_SUFFIX.any { child.name.endsWith(it, ignoreCase = true) }) continue
            if (now - child.lastModified() < TOO_FRESH_MS) continue
            out.add(LocalFile(rel, child.absolutePath, child.name, child.length(), child.lastModified()))
        }
    }

    /** Mime по расширению: сервер сам решает, конвертировать или нет, но тип нужен для записи. */
    fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "heic" -> "image/heic"
            "heif" -> "image/heif"
            "avif" -> "image/avif"
            "dng", "raw", "cr2", "nef", "arw" -> "image/x-raw"
            "tif", "tiff" -> "image/tiff"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "avi" -> "video/avi"
            "3gp" -> "video/3gpp"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            "txt" -> "text/plain"
            "json" -> "application/json"
            else -> "application/octet-stream"
        }
    }
}
