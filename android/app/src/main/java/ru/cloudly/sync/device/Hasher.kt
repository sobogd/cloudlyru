package ru.cloudly.sync.device

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/** SHA-256 файла. Нужен проверке скачанной сборки приложения (и понадобится выгрузке). */
object Hasher {
    private const val BUF = 1 shl 20

    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(BUF)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                md.update(buffer, 0, read)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
