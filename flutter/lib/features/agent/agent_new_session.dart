import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import 'agent_controller.dart';
import 'agent_types.dart';

class NewSessionChoice {
  final AgentProject project;

  final String harness;

  final String? modelKey;

  final String name;

  const NewSessionChoice({
    required this.project,
    required this.harness,
    this.modelKey,
    this.name = '',
  });
}

Future<NewSessionChoice?> showNewSessionWizard(
  BuildContext context,
  WidgetRef ref, {
  String suggestedName = '',
  String? fixedHarness,
}) {
  return showDialog<NewSessionChoice>(
    context: context,
    builder: (_) => _NewSessionWizard(
      suggestedName: suggestedName,
      fixedHarness: fixedHarness,
    ),
  );
}

class _NewSessionWizard extends ConsumerStatefulWidget {
  const _NewSessionWizard({this.suggestedName = '', this.fixedHarness});

  final String suggestedName;

  final String? fixedHarness;

  bool get harnessFixed => fixedHarness != null;

  @override
  ConsumerState<_NewSessionWizard> createState() => _NewSessionWizardState();
}

class _NewSessionWizardState extends ConsumerState<_NewSessionWizard> {
  int _step = 0;

  AgentProject? _project;

  bool _started = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    if (_started) return;
    _started = true;
    await ref.read(agentProjectsProvider.notifier).load();
    if (widget.harnessFixed) return;
    var available = ref.read(agentHarnessesProvider).available;
    if (available.isEmpty) {
      await ref.read(agentHarnessesProvider.notifier).load();
      available = ref.read(agentHarnessesProvider).available;
    }
    if (!mounted) return;
    final harnesses = available.isEmpty
        ? const <String>['claude']
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
            Flexible(
              child: widget.harnessFixed ? _folderStep() : (_step == 0 ? _folderStep() : _modelStep()),
            ),
            _actions(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    if (widget.harnessFixed) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
        child: Text(
          'Новый прогон · папка',
          style: TextStyle(color: C.fg, fontSize: 16),
        ),
      );
    }
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
          onTap: () {
            if (widget.harnessFixed) {
              Navigator.of(context).pop(NewSessionChoice(
                project: project,
                harness: widget.fixedHarness!,
                name: _name.text.trim(),
              ));
              return;
            }
            setState(() {
              _project = project;
              _step = 1;
            });
          },
        );
      },
    );
  }

  Widget _modelStep() {
    final state = ref.watch(agentAllModelsProvider);
    final claude = state.of('claude');
    final anyAvailable = claude.isNotEmpty;

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
              'Моделей не видно. Проверьте на маке, что установлен Claude Code.',
            ),
          if (claude.isNotEmpty) ...[
            _groupTitle('Claude Code'),
            for (final model in claude) _modelRow(model, 'claude'),
          ],
        ],
      ),
    );
  }

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

  Widget _buttons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }

  Widget _groupTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
    child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 12)),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      style: const TextStyle(color: C.fg3, fontSize: 12.5, height: 1.35),
    ),
  );

  IconData _harnessIcon(String harness) =>
      harness == 'claude' ? Icons.auto_awesome : Icons.terminal;

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
