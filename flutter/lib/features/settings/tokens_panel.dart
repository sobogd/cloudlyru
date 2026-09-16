import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Панель приложений с доступом к облаку: список выпущенных app-токенов.
///
/// Панель только читает список (`GET /auth/tokens` — ручка веб-сессии, клиент ходит по cookie):
/// по нему видно, какие устройства и приложения (WebDAV, Finder) имеют доступ к облаку и когда
/// ими пользовались в последний раз. Выпуска и отзыва токенов в приложении нет, и панель этого
/// не обещает: она показывает ровно то, что сервер отдаёт на чтение.
class TokensPanel extends ConsumerStatefulWidget {
  const TokensPanel({super.key});

  @override
  ConsumerState<TokensPanel> createState() => _TokensPanelState();
}

/// Состояние панели токенов: прочитанный список.
class _TokensPanelState extends ConsumerState<TokensPanel> {
  List<ApiTokenRow> _tokens = const [];

  @override
  /// Открытие панели: сразу читаем токены.
  void initState() {
    super.initState();
    _load();
  }

  /// Читает список токенов.
  ///
  /// Ошибку глотаем: панель показывает «токенов нет» — для пользователя это то же самое,
  /// что и пустой список, а разбираться с ошибкой тут негде.
  Future<void> _load() async {
    try {
      final t = await ref.read(appStateProvider).api.listTokens();
      if (mounted) setState(() => _tokens = t);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Приложения (WebDAV/Finder)',
              style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_tokens.isEmpty)
            const Text('Токенов нет', style: TextStyle(color: C.fg3, fontSize: 13))
          else
            ..._tokens.map((t) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.key_outlined, color: C.fg3),
                  title: Text(t.label, style: const TextStyle(color: C.fg, fontSize: 14)),
                  subtitle: Text(
                    t.lastUsedAt == null ? 'не использовался' : 'последний раз: ${fmtLocal(t.lastUsedAt) ?? t.lastUsedAt!}',
                    style: const TextStyle(color: C.fg3, fontSize: 12),
                  ),
                )),
        ],
      ),
    );
  }
}
