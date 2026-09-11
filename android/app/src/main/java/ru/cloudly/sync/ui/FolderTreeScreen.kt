package ru.cloudly.sync.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TriStateCheckbox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ru.cloudly.sync.data.Selection
import ru.cloudly.sync.data.Section
import ru.cloudly.sync.data.SelectionRules
import ru.cloudly.sync.device.DeviceFiles
import ru.cloudly.sync.device.FolderNode
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Выбор папок раздела: всё дерево телефона раскрыто, отметка ставится галочкой.
 * Экран отдельный, а не диалог: дерево большое, в окне поверх интерфейса его не показать.
 *
 * Отмеченная папка вбирает всё поддерево. Если снять галочку внутри отмеченной папки,
 * выбранный предок «раскрывается» — иначе снять отметку с части дерева было бы нечем.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderTreeScreen(section: Section, onBack: () -> Unit) {
    val context = LocalContext.current
    val device = remember { DeviceFiles(context) }
    val selection = remember { Selection(context) }
    val scope = rememberCoroutineScope()
    val roots = remember { device.roots() }

    val all = remember { mutableStateListOf<FolderNode>() }
    val visible = remember { mutableStateListOf<FolderNode>() }
    var chosen by remember { mutableStateOf(selection.paths(section)) }
    var collapsed by remember { mutableStateOf(emptySet<String>()) }
    var walking by remember { mutableStateOf(true) }
    val queue = remember { ConcurrentLinkedQueue<FolderNode>() }
    val finished = remember { AtomicBoolean(false) }

    // Обход идёт в фоне и отдаёт узлы порциями: дерево телефона целиком ждать нельзя,
    // а писать в состояние Compose можно только из главного потока.
    LaunchedEffect(Unit) {
        val effect = this
        launch(Dispatchers.IO) {
            device.walkTree(roots, emit = { queue.add(it) }, isCancelled = { !effect.isActive })
            finished.set(true)
        }
        while (!finished.get()) {
            delay(60)
            drain(queue, all, visible, collapsed)
        }
        drain(queue, all, visible, collapsed)
        walking = false
    }

    fun toggleCollapse(node: FolderNode) {
        collapsed = if (node.path in collapsed) collapsed - node.path else collapsed + node.path
        visible.clear()
        visible.addAll(all.filter { n -> collapsed.none { n.path.startsWith("$it/") } })
    }

    fun toggleCheck(node: FolderNode) {
        val covered = SelectionRules.isCovered(chosen, node.path)
        scope.launch {
            chosen = if (covered) {
                // раскрытие выбранного предка читает диск, поэтому вне главного потока
                withContext(Dispatchers.IO) { selection.unchoose(section, node.path) { device.subdirs(it) } }
            } else {
                selection.choose(section, node.path)
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            if (section == Section.PHOTOS) "Папки для фото и видео" else "Папки для файлов",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            if (chosen.isEmpty()) "ничего не выбрано" else "выбрано папок: ${chosen.size}",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Назад")
                    }
                },
                actions = {
                    if (chosen.isNotEmpty()) {
                        TextButton(onClick = { chosen = selection.clear(section) }) { Text("Снять всё") }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            Text(
                "Отмеченная папка включает все вложенные. Содержимое этих папок появится в разделе " +
                    if (section == Section.PHOTOS) "«Фото и видео»." else "«Файлы».",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            )
            if (walking) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(
                    "ищу папки… найдено ${all.size}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                )
            }
            if (!walking && visible.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Папок не найдено", fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Скорее всего у приложения нет доступа ко всем файлам.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = { openAllFilesSettings(context) }) { Text("Открыть настройки") }
                }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(visible, key = { it.path }) { node ->
                    FolderRow(
                        node = node,
                        chosen = chosen,
                        isCollapsed = node.path in collapsed,
                        onToggleCollapse = { toggleCollapse(node) },
                        onToggleCheck = { toggleCheck(node) },
                    )
                }
            }
        }
    }
}

@Composable
private fun FolderRow(
    node: FolderNode,
    chosen: Set<String>,
    isCollapsed: Boolean,
    onToggleCollapse: () -> Unit,
    onToggleCheck: () -> Unit,
) {
    val covered = SelectionRules.isCovered(chosen, node.path)
    val partly = !covered && SelectionRules.hasInside(chosen, node.path)
    val state = when {
        covered -> ToggleableState.On
        partly -> ToggleableState.Indeterminate
        else -> ToggleableState.Off
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onToggleCheck() }
            .padding(start = (node.depth * 14).dp, end = 12.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (node.hasChildren) {
            IconButton(onClick = onToggleCollapse) {
                Icon(
                    imageVector = if (isCollapsed) Icons.Filled.ChevronRight else Icons.Filled.ExpandMore,
                    contentDescription = if (isCollapsed) "Развернуть" else "Свернуть",
                )
            }
        } else {
            Spacer(Modifier.width(48.dp))
        }
        TriStateCheckbox(state = state, onClick = onToggleCheck)
        Icon(
            Icons.Filled.Folder,
            contentDescription = null,
            tint = if (covered) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(node.name, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                node.path,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Перенос узлов из фонового обхода в состояние экрана: пачками, чтобы не дёргать кадры. */
private fun drain(
    queue: ConcurrentLinkedQueue<FolderNode>,
    all: MutableList<FolderNode>,
    visible: MutableList<FolderNode>,
    collapsed: Set<String>,
) {
    var moved = 0
    while (moved < DRAIN_BATCH) {
        val node = queue.poll() ?: return
        all.add(node)
        if (collapsed.none { node.path.startsWith("$it/") }) visible.add(node)
        moved += 1
    }
}

private const val DRAIN_BATCH = 2000
