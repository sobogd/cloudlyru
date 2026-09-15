package ru.cloudly.cloudly_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.FileObserver
import android.os.storage.StorageManager
import android.provider.Settings
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Мост к тому, чего в Dart нет вовсе: доступ ко всем файлам, тома памяти, номер файла в
 * файловой системе и события файловой системы.
 *
 * Всё остальное синхронизатор делает сам, обычными средствами Dart: обход дерева, чтение,
 * запись, хэш, сеть. Сюда вынесено ровно то, для чего нужен Android API, — иначе мост
 * разросся бы до второго приложения.
 */
class SyncBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)

    /** Наблюдатель один на все папки: у системы ограничено и число наблюдателей, и записей. */
    private var observer: FileObserver? = null

    private var sink: EventChannel.EventSink? = null

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess())

            // Экран настроек открывается намеренно не отсюда: разрешение выдаётся в системном
            // диалоге, и приложение узнаёт об этом только по возвращении на экран
            "openAllFilesSettings" -> {
                openAllFilesSettings()
                result.success(true)
            }

            "storageRoots" -> result.success(storageRoots())

            // Номер файла: по нему зеркало отличает переименование от «удалил и залил заново».
            // Dart `FileStat` его не отдаёт, а без него перенос папки с видео стоил бы
            // повторной выгрузки всего содержимого
            "inode" -> {
                val path = call.argument<String>("path")
                result.success(if (path == null) 0L else inodeOf(path))
            }

            // …и пачкой: на обходе десятков тысяч файлов один вызов моста вместо каждого —
            // это разница между «проход идёт» и «проход ползёт». Порядок ответа повторяет
            // порядок запроса, ноль означает «не удалось узнать»
            "inodes" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                result.success(paths.map { inodeOf(it) })
            }

            "deviceLabel" -> result.success(deviceLabel())

            "watch" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                result.success(watch(paths))
            }

            "unwatch" -> {
                unwatch()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ===== события файловой системы =====

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    override fun onCancel(arguments: Any?) {
        this.sink = null
    }

    /**
     * Наблюдение за деревом выбранных папок. `FileObserver` не рекурсивный, поэтому папки
     * обходятся в ширину до предела: остальное достаётся периодическому проходу.
     *
     * @return сколько папок взято под наблюдение; 0 — наблюдать не за чем или не вышло
     */
    private fun watch(roots: List<String>): Int {
        unwatch()
        if (roots.isEmpty()) return 0
        val queue = ArrayDeque<String>().apply { roots.forEach { addLast(it) } }
        val dirs = ArrayList<File>()
        while (queue.isNotEmpty() && dirs.size < MAX_WATCHED) {
            val dir = File(queue.removeFirst())
            if (!dir.isDirectory) continue
            dirs.add(dir)
            dir.listFiles()?.forEach { child ->
                if (child.isDirectory && !skip(child.name)) queue.addLast(child.absolutePath)
            }
        }
        if (dirs.isEmpty()) return 0
        val created = runCatching {
            object : FileObserver(dirs, MASK) {
                // имя события не нужно: по любому изменению просим проход, а что именно
                // поменялось — сверка увидит сама
                override fun onEvent(event: Int, name: String?) {
                    sink?.success("change")
                }
            }.also { it.startWatching() }
        }.getOrNull() ?: return 0
        observer = created
        return dirs.size
    }

    private fun unwatch() {
        observer?.let { runCatching { it.stopWatching() } }
        observer = null
    }

    /** Служебные каталоги не наблюдаем: `.thumbnails` и `Android/data` меняются постоянно. */
    private fun skip(name: String): Boolean =
        name.startsWith(".") || name == "LOST.DIR" || name == "data" || name == "obb"

    // ===== доступ к файлам =====

    /** Полный доступ к файлам — то, ради чего приложение ставится APK-ом, а не из Play. */
    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

    private fun openAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * Корни выбора: внутренняя память и карты памяти. `StorageManager.directory` появился
     * в Android 11, поэтому на десятом адресуется только внутренняя.
     */
    private fun storageRoots(): List<Map<String, String>> {
        val out = LinkedHashMap<String, String>()
        val primary = Environment.getExternalStorageDirectory()
        if (primary != null && primary.isDirectory) {
            out[primary.absolutePath] = "Внутренняя память"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.getSystemService(StorageManager::class.java)?.storageVolumes?.forEach { volume ->
                val dir = runCatching { volume.directory }.getOrNull() ?: return@forEach
                if (!dir.isDirectory) return@forEach
                if (out.containsKey(dir.absolutePath)) return@forEach
                val name = runCatching { volume.getDescription(context) }.getOrNull().orEmpty()
                out[dir.absolutePath] = name.ifBlank { dir.name }
            }
        }
        return out.map { (path, name) -> mapOf("path" to path, "name" to name) }
    }

    private fun inodeOf(path: String): Long =
        runCatching { Os.stat(path).st_ino }.getOrDefault(0L)

    /** Как зовётся устройство: этим именем подписывается корень зеркала в облаке. */
    private fun deviceLabel(): String {
        val model = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
        return model.ifBlank { "Android" }
    }

    private companion object {
        const val METHOD_CHANNEL = "ru.cloudly.sync/native"
        const val EVENT_CHANNEL = "ru.cloudly.sync/fileEvents"

        /** Создание, удаление, переименование и конец записи файла: всё, что меняет содержимое. */
        const val MASK = FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or
            FileObserver.CLOSE_WRITE or FileObserver.DELETE_SELF or FileObserver.MOVE_SELF

        /** Предел числа наблюдаемых папок: одна запись на папку, а их у системы конечное число. */
        const val MAX_WATCHED = 4096
    }
}
