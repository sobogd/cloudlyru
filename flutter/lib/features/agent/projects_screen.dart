import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_sessions_screen.dart';
import 'agent_types.dart';

/// Раздел «Проекты»: выбор папки проекта, в которой будет работать харнесс pi.
///
/// Открывается иконкой терминала в шапке «Чата» — это родственный, но другой раздел: чат
/// ищет в интернете и цитирует источники, а здесь агент читает и правит файлы в выбранной
/// папке и запускает команды. Смешивать их в одном списке значило бы показывать рядом
/// «разговоры о свежих данных» и «работу в репозитории».
///
/// Список проектов приходит от сервера, а тот берёт его у моста на маке
/// (`agents/pi-bridge`): это папки внутри разрешённых корней, а не файловый браузер — выбрать
/// домашний каталог или `/` нельзя. Адресов и ключей в приложении нет: доступ к разделу
/// закрыт той же сессией, что и у остальных разделов.
class ProjectsScreen extends ConsumerStatefulWidget {
  /// Экран списка проектов.
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

/// Состояние экрана: контроллер списка, взятый один раз, и больше ничего.
class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  /// Контроллер списка проектов.
  late final AgentProjectsController _projects;

  @override
  void initState() {
    super.initState();
    _projects = ref.read(agentProjectsProvider.notifier);
    // список читаем после первого кадра: до этого провайдеры трогать нельзя, а пустой экран
    // до ответа сервера выглядел бы как «проектов нет»
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _projects.load();
    });
  }

  /// Открывает список сессий выбранного проекта.
  Future<void> _openProject(AgentProject project) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AgentSessionsScreen(project: project)),
    );
    // после возврата перечитываем: в проекте могла появиться новая сессия
    if (mounted) await _projects.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentProjectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Проекты', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            onPressed: state.loading ? null : () => _projects.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // чем отвечает харнесс: без этой строки непонятно, какая модель считает — а на маке
          // она одна на чат и на агента
          if (state.health.label.isNotEmpty) _harnessLine(state.health),
          if (state.error != null) _errorBar(state.error!),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  /// Тело экрана: индикатор загрузки, пустой список или сами проекты.
  Widget _body(AgentProjectsState state) {
    if (state.loading && state.projects.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.projects.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Проектов нет. Мост на маке показывает папки внутри разрешённых корней — обычно '
            'это ~/work; список корней правится в ~/.pi-bridge.json.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _projects.load(),
      child: ListView.builder(
        padding: EdgeInsets.only(bottom: 16 + navBarInset(context)),
        itemCount: state.projects.length,
        itemBuilder: (context, i) => _projectTile(state.projects[i]),
      ),
    );
  }

  /// Строка списка: имя папки, путь, число сессий и время последней.
  Widget _projectTile(AgentProject project) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined, color: C.fg2),
      title: Text(
        project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 15),
      ),
      subtitle: Text(
        [
          project.path,
          if (project.sessions > 0) '${project.sessions} сессий',
          if (project.lastUsed != null) listDate(project.lastUsed!, DateTime.now()),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
      onTap: () => _openProject(project),
    );
  }

  /// Строка о харнессе и модели над списком.
  Widget _harnessLine(AgentHealth health) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            health.label,
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
        ),
      );

  /// Сообщение об ошибке над списком: «мост недоступен» — состояние раздела, а не сбой строки.
  Widget _errorBar(String message) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.danger),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: C.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3)),
            ),
            TextButton(onPressed: () => _projects.load(), child: const Text('Повторить')),
          ],
        ),
      );
}
