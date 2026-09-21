import 'package:flutter/material.dart';

import '../../theme.dart';
import 'agent_types.dart';

/// Итог диалога уборки: что и по какому правилу удалять.
///
/// [count] — сколько разговоров попадёт под правило (посчитано в диалоге): по нему экран
/// показывает подтверждение до удаления, а не узнаёт число по факту.
class PurgeChoice {
  /// Проект, чьи разговоры убираются.
  final AgentProject project;

  /// Харнесс разговоров.
  final String harness;

  /// Удалять старше стольких дней; `null` — по возрасту не ограничиваем.
  final int? olderThanDays;

  /// Сколько самых свежих разговоров оставить; `null` — не защищаем ничего.
  final int? keep;

  /// Сколько разговоров уйдёт по этому правилу.
  final int count;

  /// Итог выбора в диалоге уборки.
  const PurgeChoice({
    required this.project,
    required this.harness,
    required this.count,
    this.olderThanDays,
    this.keep,
  });
}

/// Диалог уборки старых разговоров: папка, харнесс и правило.
///
/// В общем списке разговоров папка и харнесс не заданы, поэтому выбираются здесь. Числа
/// считаются из уже загруженного списка (сессии приходят со всех проектов сразу): человек
/// должен видеть «удалится 192» до нажатия, а не узнавать это по факту.
Future<PurgeChoice?> showPurgeDialog(
  BuildContext context, {
  required List<AgentProject> projects,
  required List<AgentSession> sessions,
  required List<AgentHarness> harnesses,
}) {
  return showDialog<PurgeChoice>(
    context: context,
    builder: (_) => _PurgeDialog(
      projects: projects,
      sessions: sessions,
      harnesses: harnesses,
    ),
  );
}

/// Диалог уборки.
class _PurgeDialog extends StatefulWidget {
  /// Проекты из allowlist моста.
  final List<AgentProject> projects;

  /// Общий список разговоров (по нему считаются числа).
  final List<AgentSession> sessions;

  /// Доступные харнессы.
  final List<AgentHarness> harnesses;

  /// Диалог уборки.
  const _PurgeDialog({
    required this.projects,
    required this.sessions,
    required this.harnesses,
  });

  @override
  State<_PurgeDialog> createState() => _PurgeDialogState();
}

/// Состояние диалога: выбранные папка, харнесс и правило.
class _PurgeDialogState extends State<_PurgeDialog> {
  /// Сколько свежих разговоров оставляем во втором правиле.
  static const _keepFreshCount = 5;

  /// Индекс выбранной папки в [widget.projects].
  int _projectIndex = 0;

  /// Выбранный харнесс; `null` — ещё не выбран, берётся первый доступный.
  String? _harness;

  /// Выбрано правило «оставить только свежие».
  bool _keepFresh = false;

  @override
  void initState() {
    super.initState();
    // Стартуем с первой папки, у которой вообще есть разговоры: убирать в пустой нечего, и
    // показывать её первой значило бы давать бессмысленный экран.
    final index = widget.projects.indexWhere((p) => _countFor(p.path, _firstHarness) > 0);
    if (index >= 0) _projectIndex = index;
  }

  /// Харнесс, который выбран сейчас или был бы выбран по умолчанию.
  String get _firstHarness => widget.harnesses.isEmpty
      ? 'pi'
      : widget.harnesses.first.harness;

  /// Текущий харнесс.
  String get _activeHarness => _harness ?? _firstHarness;

  /// Текущая папка.
  AgentProject get _project => widget.projects.isEmpty
      ? const AgentProject(path: '', name: '')
      : widget.projects[_projectIndex.clamp(0, widget.projects.length - 1)];

  /// Считает, сколько разговоров папки и харнесса попадёт под правило.
  ///
  /// Повторяет арифметику моста: свежие защищены, остальное удаляется по возрасту. Нужно, чтобы
  /// число в диалоге совпадало с тем, что произойдёт на маке.
  int _countFor(
    String path,
    String harness, {
    int? olderThanDays,
    int? keep,
  }) {
    final relevant = [
      for (final s in widget.sessions)
        if (s.path == path && s.harness == harness) s,
    ];
    final sorted = [...relevant]
      ..sort(
        (a, b) =>
            (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
      );
    final protected = <String>{
      if (keep != null)
        for (final s in sorted.take(keep)) s.id,
    };
    final threshold = olderThanDays == null
        ? null
        : DateTime.now().subtract(Duration(days: olderThanDays));
    return relevant
        .where(
          (s) =>
              !protected.contains(s.id) &&
              (threshold == null || (s.updatedAt?.isBefore(threshold) ?? true)),
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final harness = _activeHarness;
    final project = _project;
    final total = widget.sessions
        .where((s) => s.path == project.path && s.harness == harness)
        .length;
    final keepCount = _countFor(project.path, harness, keep: _keepFreshCount);
    final weekCount = _countFor(project.path, harness, olderThanDays: 7);

    return AlertDialog(
      backgroundColor: C.surface,
      title: const Text(
        'Убрать старые',
        style: TextStyle(color: C.fg, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.harnesses.length > 1) ...[
              SegmentedButton<String>(
                segments: [
                  for (final h in widget.harnesses)
                    ButtonSegment<String>(
                      value: h.harness,
                      label: Text(h.label),
                    ),
                ],
                selected: <String>{harness},
                showSelectedIcon: false,
                onSelectionChanged: (value) =>
                    setState(() => _harness = value.first),
              ),
              const SizedBox(height: 8),
            ],
            DropdownButtonFormField<int>(
              initialValue: _projectIndex.clamp(0, widget.projects.length - 1),
              isExpanded: true,
              dropdownColor: C.surface,
              decoration: const InputDecoration(
                labelText: 'Папка',
                isDense: true,
              ),
              items: [
                for (var i = 0; i < widget.projects.length; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(
                      '${widget.projects[i].name} · '
                      '${_countFor(widget.projects[i].path, harness)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg, fontSize: 13.5),
                    ),
                  ),
              ],
              onChanged: widget.projects.isEmpty
                  ? null
                  : (value) => setState(() => _projectIndex = value ?? 0),
            ),
            const SizedBox(height: 10),
            Text(
              'Всего разговоров: $total. Удаление необратимо.',
              style: const TextStyle(color: C.fg3, fontSize: 12, height: 1.35),
            ),
            RadioGroup<bool>(
              groupValue: _keepFresh,
              onChanged: (v) => setState(() => _keepFresh = v ?? false),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text(
                      'Удалить старше 7 дней — $weekCount',
                      style: const TextStyle(color: C.fg, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Разговоры за последнюю неделю остаются все',
                      style: TextStyle(color: C.fg3, fontSize: 11.5),
                    ),
                  ),
                  RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: Text(
                      'Оставить только $_keepFreshCount свежих — $keepCount',
                      style: const TextStyle(color: C.fg, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Всё остальное, включая вчерашнее, удаляется',
                      style: TextStyle(color: C.fg3, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            PurgeChoice(
              project: project,
              harness: harness,
              count: _keepFresh ? keepCount : weekCount,
              olderThanDays: _keepFresh ? null : 7,
              keep: _keepFresh ? _keepFreshCount : null,
            ),
          ),
          child: const Text('Дальше'),
        ),
      ],
    );
  }
}
