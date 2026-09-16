package ru.cloudly.cloudly_flutter

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.Settings
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Мост к тому, чего в Dart нет вовсе: доступ ко всем файлам, тома памяти, номер файла в
 * файловой системе и события файловой системы.
 *
 * Всё остальное синхронизатор делает сам, обычными средствами Dart: обход дерева, чтение,
 * запись, хэш, сеть. Сюда вынесено ровно то, для чего нужен Android API, — иначе мост
 * разросся бы до второго приложения.
 *
 * ## Потоки: два правила, без которых мост ломается
 *
 * 1. Обработчик `MethodChannel` ([onMethodCall]) вызывается **на главном потоке** — на нём же
 *    живёт Dart-изолят интерфейса. Поэтому дисковой работы в обработчике быть не должно:
 *    обход дерева на 4096 папок и пачка `Os.stat` — это пропущенные кадры и риск ANR.
 *    Тяжёлые вызовы (`inodes`, `watch`, `unwatch`) уходят в [worker], а ответ возвращается
 *    с главного потока (правило 2).
 * 2. `MethodChannel.Result` обязан отвечать **с главного потока**, а `EventSink.success` —
 *    тем более: под капотом это `FlutterJNI.dispatchPlatformMessage`, а тот начинается
 *    с `ensureRunningOnMainThread()` и в любом другом потоке бросает `RuntimeException`.
 *    Поток наблюдателя ([FileObserver.onEvent]) — «любой другой поток», поэтому события
 *    файловой системы не отправляются оттуда напрямую, а планируются в [main] ([notifyChange]).
 *
 * Ниже эти два правила соблюдены везде; при правке моста их нужно держать в голове.
 *
 * ## Контракт канала (MethodChannel `ru.cloudly.sync/native`)
 *
 * Dart-сторона — `flutter/lib/sync/device/native_fs.dart`, там же таблица методов и значений
 * «пусто». Коротко: `hasAllFilesAccess` → `Boolean`; `openAllFilesSettings` → `true`;
 * `storageRoots` → `List<Map<String,String>>{path,name}`; `inode{path}` → `Long` (0 — номера нет);
 * `inodes{paths}` → `List<Long>` той же длины; `deviceLabel` → `String`; `watch{paths}` →
 * `Int` (сколько папок взято, 0 — не за чем или система не дала); `unwatch` → `true`.
 * Неизвестный метод — `notImplemented()`. Ошибка рабочего потока приходит в Dart как
 * `PlatformException`, и Dart-сторона её глушит, подставляя «пустое» значение из той же таблицы.
 */
class SyncBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    /**
     * Активность приложения — нужна ровно для одного: на Android 10 запросить обычные
     * разрешения на хранилище ([openAllFilesSettings]). В фоновом задании активности нет,
     * и мост создаётся без неё — там доступ либо уже выдан, либо проход работает вхолостую.
     */
    private val activity: Activity? = null,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)

    /** Главный поток: только отсюда отвечают каналу и шлют события (см. правила в шапке). */
    private val main = Handler(Looper.getMainLooper())

    /**
     * Рабочий поток для дисковых вызовов. Один на мост и один на процесс: два обхода дерева
     * одновременно всё равно упрутся в диск, а порядок вызовов (`watch` после `unwatch`)
     * так сохраняется сам собой — наблюдатель живёт в этом же потоке и не требует блокировок.
     */
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "cloudly-sync-bridge").apply { isDaemon = true }
    }

    /** Наблюдатель один на все папки: у системы ограничено и число наблюдателей, и записей. */
    private var observer: FileObserver? = null

    /** Поток событий Dart. Ставится и снимается на главном потоке, там же и читается. */
    private var sink: EventChannel.EventSink? = null

    /** Всплеск событий уже запланирован: второй раз ту же пару «сообщение + задержка» не ставим. */
    private val changePending = AtomicBoolean(false)

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
                if (path == null) {
                    result.success(0L)
                } else {
                    onWorker(result) { inodeOf(path) }
                }
            }

            // …и пачкой: на обходе десятков тысяч файлов один вызов моста вместо каждого —
            // это разница между «проход идёт» и «проход ползёт». Порядок ответа повторяет
            // порядок запроса, ноль означает «не удалось узнать». Пара тысяч `Os.stat` —
            // работа для рабочего потока, а не для главного
            "inodes" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                onWorker(result) { paths.map { inodeOf(it) } }
            }

            "deviceLabel" -> result.success(deviceLabel())

            "watch" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                onWorker(result) { watch(paths) }
            }

            "unwatch" -> onWorker(result) {
                unwatch()
                true
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Выполнить дисковую работу в [worker], а ответ каналу отдать с главного потока.
     *
     * `Result` — не потокобезопасный объект: отвечать из рабочего потока нельзя (правило 2
     * в шапке класса). Ошибка становится `PlatformException`, и Dart-сторона подставляет
     * «пустое» значение: любой сбой моста — это «узнать не удалось», а не сломанный проход.
     */
    private fun <T> onWorker(result: MethodChannel.Result, body: () -> T) {
        worker.execute {
            val answer = runCatching(body)
            main.post {
                answer.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        result.error(
                            "cloudly_sync_bridge",
                            it.message ?: it::class.java.simpleName,
                            null,
                        )
                    },
                )
            }
        }
    }

    // ===== события файловой системы =====

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    /**
     * Подписка снята: наблюдатель тоже снимаем.
     *
     * Раньше здесь только обнулялся [sink], и до 4096 записей inotify оставались висеть до
     * следующего `watch`/`unwatch` или до смерти процесса: события продолжали идти в никуда,
     * а системный ресурс был занят. Теперь контракт такой: **пока подписка на события жива,
     * наблюдение может стоять; как только она снята — наблюдение снимается**. Вызывающему
     * в Dart (`NativeFs`, а через него `MirrorWatcher`) не нужно помнить об этом самому,
     * но и забывать про `unwatch` при смене выбора папок не стоит: он снимает наблюдение
     * явно, не закрывая поток.
     */
    override fun onCancel(arguments: Any?) {
        this.sink = null
        worker.execute { unwatch() }
    }

    /**
     * Событие файловой системы — повод попросить проход.
     *
     * Вызывается **потоком наблюдателя**, поэтому в канал отсюда писать нельзя (правило 2
     * в шапке класса): вместо этого ставится задача в [main]. Всплеск склеивается по времени
     * ([CHANGE_DEBOUNCE_MS]): сохранение фото или распаковка архива дают десятки событий
     * подряд, а проходу достаточно одного — сверка смотрит состояние, а не события, и своя
     * выдержка у неё всё равно есть (`MirrorWatcher.debounceMs`).
     */
    private fun notifyChange() {
        if (!changePending.compareAndSet(false, true)) return
        main.postDelayed(
            {
                changePending.set(false)
                sink?.success("change")
            },
            CHANGE_DEBOUNCE_MS,
        )
    }

    /**
     * Наблюдение за деревом выбранных папок. `FileObserver` не рекурсивный, поэтому папки
     * обходятся в ширину до предела: остальное достаётся периодическому проходу.
     *
     * Зовётся только из [worker] — вместе с [unwatch] это даёт «наблюдение всегда ровно одно»
     * без блокировок.
     *
     * @return сколько папок взято под наблюдение; 0 — наблюдать не за чем или не вышло
     */
    private fun watch(roots: List<String>): Int {
        // повторный вызов заменяет наблюдение, а не добавляет второе: выбор папок меняется
        // целиком, и старый наблюдатель иначе остался бы висеть до закрытия движка
        unwatch()
        if (roots.isEmpty()) return 0
        // в ширину, а не в глубину: важно взять как можно больше папок поближе к выбранным —
        // именно там идёт работа человека, — а не уйти в одну ветку до самого дна
        val queue = ArrayDeque<String>().apply { roots.forEach { addLast(it) } }
        val dirs = ArrayList<File>()
        while (queue.isNotEmpty() && dirs.size < MAX_WATCHED) {
            val dir = File(queue.removeFirst())
            if (!dir.isDirectory) continue
            dirs.add(dir)
            dir.listFiles()?.forEach { child ->
                if (child.isDirectory && !skip(dir.name, child.name)) {
                    queue.addLast(child.absolutePath)
                }
            }
        }
        if (dirs.isEmpty()) return 0
        val created = runCatching {
            object : FileObserver(dirs, MASK) {
                // имя события не нужно: по любому изменению просим проход, а что именно
                // поменялось — сверка увидит сама
                override fun onEvent(event: Int, name: String?) {
                    notifyChange()
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

    /**
     * Служебные каталоги не наблюдаем: `.thumbnails` и `Android/data` меняются постоянно.
     *
     * Правило то же, что в Dart (`MediaRules.skipDir`), и это важно: `data` и `obb` пропускаются
     * только внутри `Android`. Если пропускать их в любом месте дерева (как было раньше),
     * пользовательская папка `Documents/data` не берётся под наблюдение и «мгновенный» режим
     * для неё перестаёт быть мгновенным — изменения ловит только периодический проход.
     */
    private fun skip(parentName: String, name: String): Boolean =
        name.startsWith(".") ||
            name == "LOST.DIR" ||
            (parentName == "Android" && (name == "data" || name == "obb"))

    // ===== доступ к файлам =====

    /** Полный доступ к файлам — то, ради чего приложение ставится APK-ом, а не из Play. */
    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            hasLegacyStorageAccess()
        }

    /**
     * Доступ на Android 10.
     *
     * `MANAGE_EXTERNAL_STORAGE` там не действует вовсе (разрешение появилось в Android 11),
     * а читать и писать в пользовательские папки можно только с обычными разрешениями на
     * хранилище. Возвращать здесь `true` безусловно — значит обещать интерфейсу доступ,
     * которого нет: дерево и разделы выглядели бы пустыми без единой подсказки.
     *
     * Требуются оба разрешения: синхронизация не только читает дерево, но и кладёт в него
     * скачанное (`SyncApi.downloadToFile` пишет прямо в выбранную папку).
     */
    private fun hasLegacyStorageAccess(): Boolean =
        hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE) &&
            hasPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)

    private fun hasPermission(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Выдать доступ. На Android 11 и выше это системный экран «доступ ко всем файлам»;
     * на Android 10 такого экрана нет — там запрашиваются обычные разрешения, а если
     * активности рядом нет (фоновый изолят), открывается экран настроек приложения.
     *
     * Ответ на запрос разрешений сюда не приходит: приложение узнаёт о нём, вернувшись
     * на экран, — `SyncController.recheckAccess` спрашивает `hasAllFilesAccess` заново.
     */
    private fun openAllFilesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startSystemScreen(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
            return
        }
        val host = activity
        if (host != null) {
            runCatching { host.requestPermissions(LEGACY_STORAGE_PERMISSIONS, LEGACY_STORAGE_REQUEST) }
            return
        }
        startSystemScreen(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
    }

    private fun startSystemScreen(action: String) {
        runCatching {
            context.startActivity(
                Intent(action)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * Корни выбора: внутренняя память и карты памяти. `StorageManager.directory` появился
     * в Android 11, поэтому на десятом адресуется только внутренняя.
     *
     * `LinkedHashMap` — чтобы внутренняя память всегда шла первой: это тот корень, который
     * выбирают чаще всего, и он же единственный на старых версиях. Имя тома берётся у системы
     * (`getDescription`) — оно локализованное, и в дереве человек видит привычное «SD-карта»,
     * а не `1234-5678`.
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

    /** `st_ino` файла; 0 — файла нет или его номер узнать нельзя (см. комментарий у `"inode"`). */
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

        /**
         * Создание, удаление, переименование и конец записи файла: всё, что меняет содержимое.
         *
         * Плюс `DELETE_SELF` и `MOVE_SELF` — события о самой наблюдаемой папке: без них удаление
         * папки целиком не дало бы ни одного события (записи внутри неё уже не существуют),
         * и сверка узнала бы об этом только следующим периодическим проходом.
         */
        const val MASK = FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or
            FileObserver.CLOSE_WRITE or FileObserver.DELETE_SELF or FileObserver.MOVE_SELF

        /**
         * Предел числа наблюдаемых папок: одна запись на папку, а их у системы конечное число.
         *
         * 4096 — запас с обеих сторон: хватает на дерево обычного телефона (тысячи папок),
         * но не приближается к пределу ядра, за которым `startWatching` начинает отказывать.
         * Что не попало в наблюдение, догонит периодический проход — он смотрит все выбранные
         * папки целиком. Обход этого предела идёт в рабочем потоке ([worker]): на большом
         * дереве это тысячи `listFiles`/`isDirectory`, и на главном потоке они бы морозили
         * интерфейс.
         */
        const val MAX_WATCHED = 4096

        /**
         * Склейка всплеска событий файловой системы.
         *
         * Меньше — и на распаковке архива в канал полетят сотни сообщений в секунду (каждое
         * будит Dart-изолят), больше — и «мгновенный» режим станет заметно не мгновенным.
         * Своя выдержка у прохода всё равно есть (`MirrorWatcher.debounceMs` = 1500 мс),
         * так что здесь важно только не заваливать канал.
         */
        const val CHANGE_DEBOUNCE_MS = 300L

        /** Разрешения на хранилище для Android 10: отдельного «доступа ко всем файлам» там нет. */
        val LEGACY_STORAGE_PERMISSIONS = arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        )

        /** Код запроса разрешений: ответ читается системой, приложению он не нужен. */
        const val LEGACY_STORAGE_REQUEST = 4201
    }
}
