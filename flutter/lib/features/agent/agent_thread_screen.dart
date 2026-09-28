import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../theme.dart';
import '../../util/format.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../util/widgets.dart';
import 'agent_api.dart';
import 'agent_controller.dart';
import 'agent_model_picker.dart';
import 'agent_types.dart';

class AgentThreadScreen extends ConsumerStatefulWidget {
  final AgentSessionInfo session;

  final AgentProject project;

  final bool embedded;

  final double? paneWidth;

  final String? initialPrompt;

  final String? pendingName;

  final VoidCallback? onDismiss;

  final bool hidden;

  const AgentThreadScreen({
    super.key,
    required this.session,
    required this.project,
    this.embedded = false,
    this.paneWidth,
    this.onDismiss,
    this.initialPrompt,
    this.pendingName,
    this.hidden = false,
  });

  @override
  ConsumerState<AgentThreadScreen> createState() => _AgentThreadScreenState();
}

class _AgentThreadScreenState extends ConsumerState<AgentThreadScreen> {
  final _input = TextEditingController();

  final _scroll = ScrollController();

  bool _follow = true;

  bool _selfScroll = false;

  bool _details = false;


  bool _initialJumpDone = false;

  int _initialJumpTries = 0;

  double _initialJumpExtent = -1;

  Timer? _ticker;

  AppLifecycleListener? _lifecycle;

  bool _named = false;

  late final AgentThreadController _thread;

  final _recorder = AudioRecorder();

  bool _recording = false;

  bool _transcribing = false;

  String? _recordPath;

  @override
  void initState() {
    super.initState();
    _thread = ref.read(agentThreadProvider.notifier);
    final prompt = widget.initialPrompt;
    if (prompt != null && prompt.isNotEmpty) _input.text = prompt;
    _scroll.addListener(_trackScroll);
    _lifecycle = AppLifecycleListener(onResume: _thread.resume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initialJumpDone = false;
      _initialJumpTries = 0;
      _initialJumpExtent = -1;
      _thread.attach(widget.session);
      _scrollToBottomSoon();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle?.dispose();
    _thread.detach();
    _input.dispose();
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _trackScroll() {
    if (!_scroll.hasClients || _selfScroll) return;
    if (!_initialJumpDone) return;
    _follow = _scroll.position.maxScrollExtent - _scroll.position.pixels < 80;
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _follow = true;
    await _thread.send(text);
    await _applyPendingName();
  }

  Future<void> _applyPendingName() async {
    final name = widget.pendingName;
    if (_named || name == null || name.isEmpty) return;
    _named = true;
    await ref.read(agentSessionsProvider.notifier).rename(widget.session.id, name);
  }

  Future<void> _startRecording() async {
    if (_recording || _transcribing) return;
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) snack(context, 'Нет доступа к микрофону');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recordPath = path;
        _recording = true;
      });
    } catch (e) {
      if (mounted) snack(context, 'Не удалось начать запись: $e');
    }
  }

  Future<void> _stopRecordingAndTranscribe() async {
    if (!_recording) return;
    final path = _recordPath;
    _recordPath = null;
    setState(() {
      _recording = false;
      _transcribing = true;
    });
    try {
      await _recorder.stop();
      if (path == null) throw const FileSystemException('путь записи потерян');
      final file = File(path);
      final audio = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {
      }
      if (audio.isEmpty) throw const FileSystemException('пустая запись');
      final text = await ref.read(agentApiProvider).transcribe(audio);
      if (!mounted) return;
      if (text.isEmpty) {
        snack(context, 'Речь не распознана');
        return;
      }
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    } on AgentApiException catch (e) {
      if (mounted) snack(context, e.message);
    } catch (e) {
      if (mounted) snack(context, 'Распознавание не удалось: $e');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  void _syncTicker(bool sending) {
    if (sending && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!sending && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  Future<void> _pickModel() async {
    final session = ref.read(agentThreadProvider).session;
    final chosen = await showModelPicker(
      context,
      ref,
      harness: session?.harness.isEmpty ?? true ? 'pi' : session!.harness,
      current: session?.model,
    );
    if (chosen == null || !mounted) return;
    await _thread.setModel(chosen);
    if (mounted) snack(context, 'Модель: ${chosen.label}');
  }

  Future<void> _pickEffort() async {
    final session = ref.read(agentThreadProvider).session;
    if (session == null) return;
    final chosen = await showEffortPicker(context, ref, current: session.effort);
    if (chosen == null || !mounted) return;
    await _thread.setEffort(chosen);
    if (!mounted) return;
    snack(
      context,
      chosen.isEmpty
          ? 'Усилие: как решает Claude Code'
          : 'Усилие: ${agentEffortLabel(chosen)}',
    );
  }

  Future<void> _compact() async {
    final ok = await confirmDialog(
      context,
      'Сжать контекст',
      'Агент перескажет разговор и продолжит с короткой историей. Старые сообщения останутся '
          'в файле сессии, но в контекст модели больше не попадут.',
      confirmLabel: 'Сжать',
    );
    if (!ok || !mounted) return;
    await _thread.compact();
  }

  Future<void> _delete() async {
    final session = ref.read(agentThreadProvider).session;
    if (session == null) return;
    final ok = await confirmDialog(
      context,
      'Удалить сессию',
      'Разговор будет удалён на маке вместе с историей. Восстановить его нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final result = await _thread.deleteSession();
    if (!mounted || result == null) return;
    if (result.anyDeleted) {
      snack(context, 'Сессия удалена');
      if (widget.embedded) {
        widget.onDismiss?.call();
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    if (result.anyRestored) {
      snack(
        context,
        'Этот разговор ведёт живой процесс Claude Code: файл восстановлен, удалить его отсюда '
        'нельзя — только в самом Claude',
      );
      return;
    }
    snack(context, 'Удалять было нечего: файл сессии не найден');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentThreadProvider);
    _syncTicker(state.sending);

    ref.listen(agentThreadProvider, (_, next) {
      if (next.loading) {
        _initialJumpDone = false;
        _initialJumpTries = 0;
        _initialJumpExtent = -1;
        return;
      }
      if (next.items.isEmpty) return;
      if (_follow || !_initialJumpDone) _scrollToBottomSoon();
    });

    if (!_initialJumpDone && !state.loading && state.items.isNotEmpty) {
      _scrollToBottomSoon();
    }

    final body = Column(
      children: [
        Expanded(child: _body(state)),
        if (_details) _detailsPanel(state),
        if (state.error != null) _errorBar(state),
        _composer(state),
      ],
    );

    if (widget.embedded) {
      return Column(
        children: [
          _paneHeader(state),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _title(state),
        actions: [_actions(state)],
        backgroundColor: C.island,
      ),
      body: body,
    );
  }

  Widget _title(AgentThreadState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        (state.session?.name.isNotEmpty ?? false)
            ? state.session!.name
            : widget.project.name,
        style: const TextStyle(color: C.fg, fontSize: 17),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 1),
      Text(
        [
          widget.project.name,
          state.session?.modelLabel ?? widget.session.modelLabel,
        ].where((s) => s.isNotEmpty).join(' · '),
        style: const TextStyle(color: C.fg3, fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );

  Widget _actions(AgentThreadState state) => PopupMenuButton<String>(
    tooltip: 'Ещё',
    onSelected: (v) => switch (v) {
      'details' => setState(() => _details = !_details),
      'model' => _pickModel(),
      'effort' => _pickEffort(),
      'stop' => _thread.stop(),
      'compact' => _compact(),
      _ => _delete(),
    },
    style: IconButton.styleFrom(
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    iconSize: 22,
    itemBuilder: (context) => [
      PopupMenuItem(
        value: 'details',
        child: Text(_details ? 'Скрыть сведения' : 'Сведения о сессии'),
      ),
      const PopupMenuItem(value: 'model', child: Text('Модель')),
      if (state.session?.harness == 'claude')
        const PopupMenuItem(value: 'effort', child: Text('Усилие')),
      PopupMenuItem(
        value: 'stop',
        enabled: state.sending,
        child: const Text('Стоп'),
      ),
      PopupMenuItem(
        value: 'compact',
        enabled: !state.sending,
        child: const Text('Сжать контекст'),
      ),
      const PopupMenuItem(value: 'delete', child: Text('Удалить сессию')),
    ],
  );

  Widget _paneHeader(AgentThreadState state) => Container(
    height: 56,
    color: C.island,
    child: Row(
      children: [
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'К списку разговоров',
          onPressed: widget.onDismiss,
          icon: const Icon(Icons.arrow_back),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 8),
        Expanded(child: _title(state)),
        const SizedBox(width: 8),
        _actions(state),
        const SizedBox(width: 8),
      ],
    ),
  );

  Widget _body(AgentThreadState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Агент работает в папке ${widget.project.path}.\n\n'
            'Он может читать и править файлы проекта и запускать команды — '
            'спрашивать подтверждение он не будет.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    final entries = _entries(
      state.items,
      streaming: state.sending,
      step: state.step,
      toolHidden: widget.hidden,
    );
    final older = state.hasOlder;
    return SelectionContainer(
      delegate: StaticSelectionContainerDelegate(),
      child: ListView.builder(

      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: entries.length + (older ? 1 : 0),
      itemBuilder: (context, i) {
        if (older && i == 0) return _olderRow();
        return _entry(entries[older ? i - 1 : i]);
      },
    ),
    );
  }

  Widget _olderRow() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Center(
      child: TextButton(
        onPressed: _loadOlder,
        child: const Text('Показать более раннее'),
      ),
    ),
  );



  Future<void> _loadOlder() async {
    if (!_scroll.hasClients) {
      await _thread.loadOlder();
      return;
    }
    final before = _scroll.position.maxScrollExtent;
    _selfScroll = true;
    await _thread.loadOlder();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final after = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(_scroll.position.pixels + (after - before));
      _selfScroll = false;
    });
  }

  List<_Entry>? _entriesCache;
  List<AgentItem>? _entriesFor;
  bool _entriesStreaming = false;
  bool _entriesToolHidden = false;

  List<_Entry> _entries(List<AgentItem> items,
      {required bool streaming,
      String? step,
      bool toolHidden = false}) {
    if (_entriesCache != null &&
        identical(_entriesFor, items) &&
        _entriesStreaming == streaming &&
        _entriesToolHidden == toolHidden) {
      return _entriesCache!;
    }
    final entries = _buildEntries(items, streaming, step: step, toolHidden: toolHidden);
    _entriesFor = items;
    _entriesStreaming = streaming;
    _entriesToolHidden = toolHidden;
    _entriesCache = entries;
    return entries;
  }

  List<_Entry> _buildEntries(List<AgentItem> items, bool streaming,
      {String? step, bool toolHidden = false}) {
    final entries = <_Entry>[];
    for (final item in items) {
      final mine = <_Entry>[];
      if (item.kind == 'note') {
        mine.add(_Entry(_EntryKind.note, text: item.text));
      } else if (item.kind == 'bash') {
        mine.add(
          _Entry(
            _EntryKind.bash,
            text: item.text,
            command: item.command,
            exitCode: item.exitCode,
          ),
        );
      } else if (item.isUser) {
        mine.add(_Entry(_EntryKind.user, text: item.text));
      } else if (item.blocks.isEmpty) {
        if (item.reasoning.trim().isNotEmpty) {
          mine.add(_Entry(_EntryKind.reasoning, text: item.reasoning));
        }
        if (item.text.trim().isNotEmpty) {
          mine.add(_Entry(_EntryKind.text, text: item.text));
        }
        for (final tool in item.tools) {
          mine.add(_Entry(_EntryKind.tool, tool: tool));
        }
      } else {
        final byId = <String, AgentTool>{
          for (final tool in item.tools) tool.id: tool,
        };
        for (final block in item.blocks) {
          if (block.isTool) {
            final tool = byId[block.toolId];
            if (tool != null) mine.add(_Entry(_EntryKind.tool, tool: tool));
          } else if (block.isReasoning) {
            if (block.text.trim().isNotEmpty) {
              mine.add(_Entry(_EntryKind.reasoning, text: block.text));
            }
          } else {
            if (block.text.trim().isNotEmpty) {
              mine.add(_Entry(_EntryKind.text, text: block.text));
            }
          }
        }
      }
      if (mine.isEmpty && item.isAssistant && item.isEmpty) {
        mine.add(const _Entry(_EntryKind.waiting));
      }
      if (item.error.isNotEmpty && mine.isNotEmpty) {
        mine[mine.length - 1] = mine.last.copyWith(error: item.error);
      }
      entries.addAll(mine);
    }
    if (streaming && entries.isNotEmpty && items.isNotEmpty && items.last.isAssistant) {
      entries[entries.length - 1] = entries.last.copyWith(streaming: true);
    }
    if ((step?.isNotEmpty ?? false) && !streaming) {
      entries.add(_Entry(_EntryKind.step, text: step!));
    }
    return entries;
  }

  String _toolLabel(AgentTool tool) {
    if (tool.args.isEmpty) return tool.name;
    final parts = tool.args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    return '${tool.name}($parts)';
  }

  Widget _entry(_Entry entry) {
    if (entry.kind == _EntryKind.note) return _noteCard(entry.text);
    if (entry.kind == _EntryKind.bash) {
      return entry.exitCode != null && entry.exitCode! != 0
          ? _errorCard('\$ ${entry.command}', entry.text)
          : _instructionCard('\$ ${entry.command}', entry.text);
    }
    if (entry.kind == _EntryKind.tool) {
      final tool = entry.tool!;
      if (tool.running) {
        return _instructionCard('⏳ ${_toolLabel(tool)}', tool.output);
      }
      if (tool.isError) {
        return _errorCard(_toolLabel(tool), '');
      }
      return _instructionCard(_toolLabel(tool), '');
    }
    if (entry.kind == _EntryKind.reasoning) return _agentCard(entry.text);
    if (entry.kind == _EntryKind.user) return _userCard(entry.text);
    if (entry.kind == _EntryKind.text) return _agentCard(entry.text);
    if (entry.kind == _EntryKind.waiting) return _agentCard('');
    if (entry.kind == _EntryKind.step) return _stepIndicator(entry.text);
    return SizedBox();
  }

  Widget _userCard(String text) {
    final body = text.isEmpty
        ? SizedBox()
        : MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                color: const Color(0xFF1A1D24),
                fontSize: _textSize,
                height: 1.35,
              ),
              code: TextStyle(
                color: const Color(0xFF1A1D24),
                backgroundColor: C.surface3,
                fontSize: _textSize,
                fontFamily: 'monospace',
              ),
              blockquote: TextStyle(
                color: C.fg2,
                fontSize: _textSize,
                height: 1.35,
              ),
              em: TextStyle(
                color: const Color(0xFF1A1D24),
                fontStyle: FontStyle.italic,
                fontSize: _textSize,
              ),
              strong: TextStyle(
                color: const Color(0xFF1A1D24),
                fontSize: _textSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _messageGapV),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }

  Widget _agentCard(String text) {
    final body = text.isEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                color: C.fg,
                fontSize: _textSize,
                height: 1.35,
              ),
              code: TextStyle(
                color: C.fg,
                backgroundColor: C.surface3,
                fontSize: _textSize,
                fontFamily: 'monospace',
              ),
              blockquote: TextStyle(
                color: C.fg2,
                fontSize: _textSize,
                height: 1.35,
              ),
              em: TextStyle(
                color: C.fg,
                fontStyle: FontStyle.italic,
                fontSize: _textSize,
              ),
              strong: TextStyle(
                color: C.fg,
                fontSize: _textSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _messageGapV),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }

  Widget _instructionCard(String title, String bodyText) {
    final showBody = bodyText.trim().isNotEmpty;
    if (title.trim().isEmpty && !showBody) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _messageGapV),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.ok.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Text(
                title,
                style: const TextStyle(
                  color: C.ok,
                  fontSize: _textSize,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            if (showBody)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _OutputText(bodyText, color: C.fg2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String title, String bodyText) {
    final showBody = bodyText.trim().isNotEmpty;
    if (title.trim().isEmpty && !showBody) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _messageGapV),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Text(
                title,
                style: const TextStyle(
                  color: C.danger,
                  fontSize: _textSize,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            if (showBody)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _OutputText(bodyText, color: C.fg2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _noteCard(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, color: C.fg3, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: C.fg3, fontSize: _textSize, height: 1.35),
          ),
        ),
      ],
    ),
  );

  Widget _stepIndicator(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: C.fg3,
              fontSize: _textSize,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _errorBar(AgentThreadState state) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
          child: Text(
            state.error!,
            style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
          ),
        ),
        if (!state.sending)
          TextButton(
            onPressed: () => _thread.retry(),
            child: const Text('Повторить'),
          ),
      ],
    ),
  );

  Widget _contextBorder(AgentThreadState state) {
    final percent = state.session?.contextPercent ?? 0;

    return LinearProgressIndicator(
      value: (percent / 100).clamp(0.0, 1.0),
      minHeight: 3,
      backgroundColor: C.surface3,
      stopIndicatorRadius: 0,
      valueColor: AlwaysStoppedAnimation(
        percent >= 85 ? C.danger : (percent >= 65 ? C.warn : C.accent),
      ),
    );
  }

  Widget _detailsPanel(AgentThreadState state) {
    final session = state.session!;
    final rows = <(String, String)>[
      ('Идентификатор', session.id),
      ('Проект', session.path),
      ('Харнесс', session.harnessName.isEmpty ? 'pi' : session.harnessName),
      ('Модель', session.modelLabel),
      ('Где считает', session.whereLabel),
      if (session.harness == 'claude')
        (
          'Усилие',
          session.effort.isEmpty
              ? 'как решает Claude Code'
              : agentEffortLabel(session.effort),
        )
      else if (session.thinkingLevel.isNotEmpty)
        ('Размышления', session.thinkingLevel),
      (
        'Начата',
        session.startedAt == null
            ? '—'
            : fullDate(session.startedAt!.toLocal()),
      ),
      (
        'Последняя активность',
        session.updatedAt == null
            ? '—'
            : fullDate(session.updatedAt!.toLocal()),
      ),
      if (state.runStartedAt != null && state.sending)
        ('Текущий прогон', 'идёт ${_elapsed(state.runStartedAt)}'),
      (
        'Сообщений',
        '${_num(session.messages)} (вопросов ${_num(session.userMessages)}, '
            'ответов ${_num(session.assistantMessages)})',
      ),
      ('Вызовов инструментов', _num(session.toolCalls)),
      if (session.cost > 0) ('Стоимость', session.cost.toStringAsFixed(4)),
      if (session.sessionFile.isNotEmpty) ('Файл на маке', session.sessionFile),
    ];

    return Container(
      width: double.infinity,
      color: C.surface2,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Сведения о сессии',
            style: TextStyle(color: C.fg2, fontSize: 12),
          ),
          const SizedBox(height: 6),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      label,
                      style: const TextStyle(color: C.fg3, fontSize: 11.5),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: const TextStyle(
                        color: C.fg2,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _composer(AgentThreadState state) => Container(
    color: C.canvas,
    padding: EdgeInsets.only(bottom: navBarInset(context)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _contextBorder(state),
        Stack(
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
                const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
                const SingleActivator(LogicalKeyboardKey.enter, alt: true): _send,
              },
              child: TextField(
                controller: _input,
                enabled: true,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: C.fg, fontSize: 15),
                decoration: InputDecoration(
                  hintText: state.sending
                      ? 'Дописать — уйдёт в очередь'
                      : 'Что сделать в проекте?',
                  hintStyle: const TextStyle(color: C.fg3, fontSize: 15),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(14, 10, 52, 10),
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 2,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _input,
                builder: (context, value, _) => _transcribing
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _recording
                    ? IconButton(
                        tooltip: 'Остановить запись',
                        onPressed: _stopRecordingAndTranscribe,
                        icon: const Icon(
                          Icons.stop_circle_outlined,
                          color: C.danger,
                          size: 32,
                        ),
                      )
                    : value.text.trim().isEmpty
                    ? IconButton(
                        tooltip: 'Голосовой ввод',
                        onPressed: _startRecording,
                        icon: const Icon(Icons.mic_none, size: 28, color: C.fg3),
                      )
                    : IconButton(
                        tooltip: state.sending
                            ? 'Отправить в очередь'
                            : 'Отправить',
                        onPressed: _send,
                        icon: const Icon(Icons.send, size: 28, color: C.accent),
                      ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initial = !_initialJumpDone;
      if (!initial && !_follow) return;
      if (initial) {
        if (ref.read(agentThreadProvider).loading) return;
        if (!_scroll.hasClients) {
          _retryInitialJump();
          return;
        }
      } else {
        if (!_scroll.hasClients) return;
        if (_scroll.position.isScrollingNotifier.value) return;
      }
      final bottom = _scroll.position.maxScrollExtent;
      _selfScroll = true;
      _scroll.jumpTo(bottom);
      _selfScroll = false;
      if (!initial) return;
      _retryInitialJump(
        atBottom: _scroll.position.pixels >= bottom - 1,
        stable: bottom == _initialJumpExtent,
        extent: bottom,
      );
    });
  }

  void _retryInitialJump({
    bool atBottom = false,
    bool stable = false,
    double? extent,
  }) {
    _initialJumpExtent = extent ?? _initialJumpExtent;
    _initialJumpTries++;
    if (_initialJumpTries < _maxInitialJumpTries && (!atBottom || !stable)) {
      _scrollToBottomSoon();
      return;
    }
    _initialJumpDone = true;
    _follow = true;
  }

  String _elapsed(DateTime? startedAt) {
    if (startedAt == null) return '';
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    if (seconds < 0) return '';
    if (seconds < 60) return '$seconds с';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes мин $rest с';
  }

  String _num(int value) {
    final text = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}

class _Entry {
  final _EntryKind kind;

  final String text;

  final AgentTool? tool;

  final String command;

  final int? exitCode;

  final String error;

  final bool streaming;

  const _Entry(
    this.kind, {
    this.text = '',
    this.tool,
    this.command = '',
    this.exitCode,
    this.error = '',
    this.streaming = false,
  });

  String get copyText => switch (kind) {
    _EntryKind.tool => [
      tool?.summary ?? '',
      tool?.output ?? '',
    ].where((s) => s.trim().isNotEmpty).join('\n'),
    _EntryKind.bash => ['\$ $command', text]
        .where((s) => s.trim().isNotEmpty)
        .join('\n'),
    _ => text,
  };

  _Entry copyWith({String? error, bool? streaming, int? exitCode}) => _Entry(
    kind,
    text: text,
    tool: tool,
    command: command,
    exitCode: exitCode ?? this.exitCode,
    error: error ?? this.error,
    streaming: streaming ?? this.streaming,
  );
}

enum _EntryKind { user, text, reasoning, tool, bash, note, waiting, step }

const _maxInitialJumpTries = 40;

String _compactLines(String text) {
  var result = text
      .replaceAll(RegExp(r'^#{1,6}\s+'), '#')
      .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
      .replaceAll(RegExp(r'\*(.+?)\*'), r'$1')
      .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')
      .replaceAll(RegExp(r'^[-*]\s+'), '')
      .replaceAll(RegExp(r'^>\s?'), '')
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .join('\n')
      .trim();
  return result;
}

const _textSize = 14.0;

const _messageGapV = 6.0;

class _OutputText extends StatefulWidget {
  final String text;

  final Color color;

  const _OutputText(this.text, {this.color = C.fg3});

  @override
  State<_OutputText> createState() => _OutputTextState();
}

class _OutputTextState extends State<_OutputText> {
  String _compact = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(_OutputText old) {
    super.didUpdateWidget(old);
    if (!identical(old.text, widget.text)) _refresh();
  }

  void _refresh() {
    _compact = _compactLines(widget.text);
  }

  @override
  Widget build(BuildContext context) => SelectableText(
    _compact,
    style: TextStyle(color: widget.color, fontSize: _textSize, height: 1.35),
  );
}
