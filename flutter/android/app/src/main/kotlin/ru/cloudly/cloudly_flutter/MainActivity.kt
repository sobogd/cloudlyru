package ru.cloudly.cloudly_flutter

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // На экране ли приложение: по этому признаку периодическое задание решает, делать ли
        // проход из фона (см. AppPresence). Ставится один раз на процесс.
        AppPresence.register(application)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Мост к Android API, которого нет в Dart: доступ ко всем файлам, тома памяти,
        // номер файла в файловой системе и события файловой системы (см. SyncBridge).
        // Активность передаётся ради Android 10: там «доступ ко всем файлам» выдаётся обычными
        // разрешениями, а запросить их можно только из активности (в фоне её нет — мост
        // создаётся и без неё, см. SyncJobService)
        SyncBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            activity = this,
        )
        // Заведение и снятие периодического прохода: само задание живёт в системе, а не
        // в движке — к моменту его запуска движка приложения может уже не быть
        BackgroundBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}
