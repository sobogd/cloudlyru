import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import 'agent_controller.dart';
import 'agent_providers_screen.dart';
import 'agent_types.dart';

/// Выбор человека в мастере новой сессии: папка, харнесс и модель.
///
/// Именем типа, а не записью из трёх полей: результат уходит наружу, и по нему экран открывает
/// сессию — так видно, что «сначала пусто» здесь невозможно.
class NewSessionChoice {
  /// Папка проекта, в которой поднимется агент.
  final AgentProject project;

  /// Харнесс разговора (`pi` или `claude`).
  final String harness;

  /// Модель в виде `провайдер/идентификатор`; `null` — модель по умолчанию харнесса.
  final String? modelKey;

  /// Имя разговора, если человек его задал; пусто — имя поставит сам харнесс по первому вопросу.
  final String name;

  /// Выбор новой сессии.
  const NewSessionChoice({
    required this.project,
    required this.harness,
    this.modelKey,
    this.name = '',
  });
}

/// Мастер новой сессии: папка проекта → модель (локальные, удалённые, Claude Code).
///
/// Показывается модалкой по кнопке «+» в общем списке разговоров. Сессию он не открывает сам, а
/// только возвращает выбор: поднимает её экран, который умеет показать отказ моста и перейти в
/// переписку.
///
/// Список моделей берётся у всех харнессов сразу: в этом выборе рядом стоят локальные модели pi,
/// удалённые по API и модели Claude Code, и человек должен видеть их одним списком.
/// [suggestedName] — имя, предложенное разделом, который позвал мастер (доска PR предлагает
/// `repo#123`). Человек его правит или стирает: поле необязательное.
Future<NewSessionChoice?> showNewSessionWizard(
  BuildContext context,
  WidgetRef ref, {
  String suggestedName = '',
}) {
  return showDialog<NewSessionChoice>(
    context: context,
    builder: (_) => _NewSessionWizard(suggestedName: suggestedName),
  );
}

/// Диалог-мастер: два шага в одном виджете, чтобы шаг назад не терял выбранную папку.
class _NewSessionWizard extends ConsumerStatefulWidget {
  /// Диалог мастера новой сессии.
  const _NewSessionWizard({this.suggestedName = ''});

  /// Имя, с которым поле открывается заполненным.
  final String suggestedName;

  @override
  ConsumerState<_NewSessionWizard> createState() => _NewSessionWizardState();
}

/// Состояние мастера: текущий шаг и выбранная на первом шаге папка.
class _NewSessionWizardState extends ConsumerState<_NewSessionWizard> {
  /// Шаг: 0 — папка, 1 — модель.
  int _step = 0;

  /// Папка, выбранная на первом шаге.
  AgentProject? _project;

  /// Загружаем ли мы данные (используется, чтобы не запускать загрузку дважды).
  bool _started = false;

  /// Имя будущего разговора: необязательное, живёт на обоих шагах.
  ///
  /// Полем, а не отдельным шагом: имя нужно далеко не всегда, и лишний экран между выбором
  /// модели и разговором стоил бы нажатия в каждой новой сессии.
  late final TextEditingController _name =
      TextEditingController(text: widget.suggestedName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Данные читаем после первого кадра: провайдеры в initState трогать нельзя. Проекты и
    // харнессы читаются заново, а не берутся из экрана: диалог может открыться и до его
    // первой загрузки.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  /// Читает проекты и харнессы, затем модели всех доступных харнессов.
  ///
  /// Харнессы определяют, чьи модели показывать, поэтому модели читаются только после них. Если
  /// про харнессы узнать не удалось (мост недоступен), предлагаем хотя бы pi: его список моделей
  /// всё равно вернёт ошибку словами, и она покажется в диалоге.
  ///
  /// Проекты перечитываются всегда, а не берутся из экрана: в них лежит число разговоров в
  /// папке, и после удаления сессии оно расходилось с самим списком («5 разговоров» при четырёх
  /// строках), потому что экран обновляет только список сессий, а проекты читает один раз.
  Future<void> _prepare() async {
    if (_started) return;
    _started = true;
    await ref.read(agentProjectsProvider.notifier).load();
    var available = ref.read(agentHarnessesProvider).available;
    if (available.isEmpty) {
      await ref.read(agentHarnessesProvider.notifier).load();
      available = ref.read(agentHarnessesProvider).available;
    }
    if (!mounted) return;
    final harnesses = available.isEmpty
        ? const <String>['pi']
        : [for (final h in available) h.harness];
    await ref.read(agentAllModelsProvider.notifier).load(harnesses);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: C.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            Flexible(child: _step == 0 ? _folderStep() : _modelStep()),
            _actions(),
          ],
        ),
      ),
    );
  }

  /// Шапка: на первом шаге — название, на втором — выбранная папка и возврат назад.
  Widget _header() {
    if (_step == 0) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
        child: Text(
          'Новая сессия · папка',
          style: TextStyle(color: C.fg, fontSize: 16),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 20, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Назад к папкам',
            onPressed: () => setState(() => _step = 0),
            icon: const Icon(Icons.arrow_back, color: C.fg2, size: 20),
          ),
          Expanded(
            child: Text(
              'Модель · ${_project?.name ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.fg, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  /// Первый шаг: список папок, в которых можно поднять агента.
  Widget _folderStep() {
    final state = ref.watch(agentProjectsProvider);
    if (state.loading && state.projects.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.projects.isEmpty) {
      return _hint(
        state.error ??
            'Проектов нет. Мост на маке показывает папки внутри разрешённых корней — обычно '
                'это ~/work.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: state.projects.length,
      itemBuilder: (context, i) {
        final project = state.projects[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined, color: C.fg2, size: 20),
          title: Text(
            project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.fg, fontSize: 14.5),
          ),
          subtitle: Text(
            [
              project.path,
              if (project.sessions > 0) '${project.sessions} разговоров',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.fg3, fontSize: 11.5),
          ),
          onTap: () => setState(() {
            _project = project;
            _step = 1;
          }),
        );
      },
    );
  }

  /// Второй шаг: модели трёх групп — на маке, по API и Claude Code.
  Widget _modelStep() {
    final state = ref.watch(agentAllModelsProvider);
    final piLocal = [
      for (final m in state.of('pi'))
        if (m.local) m,
    ];
    final piRemote = [
      for (final m in state.of('pi'))
        if (!m.local) m,
    ];
    final claude = state.of('claude');
    final anyAvailable =
        piLocal.isNotEmpty || piRemote.isNotEmpty || claude.isNotEmpty;

    if (state.loading && !anyAvailable) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Text(
                state.error!,
                style: const TextStyle(
                  color: C.danger,
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
            ),
          if (!anyAvailable && state.error == null)
            _hint(
              'Моделей не видно. Проверьте на маке, что pi настроен: pi --list-models.',
            ),
          if (piLocal.isNotEmpty) ...[
            _groupTitle('На этом маке'),
            for (final model in piLocal) _modelRow(model, 'pi'),
          ],
          if (piRemote.isNotEmpty) ...[
            _groupTitle('По API (удалённые)'),
            for (final model in piRemote) _modelRow(model, 'pi'),
          ],
          if (claude.isNotEmpty) ...[
            _groupTitle('Claude Code'),
            for (final model in claude) _modelRow(model, 'claude'),
          ],
        ],
      ),
    );
  }

  /// Строка модели: по тапу возвращает выбор наружу.
  Widget _modelRow(AgentModel model, String harness) {
    final enabled = model.hasKey;
    return InkWell(
      onTap: enabled
          ? () => Navigator.of(context).pop(
              NewSessionChoice(
                project: _project!,
                harness: harness,
                modelKey: model.key,
                name: _name.text.trim(),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _harnessIcon(harness),
              size: 18,
              color: enabled ? C.accent : C.fg3,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.label,
                    style: TextStyle(
                      color: enabled ? C.fg : C.fg3,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      model.key,
                      if (model.contextWindow != null)
                        'окно ${_tokens(model.contextWindow!)}',
                      if (!model.hasKey) 'нужен ключ на маке',
                    ].join(' · '),
                    style: TextStyle(
                      color: model.hasKey ? C.fg3 : C.warn,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Кнопки внизу: добавить провайдера и закрыть.
  Widget _actions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: TextField(
            controller: _name,
            style: const TextStyle(color: C.fg, fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Название разговора (необязательно)',
              labelStyle: TextStyle(color: C.fg3, fontSize: 12.5),
            ),
          ),
        ),
        _buttons(),
      ],
    );
  }

  /// Кнопки мастера: провайдеры и отмена.
  Widget _buttons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          // Провайдеров можно добавлять при pi: Claude Code берёт модели из своей подписки или
          // ключа, и снаружи в него не влезть
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AgentProvidersScreen(),
                ),
              );
            },
            child: const Text('Провайдеры'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }

  /// Заголовок группы моделей.
  Widget _groupTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
    child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 12)),
  );

  /// Пояснение вместо списка: пусто, но не из-за ошибки запроса.
  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      style: const TextStyle(color: C.fg3, fontSize: 12.5, height: 1.35),
    ),
  );

  /// Значок харнесса: у pi терминал, у Claude Code — звёздочка его бренда.
  IconData _harnessIcon(String harness) =>
      harness == 'claude' ? Icons.auto_awesome : Icons.terminal;

  /// Токены в коротком виде: «32 768» читается лучше, чем «32768».
  String _tokens(int value) {
    final text = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}
