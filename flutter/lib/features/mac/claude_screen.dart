import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Экран «Claude»: состояние Claude Code (tangem) на маке и вход заново.
///
/// Вход двухшаговый, как в веб-панели: запрос выдаёт authorize URL, человек открывает его в
/// браузере и авторизуется, затем вставляет код обратно. Сам URL и код живут на маке; приложение
/// их только показывает и передаёт — токенов у себя не хранит.
class ClaudeScreen extends ConsumerStatefulWidget {
  /// Экран статуса и входа Claude.
  const ClaudeScreen({super.key});

  @override
  ConsumerState<ClaudeScreen> createState() => _ClaudeScreenState();
}

/// Состояние экрана: снимок `/mac/claude`, поле кода и признаки занятости.
class _ClaudeScreenState extends ConsumerState<ClaudeScreen> {
  /// Снимок статуса; `null` — ответа ещё не было.
  Map<String, dynamic>? _st;

  /// Текст последней неудачи.
  String? _err;

  /// Идёт запрос (вход/отправка кода) — кнопки блокируются.
  bool _busy = false;

  /// Введённый код авторизации.
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Перечитывает статус Claude.
  Future<void> _load() async {
    try {
      final s = await ref.read(appStateProvider).api.macClaude();
      if (!mounted) return;
      setState(() {
        _st = s;
        _err = null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  /// Начинает вход: панель запускает `claude auth login` и возвращает authorize URL.
  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.macClaudeLogin();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Завершает вход: отправляет скопированный код.
  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.macClaudeCode(code);
      _code.clear();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _st;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude'),
        actions: [
          IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _err != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Мак недоступен: $_err')))
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _statusCard(s),
                    if (!(s['loggedIn'] == true) || (s['url'] ?? '') != '') _loginCard(s),
                  ],
                ),
    );
  }

  /// Карточка текущего состояния агента и авторизации.
  Widget _statusCard(Map<String, dynamic> s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Состояние', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _kv('Агент', s['agentRunning'] == true ? 'running (pid ${s['agentPid'] ?? '-'})' : 'stopped'),
            _kv('Авторизован', s['loggedIn'] == true ? 'да' : 'нет'),
            _kv('Способ', '${s['authMethod'] ?? '—'}'),
            if ((s['email'] ?? '') != '') _kv('Аккаунт', '${s['email']}'),
            if ((s['dir'] ?? '') != '') _kv('Каталог', '${s['dir']}'),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton(onPressed: _busy ? null : _start, child: const Text('Войти заново')),
            ]),
          ],
        ),
      ),
    );
  }

  /// Карточка шага авторизации: URL для браузера и поле кода.
  Widget _loginCard(Map<String, dynamic> s) {
    final url = '${s['url'] ?? ''}';
    final logs = (s['logTail'] is List) ? (s['logTail'] as List) : const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Вход', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (url.isEmpty)
              Text(s['loginRunning'] == true ? 'Запускаю вход…' : 'Нажми «Войти заново», чтобы получить ссылку.')
            else ...[
              const Text('1. Открой ссылку и авторизуйся:'),
              const SizedBox(height: 4),
              SelectableText(url, style: const TextStyle(fontSize: 12, color: Colors.blue)),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ссылка скопирована')));
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Скопировать ссылку'),
              ),
              const SizedBox(height: 8),
              const Text('2. Вставь код и отправь:'),
              TextField(
                controller: _code,
                decoration: const InputDecoration(hintText: 'код…'),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _busy ? null : _submit, child: const Text('Отправить код')),
            ],
            if (logs.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Лог', style: Theme.of(context).textTheme.bodySmall),
              for (final l in logs)
                Text('$l', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  /// Строка «ключ — значение».
  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 110, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(v)),
        ]),
      );
}
