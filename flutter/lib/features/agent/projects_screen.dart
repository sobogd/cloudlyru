import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
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
/// Список проектов приходит от моста на маке (`agents/pi-bridge`): это папки внутри
/// разрешённых корней, а не файловый браузер — выбрать домашний каталог или `/` нельзя.
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
    // до ответа моста выглядел бы как «проектов нет»
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

  /// Диалог настроек доступа к мосту: адрес, токен моста и пара Cloudflare Access.
  ///
  /// Всё, что нужно для доступа, лежит в приложении, а не в репозитории: токен моста — в
  /// `~/.pi-bridge.json` на маке, пара Access — в панели Cloudflare. После сохранения список
  /// перечитывается сразу: человек должен увидеть, что новый адрес работает, а не гадать.
  Future<void> _settings() async {
    final settings = ref.read(settingsProvider);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BridgeSettingsDialog(
        url: settings.agentUrl,
        token: settings.agentToken,
        cfId: settings.agentCfId,
        cfSecret: settings.agentCfSecret,
        onSave: (url, token, cfId, cfSecret) async {
          await settings.setAgentUrl(url);
          await settings.setAgentToken(token);
          await settings.setAgentCf(cfId, cfSecret);
        },
      ),
    );
    if (saved == true && mounted) await _projects.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentProjectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Проекты', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Настройки доступа',
            onPressed: _settings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Обновить список',
            onPressed: state.loading ? null : () => _projects.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // чем отвечает харнесс: без этой строки непонятно, куда уходит запрос и какая
          // модель его считает — а на маке она одна на чат и на агента
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
            'Проектов нет. Мост показывает папки внутри разрешённых корней — обычно это '
            '~/work; список корней правится в ~/.pi-bridge.json на маке.',
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

/// Диалог настроек доступа к мосту.
///
/// Четыре поля одним экраном, а не по одному: это один и тот же доступ (туннель + токен
/// моста), и заполнять его человек будет за один заход — копируя значения из терминала
/// мака и из панели Cloudflare.
class _BridgeSettingsDialog extends StatefulWidget {
  /// Текущие значения — то, что уже сохранено в настройках.
  final String url;
  final String token;
  final String cfId;
  final String cfSecret;

  /// Сохранение: вызывающий пишет значения в настройки приложения.
  final Future<void> Function(String url, String token, String cfId, String cfSecret) onSave;

  /// Диалог настроек доступа.
  const _BridgeSettingsDialog({
    required this.url,
    required this.token,
    required this.cfId,
    required this.cfSecret,
    required this.onSave,
  });

  @override
  State<_BridgeSettingsDialog> createState() => _BridgeSettingsDialogState();
}

/// Состояние диалога: контроллеры полей и признак «идёт сохранение».
class _BridgeSettingsDialogState extends State<_BridgeSettingsDialog> {
  /// Контроллеры полей; создаются один раз и освобождаются в [dispose].
  late final TextEditingController _url = TextEditingController(text: widget.url);
  late final TextEditingController _token = TextEditingController(text: widget.token);
  late final TextEditingController _cfId = TextEditingController(text: widget.cfId);
  late final TextEditingController _cfSecret = TextEditingController(text: widget.cfSecret);

  /// Идёт запись настроек: кнопка блокируется, чтобы не сохранить дважды.
  bool _saving = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _cfId.dispose();
    _cfSecret.dispose();
    super.dispose();
  }

  /// Сохраняет введённое и закрывает диалог с признаком успеха.
  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.onSave(_url.text, _token.text, _cfId.text, _cfSecret.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: C.surface,
      title: const Text('Доступ к мосту', style: TextStyle(color: C.fg, fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_url, 'Адрес моста', 'https://pi.iq-factura.com'),
            const SizedBox(height: 10),
            _field(_token, 'Токен моста', 'из ~/.pi-bridge.json на маке'),
            const SizedBox(height: 10),
            _field(_cfId, 'Cloudflare Access: Client Id', ''),
            const SizedBox(height: 10),
            _field(_cfSecret, 'Cloudflare Access: Client Secret', ''),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }

  /// Одно поле диалога с подписью-подсказкой.
  Widget _field(TextEditingController controller, String label, String hint) => TextField(
        controller: controller,
        style: const TextStyle(color: C.fg, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: C.fg3, fontSize: 12),
          hintText: hint.isEmpty ? null : hint,
          hintStyle: const TextStyle(color: C.fg3, fontSize: 12),
          filled: true,
          fillColor: C.canvas,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}
