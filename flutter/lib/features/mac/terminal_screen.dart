import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Экран «Терминал»: простая консоль к маку (одна строка ввода, вывод текстом).
///
/// Сессия постоянная: панель на маке держит один `bash` и отдаёт приращение вывода по смещению
/// (`/mac/term/poll`). Транспорт — опрос по HTTP, поэтому раздел работает через тот же
/// reverse-SSH туннель без WebSocket. Это полный shell на маке: доступ закрыт сессией
/// приложения, как и остальные ручки раздела.
class TerminalScreen extends ConsumerStatefulWidget {
  /// Экран терминала.
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

/// Состояние терминала: накопленный вывод, смещение и цикл опроса.
class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  /// Накопленный вывод сессии.
  final _out = StringBuffer();

  /// Смещение уже прочитанного вывода (байты).
  int _after = 0;

  /// Сессия на маке завершилась (нужен reset).
  bool _dead = false;

  /// Текст ошибки связи с маком.
  String? _err;

  /// Идёт отправка строки/сброс — блокирует кнопки.
  bool _busy = false;

  /// Периодический опрос вывода.
  Timer? _timer;

  /// Контроллер прокрутки, чтобы держать вывод у нижнего края.
  final _scroll = ScrollController();

  /// Поле ввода команды.
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Открывает (или переиспользует) сессию и запускает цикл опроса.
  Future<void> _open() async {
    try {
      await ref.read(appStateProvider).api.macTermOpen();
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _poll());
      _poll();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  /// Забирает приращение вывода.
  Future<void> _poll() async {
    try {
      final d = await ref.read(appStateProvider).api.macTermPoll(_after);
      if (!mounted) return;
      final chunk = '${d['out'] ?? ''}';
      final after = d['after'];
      setState(() {
        if (chunk.isNotEmpty) _out.write(chunk);
        if (after is int) _after = after;
        _dead = d['dead'] == true;
        _err = null;
      });
      _toBottom();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  /// Прокручивает вывод вниз после перерисовки.
  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Отправляет строку в сессию (Enter добавляет перевод строки).
  Future<void> _send() async {
    final line = _input.text;
    if (line.isEmpty || _busy) return;
    _input.clear();
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.macTermInput('$line\n');
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Отправляет SIGINT (^C), не убивая сессию.
  Future<void> _ctrlC() async {
    try {
      await ref.read(appStateProvider).api.macTermInput('\x03');
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  /// Сбрасывает сессию, начиная новую.
  Future<void> _reset() async {
    setState(() {
      _out.clear();
      _after = 0;
      _dead = false;
      _err = null;
    });
    try {
      await ref.read(appStateProvider).api.macTermReset();
      _toBottom();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Терминал Mac'),
        actions: [
          IconButton(tooltip: 'Reset', onPressed: _reset, icon: const Icon(Icons.restart_alt)),
        ],
      ),
      body: Column(
        children: [
          if (_err != null)
            Container(
              width: double.infinity,
              color: Colors.red.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(8),
              child: Text('Связь с маком: $_err', style: const TextStyle(fontSize: 12)),
            ),
          if (_dead)
            Container(
              width: double.infinity,
              color: Colors.orange.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(8),
              child: const Text('Сессия завершена — нажми Reset', style: TextStyle(fontSize: 12)),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0d1117),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                controller: _scroll,
                child: SelectableText(
                  _out.toString().isEmpty ? '(пусто)' : _out.toString(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFe6edf3)),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Ctrl+C',
                    onPressed: _ctrlC,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onSubmitted: (_) => _send(),
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(hintText: 'команда…', isDense: true),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Отправить',
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
