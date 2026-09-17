import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Панель приложений с доступом к облаку: выпущенные app-токены и их отзыв.
///
/// Это **не сеансы** (сеансы — вошедшие приложения и браузеры, см. `account_panel.dart`), и
/// разница важна: токеном ходят WebDAV, Finder и синхронизация устройств, у него свой срок,
/// а сеанс — это cookie приложения. Завершение сеансов такой токен не гасит, и раньше панель
/// только показывала список — поэтому лишние токены копились без единого способа их убрать
/// (у владельца их набралось 26, из них 15 с одной и той же меткой ноутбука).
///
/// Теперь рядом с каждым токеном есть кнопка «Отозвать»: после неё он не проходит авторизацию
/// ни в REST, ни в WebDAV. Устройство, которому токен был нужен, выпустит себе новый при
/// следующем запуске — об этом сказано в подтверждении, потому что это и есть причина, по
/// которой отзывать чужой токен отсюда не всегда умно.
class TokensPanel extends ConsumerStatefulWidget {
  const TokensPanel({super.key});

  @override
  ConsumerState<TokensPanel> createState() => _TokensPanelState();
}

/// Состояние панели: прочитанный список и признак идущего запроса.
class _TokensPanelState extends ConsumerState<TokensPanel> {
  List<ApiTokenRow> _tokens = const [];
  /// Запрос на отзыв уже уходит: кнопки выключены, чтобы не отправить его дважды.
  bool _busy = false;

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

  /// Отзывает один токен: подтверждение, запрос, перечитка списка.
  ///
  /// Подтверждение обязательно: отзыв мгновенный и необратимый, а устройство, потерявшее токен,
  /// начнёт синхронизацию заново — и в облаке появится ещё одна папка зеркала. Ровно поэтому
  /// в диалоге сказано, что нужный токен лучше отзывать с самого устройства.
  ///
  /// Список перечитываем после успеха, а не вычёркиваем строку на месте: правда о том, что
  /// осталось, лежит на сервере, и вторая копия этого знания на экране разошлась бы с ней.
  Future<void> _revoke(ApiTokenRow token) async {
    if (_busy) return;
    final ok = await confirmDialog(
      context,
      'Отозвать доступ «${token.label}»?',
      'Это приложение или устройство потеряет доступ к облаку сразу. Если оно ещё нужно — '
          'лучше отозвать доступ с самого устройства: там токен выпустится заново сам.',
      danger: true,
      confirmLabel: 'Отозвать',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.revokeToken(token.id);
      await _load();
      if (mounted) snack(context, 'Доступ отозван: ${token.label}');
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Приложения с доступом (WebDAV/Finder)',
              style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          // Пояснение на месте: это ровно то, что выглядит как «куча непонятных сеансов»
          // с именами устройств, и путать токены с сеансами входа нельзя.
          const Text(
            'Устройства, которые ходят в облако по своему ключу: WebDAV, Finder, синхронизация '
            'телефона. Это не сеансы входа — их отзывают здесь, по одному.',
            style: TextStyle(color: C.fg3, fontSize: 13),
          ),
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
                  trailing: IconButton(
                    tooltip: 'Отозвать доступ',
                    onPressed: _busy ? null : () => _revoke(t),
                    icon: const Icon(Icons.link_off, color: C.danger),
                  ),
                )),
        ],
      ),
    );
  }
}
