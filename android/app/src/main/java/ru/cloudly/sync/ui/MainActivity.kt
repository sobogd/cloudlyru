package ru.cloudly.sync.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import ru.cloudly.sync.App
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.queue.QueueRefresher

/** Что показывает приложение: два раздела файлов, очередь загрузки и настройки. */
private enum class Tab(val label: String) {
    FILES("Файлы"),
    PHOTOS("Фото"),
    QUEUE("Очередь"),
    SETTINGS("Настройки"),
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) { Root() }
            }
        }
    }
}

@Composable
private fun Root() {
    val context = LocalContext.current
    val app = remember { App.of(context) }

    var tab by remember { mutableStateOf(Tab.FILES) }
    // выбор папок — отдельный экран, а не диалог: дерево телефона в окне поверх не показать
    var folderSection by remember { mutableStateOf<Section?>(null) }
    var waiting by remember { mutableIntStateOf(0) }

    // Счётчик очереди и фоновое наполнение: очередь должна собираться сама, а запуск остаётся
    // ручным. Наполняем при старте и после каждого изменения выбора папок.
    LaunchedEffect(folderSection) {
        if (folderSection != null) return@LaunchedEffect
        // выбор папок мог измениться: пересобираем наблюдение за папками зеркала
        app.refreshMirrorWatch()
        withContext(Dispatchers.IO) { runCatching { QueueRefresher.refresh(context) } }
        waiting = withContext(Dispatchers.IO) { app.queueStore.waitingCount() }
    }
    LaunchedEffect(Unit) {
        while (true) {
            waiting = withContext(Dispatchers.IO) { app.queueStore.waitingCount() }
            delay(3000)
        }
    }

    folderSection?.let { section ->
        FolderTreeScreen(section = section, onBack = { folderSection = null })
        return
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == Tab.FILES,
                    onClick = { tab = Tab.FILES },
                    icon = { Icon(Icons.Filled.Folder, contentDescription = null) },
                    label = { Text(Tab.FILES.label) },
                )
                NavigationBarItem(
                    selected = tab == Tab.PHOTOS,
                    onClick = { tab = Tab.PHOTOS },
                    icon = { Icon(Icons.Filled.PhotoLibrary, contentDescription = null) },
                    label = { Text(Tab.PHOTOS.label) },
                )
                NavigationBarItem(
                    selected = tab == Tab.QUEUE,
                    onClick = { tab = Tab.QUEUE },
                    icon = {
                        BadgedBox(
                            badge = {
                                if (waiting > 0) Badge { Text(waiting.toString()) }
                            },
                        ) { Icon(Icons.Filled.CloudUpload, contentDescription = null) }
                    },
                    label = { Text(Tab.QUEUE.label) },
                )
                NavigationBarItem(
                    selected = tab == Tab.SETTINGS,
                    onClick = { tab = Tab.SETTINGS },
                    icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                    label = { Text(Tab.SETTINGS.label) },
                )
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                Tab.FILES -> FileListScreen(
                    section = Section.FILES,
                    onOpenFolders = { folderSection = Section.FILES },
                )
                Tab.PHOTOS -> FileListScreen(
                    section = Section.PHOTOS,
                    onOpenFolders = { folderSection = Section.PHOTOS },
                )
                Tab.QUEUE -> QueueScreen()
                Tab.SETTINGS -> SettingsScreen(onOpenFolders = { folderSection = it })
            }
        }
    }
}
