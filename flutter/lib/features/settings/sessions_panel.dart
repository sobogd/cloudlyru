import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';

/// Панель сеансов: закрыть все входы в аккаунт, кроме этого устройства.
///
/// Зачем она нужна. Вход в приложении, вход в браузере и вход на другом телефоне — это разные
/// сессии: у каждой своя cookie, и живут они до 30 дней независимо друг от друга. До этой панели
/// погасить чужой вход было нечем: «Выйти» закрывал только свой, а все прочие сессии гасились
/// лишь попутно — при смене пароля. Теперь убрать чужие входы можно отдельным действием, не
/// меняя пароль, — на случай потерянного телефона или чужого браузера.
///
/// Чего панель не делает: не трогает app-токены устройств (WebDAV, Finder, сама синхронизация —
/// она ходит именно токеном, а не сессией). Их видно и отзывают в другой панели — «Приложения»
/// (см. `tokens_panel.dart`), и обещать здесь «выход со всех устройств» было бы неправдой.
class SessionsPanel extends ConsumerStatefulWidget {
  const SessionsPanel({super.key});

  @override
  ConsumerState<SessionsPanel> createState() => _SessionsPanelState();
}

/// Состояние панели: идёт ли запрос на отзыв.
class _SessionsPanelState extends ConsumerState<SessionsPanel> {
  /// Запрос уже уходит: кнопка выключена, чтобы не отправить его второй раз.
  bool _busy = false;

  /// Спрашивает подтверждение и гасит все прочие сессии.
  ///
  /// Подтверждение здесь обязательно, и кнопка в диалоге красная: действие необратимо с другой
  /// стороны — на закрытых устройствах придётся входить заново, и «нажал случайно» стоит дорого.
  /// Число погашенных сессий показываем подсказкой: ноль — это «других входов не было», и это
  /// тоже ответ, который человек должен увидеть, иначе нажатие выглядит как «ничего не произошло».
  ///
  /// Побочно: подсказка и перерисовка кнопки. Ошибку показываем как есть (например, отозванная
  /// cookie отвечает 401) — разбираться с ней здесь негде.
  Future<void> _revokeOthers() async {
    if (_busy) return;
    final ok = await confirmDialog(
      context,
      'Завершить другие сеансы?',
      'Все входы, кроме этого устройства, перестанут работать — на них придётся войти заново. '
          'Приложения с токеном (WebDAV, Finder) и синхронизация это не затрагивает.',
      danger: true,
      confirmLabel: 'Завершить',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(appStateProvider).api.revokeOtherSessions();
      if (mounted) snack(context, n == 0 ? 'Других сеансов не было' : 'Завершено сеансов: $n');
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
          const Text('Сеансы', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Вход в приложении, в браузере и на другом телефоне — разные сеансы. '
            'Здесь закрываются все, кроме этого.',
            style: TextStyle(color: C.fg3, fontSize: 13),
          ),
          const SizedBox(height: 8),
          // Кнопка не «главная» (не залита акцентом) намеренно: это редкое действие, и рядом
          // с «Выйти» залитая кнопка читалась бы как обычный шаг.
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _revokeOthers,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Завершить другие сеансы'),
            ),
          ),
        ],
      ),
    );
  }
}
