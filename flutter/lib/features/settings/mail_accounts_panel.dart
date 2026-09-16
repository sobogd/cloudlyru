import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Панель почтовых аккаунтов: адреса, счётчики папок и состояние последней проверки.
///
/// Аккаунты настраиваются только в веб-клиенте (там же и пароли), здесь видно их состояние
/// и есть кнопка «Проверить» — она просит сервер пройтись по IMAP прямо сейчас, не дожидаясь
/// IDLE или расписания. Панель обновляется по таймеру, потому что синхронизация идёт в фоне
/// и её ход иначе не увидеть.
class MailAccountsPanel extends ConsumerStatefulWidget {
  const MailAccountsPanel({super.key});

  @override
  ConsumerState<MailAccountsPanel> createState() => _MailAccountsPanelState();
}

/// Состояние панели: список аккаунтов и таймер обновления.
class _MailAccountsPanelState extends ConsumerState<MailAccountsPanel> {
  List<MailAccountRow> _rows = const [];
  /// Опрос состояния аккаунтов.
  Timer? _timer;

  @override
  /// Первый снимок аккаунтов и запуск опроса.
  void initState() {
    super.initState();
    _load();
    // Раз в 10 секунд — реже, чем очередь превью: письма приходят минутами, а не секундами,
    // и обновлять быстрее нечего.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  /// Уходим с экрана — опрос аккаунтов снимаем.
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Читает аккаунты и их состояние.
  ///
  /// Ошибку глотаем: панель показывает то, что уже было, — разовый сбой опроса не повод
  /// оставить пользователя без списка ящиков.
  Future<void> _load() async {
    try {
      final r = await ref.read(appStateProvider).api.mailAccounts();
      if (mounted) setState(() => _rows = r);
    } catch (_) {}
  }

  /// Просит сервер пройтись по ящикам прямо сейчас.
  ///
  /// Сервер отвечает сразу, а сам разбор ящиков идёт в фоне: поэтому сообщение говорит
  /// «запущена», а не «проверено», и результат появится в строке аккаунта после ближайшего
  /// опроса.
  ///
  /// Сообщение собирается до проверки `mounted` намеренно: пока шёл запрос, панель могли
  /// закрыть (настройки — обычная вкладка), и обращение к `context` после этого было бы
  /// ошибкой. Побочно: подсказка внизу экрана.
  Future<void> _checkMail() async {
    String message;
    try {
      await ref.read(appStateProvider).api.mailSync();
      message = 'Проверка запущена';
    } catch (e) {
      message = e.toString();
    }
    if (!mounted) return;
    snack(context, message);
  }

  /// Человеческое описание состояния аккаунта: выключен, идёт приём писем, ошибка,
  /// «ещё не проверялся» или время последней проверки.
  ///
  /// Порядок проверок важен: у включённого аккаунта состояние важнее даты, а `statusError`
  /// показывается вместо общего «ошибка», если сервер прислал текст.
  String _status(MailAccountRow r) {
    if (!r.enabled) return 'выключен';
    if (r.status == 'syncing') return 'забираем письма…';
    if (r.status == 'error') return r.statusError ?? 'ошибка';
    if (r.lastSyncAt == null) return 'ещё не проверялся';
    return 'проверен ${fmtLocal(r.lastSyncAt) ?? r.lastSyncAt!}';
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Почта', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(onPressed: _checkMail, child: const Text('Проверить')),
            ],
          ),
          ..._rows.map((r) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline, color: C.fg3),
                title: Text(r.email, style: const TextStyle(color: C.fg, fontSize: 14)),
                subtitle: Text('${r.counts.inbox} вх · ${r.counts.sent} исх · ${_status(r)}',
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
              )),
        ],
      ),
    );
  }
}
