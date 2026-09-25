import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../util/master_detail.dart';
import 'mac_actions_panel.dart';
import 'mac_model_panel.dart';
import 'mac_status_panel.dart';
import 'mac_warp_panel.dart';

/// Экран раздела «Mac»: состояние MacBook и базовое управление.
///
/// Использует [MasterDetail] для раскладки «список слева — детали справа», как настройки.
/// На широком экране — две колонки с перетаскиваемой границей; на телефоне — список во всю
/// ширину, панели открываются отдельным экраном.
///
/// Пункты списка (слева):
/// • Статус — системная информация (CPU/RAM/диски/сеть)
/// • WARP — Cloudflare One
/// • LLM — переключение моделей
/// • Действия — кнопки управления (reboot, sleep, firewall…)
class MacScreen extends ConsumerStatefulWidget {
  const MacScreen({super.key});

  @override
  ConsumerState<MacScreen> createState() => _MacScreenState();
}

/// Состояние экрана: снимки статуса и моделей, флаг загрузки/действия.
///
/// Вся логика (запрос, подтверждение, повтор) держится здесь — UI-панели пассивны и
/// получают данные через конструктор.
class _MacScreenState extends ConsumerState<MacScreen> {
  /// Снимок `/mac/status`; `null` — ответа ещё не было.
  Map<String, dynamic>? _status;

  /// Снимок `/mac/models` — доступные и текущая LLM-модель.
  Map<String, dynamic>? _models;

  /// Идёт загрузка статуса (защита от гонки двух запросов).
  bool _loading = false;

  /// Идёт действие/переключение: блокирует кнопки.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadModels();
  }

  /// Перечитывает снимок состояния с сервера.
  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final s = await ref.read(appStateProvider).api.macStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  /// Перечитывает снимок моделей. При ошибке молчит — просто не покажет переключатель.
  Future<void> _loadModels() async {
    try {
      final m = await ref.read(appStateProvider).api.macModels();
      if (!mounted) return;
      setState(() => _models = m);
    } catch (e) {
      // non-critical — just won't show the model switcher
    }
  }

  /// Отправляет опасное действие над маком (требует подтверждения).
  ///
  /// Делегирует показ диалога в [_confirm], после подтверждения — [api.macAction].
  Future<void> _action(String action, String title) async {
    final ok = await _confirm(title, 'Действие выполнится на MacBook.');
    if (ok != true) return;
    await _run(() => ref.read(appStateProvider).api.macAction(action));
  }

  /// Отправляет команду WARP (без подтверждения — операция безопасна и обратима).
  Future<void> _warp(String op) async {
    await _run(() => ref.read(appStateProvider).api.macWarp(op));
  }

  /// Переключает LLM-модель (без подтверждения — операция обратима).
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
    return MasterDetail(
      title: 'MacBook',
      entries: [
        MasterDetailEntry(
          id: 'status',
          title: 'Статус',
          icon: Icons.laptop_mac,
          body: _status != null
              ? MacStatusPanel(status: _status!)
              : const Center(child: CircularProgressIndicator()),
        ),
        MasterDetailEntry(
          id: 'warp',
          title: 'WARP',
          icon: Icons.cloud_outlined,
          body: MacWarpPanel(
            status: _status ?? {},
            onAction: _action,
            onWarp: _warp,
            busy: _busy,
          ),
        ),
        MasterDetailEntry(
          id: 'model',
          title: 'LLM',
          icon: Icons.smart_toy_outlined,
          body: MacModelPanel(
            models: _models,
            onSwitch: _switchModel,
            busy: _busy,
          ),
        ),
        MasterDetailEntry(
          id: 'actions',
          title: 'Действия',
          icon: Icons.gamepad,
          body: MacActionsPanel(
            onAction: _action,
            busy: _busy,
          ),
        ),
      ],
    );
  }
}
