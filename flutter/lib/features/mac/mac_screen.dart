import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'claude_screen.dart';
import 'env_screen.dart';
import 'github_actions_screen.dart';
import 'terminal_screen.dart';

/// Экран раздела «Mac»: состояние домашнего MacBook и базовое управление.
///
/// Данные приходят не с мака напрямую, а через бэкенд Cloudly (`/mac/*`): сервер сам ходит к
/// панели мака по reverse-SSH туннелю. Поэтому приложение ни адреса туннеля, ни порта не знает,
/// а «мак недоступен» — это не сбой раздела, а состояние (мак спит или туннель отключился).
///
/// Экран читает снимок состояния и показывает его карточками; действия (WARP, reboot, sleep и
/// т. д.) отправляются отдельными запросами и после ответа состояние перечитывается целиком —
/// так панель остаётся единственным источником правды о маке.
class MacScreen extends ConsumerStatefulWidget {
  /// Экран раздела «Mac».
  const MacScreen({super.key});

  @override
  ConsumerState<MacScreen> createState() => _MacScreenState();
}

/// Состояние экрана: снимок статуса, ошибка загрузки и признаки «идёт запрос/действие».
class _MacScreenState extends ConsumerState<MacScreen> {
  /// Снимок `/mac/status`; `null` — ответа ещё не было (показывается спиннер).
  Map<String, dynamic>? _status;

  /// Снимок `/mac/models` — доступные и текущая LLM-модель.
  Map<String, dynamic>? _models;

  /// Текст последней неудачи: заменяет карточки, потому что показывать устаревший статус хуже,
  /// чем честно сказать, что мак не ответил.
  String? _error;

  /// Идёт загрузка/перечитывание статуса (защита от гонки двух запросов).
  bool _loading = false;

  /// Идёт действие/WARP-переключение/смена модели: блокирует кнопки.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadModels();
  }

  /// Перечитывает снимок состояния.
  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final s = await ref.read(appStateProvider).api.macStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Перечитывает снимок моделей.
  Future<void> _loadModels() async {
    try {
      final m = await ref.read(appStateProvider).api.macModels();
      if (!mounted) return;
      setState(() => _models = m);
    } catch (e) {
      // non-critical — just won't show the model switcher
    }
  }

  /// Отправляет действие над маком, спросив подтверждение (действия необратимы/рвут сеть).
  Future<void> _action(String action, String title) async {
    final ok = await _confirm(title, 'Действие выполнится на MacBook.');
    if (ok != true) return;
    await _run(() => ref.read(appStateProvider).api.macAction(action));
  }

  /// Переключает WARP; подтверждения нет — операция безопасна и обратима.
  Future<void> _warp(String op) async {
    await _run(() => ref.read(appStateProvider).api.macWarp(op));
  }

  /// Переключает LLM-модель; подтверждение не нужно — операция обратима.
  Future<void> _switchModel(String modelId, String modelName) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.macModelSwitch(modelId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Switching to $modelName…')));
        await _loadModels();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Общая обёртка действия: блокирует кнопки, перечитывает состояние, показывает ошибку.
  Future<void> _run(Future<Map<String, dynamic>> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  /// Диалог подтверждения опасного действия.
  Future<bool?> _confirm(String title, String text) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Выполнить')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MacBook'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// Тело экрана: спиннер / ошибка / карточки состояния.
  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.laptop_mac, size: 40),
              const SizedBox(height: 12),
              Text('Мак недоступен', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    final s = _status;
    if (s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _systemCard(s),
          _warpCard(s),
          _modelCard(),
          _actionsCard(),
          _linksCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Карточка системного состояния: хост, uptime, CPU/RAM, диски, батарея, сеть.
  Widget _systemCard(Map<String, dynamic> s) {
    final cpu = _map(s['cpu']);
    final mem = _map(s['mem']);
    final net = _map(s['net']);
    final batt = _map(s['battery']);
    final disks = (s['disk'] is List) ? (s['disk'] as List) : const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_str(s['host']) ?? 'Mac',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _kv('Uptime', _str(s['uptime']) ?? '—'),
            _kv('CPU busy', _fmtPct(cpu['busy'])),
            _kv('Load', '${_fmtN(cpu['load1'])}  ${_fmtN(cpu['load5'])}  ${_fmtN(cpu['load15'])}'),
            _kv('RAM', '${_fmtN(mem['used_gb'])} / ${_fmtN(mem['total_gb'])} GB (${_fmtPct(mem['used_pct'])})'),
            _kv('IP', '${_str(net['ip']) ?? '—'} (${_str(net['iface']) ?? '—'})'),
            if (s['public_ip'] != null) _kv('Public IP', '${s['public_ip']}'),
            if (batt['present'] == true)
              _kv('Battery', '${_fmtPct(batt['percent'])} · ${_str(batt['state']) ?? ''} ${_str(batt['source']) ?? ''}'),
            const SizedBox(height: 8),
            for (final d in disks) _diskRow(_map(d)),
          ],
        ),
      ),
    );
  }

  /// Строка одного диска: точка монтирования и занято/всего.
  Widget _diskRow(Map<String, dynamic> d) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text('${_str(d['mount']) ?? '?'}: ${d['used_gb']} / ${d['size_gb']} GB (${_str(d['pct']) ?? '?'})',
            style: Theme.of(context).textTheme.bodySmall),
      );

  /// Карточка WARP (корпоративный Cloudflare One) с кнопками управления.
  Widget _warpCard(Map<String, dynamic> s) {
    final w = _map(s['warp']);
    final state = _str(w['state']) ?? 'unknown';
    final connected = state.toLowerCase() == 'connected';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WARP · Cloudflare One', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _kv('Состояние', state),
            if (_str(w['org']) != null) _kv('Организация', _str(w['org'])!),
            if ((_str(w['reason']) ?? '').isNotEmpty) _kv('Причина', _str(w['reason'])!),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy || connected ? null : () => _warp('connect'),
                  child: const Text('Connect'),
                ),
                OutlinedButton(
                  onPressed: _busy || !connected ? null : () => _warp('disconnect'),
                  child: const Text('Disconnect'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _warp('reconnect'),
                  child: const Text('Reconnect'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Карточка локальных LLM-моделей (oMLX): текущая модель и кнопки переключения.
  Widget _modelCard() {
    final m = _models;
    if (m == null) return const SizedBox.shrink();
    final current = _str(m['current']);
    final modelList = (m['models'] as Map<String, dynamic>? ?? {});
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LLM · oMLX', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Текущая: ${current ?? 'не загружена'}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final entry in modelList.entries)
              _modelSwitchTile(entry.key, entry.value, current),
          ],
        ),
      ),
    );
  }

  /// Кнопка переключения на одну модель.
  Widget _modelSwitchTile(String id, Map<String, dynamic> info, String? current) {
    final isActive = id == current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${info['name'] ?? id} (${info['quantization'] ?? ''})',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isActive ? null : Colors.grey,
                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
          FilledButton.tonal(
            onPressed: _busy || isActive ? null : () => _switchModel(id, '${info['name'] ?? id}'),
            child: Text(isActive ? 'Active' : 'Switch'),
          ),
        ],
      ),
    );
  }

  /// Карточка действий над маком. Опасные — через подтверждение.
  Widget _actionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Действия', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _action('restart-tunnel', 'Перезапустить туннель?'),
                  child: const Text('Restart tunnel'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _action('firewall-on', 'Включить firewall?'),
                  child: const Text('Firewall ON'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _action('sleep-off', 'Запретить сон MacBook?'),
                  child: const Text('Sleep OFF'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _action('sleep', 'Усыпить MacBook?'),
                  child: const Text('Sleep now'),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _action('reboot', 'Перезагрузить MacBook?'),
                  child: const Text('Reboot'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Действия выполняются на MacBook и применяются сразу.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  /// Карточка-навигация к остальным экранам раздела.
  Widget _linksCard() {
    Widget tile(IconData icon, String title, String subtitle, WidgetBuilder b) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: b)),
        );
    return Card(
      child: Column(
        children: [
          tile(Icons.smart_toy_outlined, 'Claude', 'Статус и вход', (_) => const ClaudeScreen()),
          tile(Icons.play_circle_outline, 'GitHub Actions', 'Workflow и запуск',
              (_) => const GithubActionsScreen()),
          tile(Icons.description_outlined, 'Env-файлы', 'Список и редактор .env', (_) => const EnvScreen()),
          tile(Icons.terminal, 'Терминал', 'Shell на MacBook', (_) => const TerminalScreen()),
        ],
      ),
    );
  }

  /// Строка «ключ — значение».
  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(child: Text(v)),
          ],
        ),
      );
}

/// Достаёт вложенный объект; не-объект даёт пустую карту, чтобы разбор не падал.
Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

/// Строковое поле: не-строка даёт `null`, чтобы UI показал «—».
String? _str(dynamic v) => v is String ? v : null;

/// Число с одним знаком после запятой; `null` → «—».
String _fmtN(dynamic v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return n == null ? '—' : n.toStringAsFixed(1);
}

/// Процент: добавляет «%», если значение есть.
String _fmtPct(dynamic v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return n == null ? '—' : '${n.toStringAsFixed(0)}%';
}
