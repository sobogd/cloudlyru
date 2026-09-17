import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Панель аккаунта: кто вошёл, смена логина и пароля, выход и уборка чужих сеансов.
///
/// Всё, что касается входа в аккаунт, собрано в одном месте намеренно: логин и пароль меняются
/// одной формой (доказательство у них общее — текущий пароль), а «выйти» и «завершить другие
/// сеансы» — это про то же самое, про доступ к аккаунту. Раньше вход был показан строкой
/// с кнопкой «Выйти», а сменить логин или пароль из приложения было нечем вовсе: обе ручки
/// существуют на сервере, но кнопки к ним не было.
///
/// Чего панель не делает: не трогает app-токены устройств (WebDAV, Finder, синхронизация —
/// она ходит именно токеном). Их видно и отзывают в панели «Приложения» (см. `tokens_panel.dart`),
/// и обещать здесь «выход со всех устройств» было бы неправдой.
class AccountPanel extends ConsumerStatefulWidget {
  const AccountPanel({super.key});

  @override
  ConsumerState<AccountPanel> createState() => _AccountPanelState();
}

/// Состояние панели: список входов и признак идущего запроса.
class _AccountPanelState extends ConsumerState<AccountPanel> {
  /// Запрос уже уходит: кнопки выключены, чтобы не отправить его второй раз.
  bool _busy = false;

  /// Живые входы в аккаунт: их читает и перечитывает сервер (`GET /auth/sessions`).
  List<AuthSessionRow> _sessions = const [];

  /// Список входов не прочитался: показать это надо — иначе пустая панель читается как
  /// «других входов нет», хотя на самом деле их просто не спросили.
  String? _sessionsError;

  @override
  /// Открытие панели: читаем список входов.
  void initState() {
    super.initState();
    unawaited(_loadSessions());
  }

  /// Читает список живых сеансов.
  ///
  /// Побочно: заполняет [_sessions] или [_sessionsError] и перерисовывает панель. Ошибку не
  /// глотаем и не бросаем: панель показывает её текстом, остальное на экране работает.
  Future<void> _loadSessions() async {
    try {
      final list = await ref.read(appStateProvider).api.listSessions();
      if (mounted) {
        setState(() {
          _sessions = list;
          _sessionsError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _sessionsError = e.toString());
    }
  }

  /// Завершает один сеанс — кнопка рядом с конкретным входом.
  ///
  /// Подтверждение: завершение мгновенное, и на том устройстве придётся входить заново.
  /// Свой текущий сеанс сервер завершать откажется — рядом с ним кнопки и нет, там подпись
  /// «это устройство»: для выхода из него служит «Выйти».
  Future<void> _revokeSession(AuthSessionRow row) async {
    if (_busy) return;
    final ok = await confirmDialog(
      context,
      'Завершить этот вход?',
      'Устройство или браузер, из которого сделан этот вход, потеряет доступ и попросит '
          'войти заново.',
      danger: true,
      confirmLabel: 'Завершить',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.revokeSession(row.id);
      await _loadSessions();
      if (mounted) snack(context, 'Вход завершён');
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Открывает форму смены логина и пароля и применяет то, что вернула форма.
  ///
  /// Форма возвращает `null`, если её закрыли, — тогда ничего не происходит. Текущий пароль
  /// берётся из формы, а не отсюда: приложение его не хранит и хранить не должно.
  ///
  /// После успеха логин перечитывается через `/auth/me` (он показан в этой же панели), и в
  /// подсказке сообщается, сколько прочих сеансов погашено: смена пароля гасит их на сервере,
  /// и человек должен знать, что на других устройствах вход пропал.
  Future<void> _editCredentials() async {
    if (_busy) return;
    final result = await showDialog<_Credentials>(
      context: context,
      builder: (_) => _CredentialsDialog(login: ref.read(appStateProvider).user?.login ?? ''),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final out = await ref.read(appStateProvider).api.changeCredentials(
            currentPassword: result.currentPassword,
            login: result.login,
            newPassword: result.newPassword,
          );
      await ref.read(appStateProvider).reloadUser();
      if (!mounted) return;
      snack(
        context,
        out.sessionsRevoked > 0
            ? 'Сохранено. Завершено других сеансов: ${out.sessionsRevoked}'
            : 'Сохранено',
      );
    } catch (e) {
      // Текст ошибки показываем как есть: сервер объясняет и неверный текущий пароль, и занятый
      // логин, и слишком короткий новый пароль — разбираться с этим на экране негде.
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Логин и адрес сервера читаются из состояния: их обновляет `AppState` (после входа,
    // выхода и смены логина), и вторая копия правды здесь не нужна.
    final state = ref.watch(appStateProvider);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, color: C.fg3),
              const SizedBox(width: 8),
              Text(state.user?.login ?? '',
                  style: const TextStyle(color: C.fg, fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: C.danger),
                // Выход из аккаунта: `AppState` сам гасит синхронизацию и чистит сессию,
                // ждать тут нечего — ни подсказки, ни перехода экран не делает.
                onPressed: () => ref.read(appStateProvider).logout(),
                child: const Text('Выйти'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Адрес сервера — только для чтения: в приложении он не меняется, поле ввода
          // живёт на экране входа (см. `features/auth/login_screen.dart`).
          Text(state.settings.serverUrl, style: const TextStyle(color: C.fg3, fontSize: 12)),
          const SizedBox(height: 12),
          // Кнопка не залита акцентом: это редкое действие, и рядом с «Выйти» залитая кнопка
          // читалась бы как обычный шаг работы с экраном.
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _editCredentials,
              icon: const Icon(Icons.badge_outlined, size: 18),
              label: const Text('Сменить логин или пароль'),
            ),
          ),
          const SizedBox(height: 14),
          const Text('Входы в аккаунт', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Каждый вход — отдельный сеанс: телефон, браузер на компьютере, второе приложение. '
            'Завершать их можно по одному, тот, из которого вы смотрите, помечен как «это устройство».',
            style: TextStyle(color: C.fg3, fontSize: 13),
          ),
          const SizedBox(height: 6),
          if (_sessionsError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(_sessionsError!, style: const TextStyle(color: C.danger, fontSize: 13)),
            )
          else
            ..._sessions.map((s) => _sessionTile(s)),
        ],
      ),
    );
  }

  /// Строка одного входа: кто, откуда и когда — и кнопка «завершить» рядом с ней.
  ///
  /// У текущего входа кнопки нет намеренно: завершить себя этой ручкой сервер не даст, для
  /// этого есть «Выйти» — он делает то же самое и ещё чистит cookie и локальные данные.
  Widget _sessionTile(AuthSessionRow s) {
    final when = s.createdAt == null ? '' : (fmtLocal(s.createdAt) ?? s.createdAt!);
    final where = s.ip == null || s.ip!.isEmpty ? '' : ' · ${s.ip}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(s.current ? Icons.smartphone : Icons.devices_other, color: s.current ? C.accent : C.fg3),
      title: Text(
        s.client ?? _clientFromUserAgent(s.userAgent) ?? 'Неизвестный вход',
        style: const TextStyle(color: C.fg, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        when.isEmpty ? 'время входа неизвестно$where' : 'вход: $when$where',
        style: const TextStyle(color: C.fg3, fontSize: 12),
        maxLines: 2,
      ),
      trailing: s.current
          ? const Text('это устройство', style: TextStyle(color: C.accent, fontSize: 12))
          : IconButton(
              tooltip: 'Завершить этот вход',
              onPressed: _busy ? null : () => _revokeSession(s),
              icon: const Icon(Icons.logout, color: C.danger),
            ),
    );
  }

  /// Название клиента из `User-Agent`, когда метки нет: у входов, сделанных до того, как
  /// приложение начало представляться, это единственная зацепка. Возвращает `null`, если
  /// и по заголовку ничего не понять — тогда строка называется «Неизвестный вход».
  static String? _clientFromUserAgent(String? ua) {
    final s = ua?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.startsWith('Dio/')) return 'Приложение Cloudly';
    return s.length <= 40 ? s : '${s.substring(0, 40)}…';
  }
}

/// Что вернула форма смены данных: текущий пароль (доказательство) и то, что меняется.
///
/// Отдельный тип, а не три значения подряд: у полей разный смысл (`currentPassword` обязателен
/// всегда, остальные могут быть пустыми — «не менять»), и перепутать их местами было бы легко.
class _Credentials {
  /// Текущий пароль: им подтверждается право менять данные аккаунта.
  final String currentPassword;
  /// Новый логин; пустая строка — оставить прежний.
  final String login;
  /// Новый пароль; пустая строка — оставить прежний.
  final String newPassword;

  const _Credentials({
    required this.currentPassword,
    required this.login,
    required this.newPassword,
  });
}

/// Форма смены логина и пароля.
///
/// Поля необязательны намеренно (кроме текущего пароля): пустое поле значит «не менять», поэтому
/// одной формой закрываются и смена логина, и смена пароля, и обе сразу. Повтор нового пароля
/// проверяется здесь, а не на сервере: сервер повтор не присылают, а опечатка в новом пароле
/// означала бы, что войти заново уже нечем.
///
/// Контроллеры живут ровно столько, сколько живёт диалог, и освобождаются в [dispose]: после
/// `showDialog` поле ещё существует во время обратной анимации закрытия маршрута, и освобождение
/// сразу после вызова грозило бы «A TextEditingController was used after being disposed».
class _CredentialsDialog extends StatefulWidget {
  /// Текущий логин — подставляется в поле, чтобы его было видно и можно было поправить,
  /// а не набирать с нуля.
  final String login;

  const _CredentialsDialog({required this.login});

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

/// Состояние формы: поля и текст последней ошибки проверки.
class _CredentialsDialogState extends State<_CredentialsDialog> {
  late final TextEditingController _login = TextEditingController(text: widget.login);
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  /// Текст ошибки проверки; `null` — проверка пройдена (или ещё не запускалась).
  String? _error;

  /// Минимум для нового пароля — тот же, что на сервере (`MIN_PASSWORD_LEN`).
  ///
  /// Проверяем и здесь, хотя сервер откажет сам: отказ прилетел бы подсказкой поверх формы,
  /// то есть после закрытия диалога, — и человек потерял бы уже набранные поля.
  static const _minPassword = 12;
  /// Минимум для логина — тоже серверный (`MIN_LOGIN_LEN`).
  static const _minLogin = 3;

  @override
  void dispose() {
    _login.dispose();
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  /// Проверяет заполненное и закрывает форму, если всё в порядке.
  ///
  /// Ничего не меняющее заполнение (логин тот же, пароль пуст) считается ошибкой: иначе кнопка
  /// отправила бы запрос, на который сервер ответит «нечего менять».
  void _submit() {
    final login = _login.text.trim();
    final next = _next.text;
    if (_current.text.isEmpty) {
      setState(() => _error = 'введите текущий пароль');
      return;
    }
    if (login.isNotEmpty && login.length < _minLogin) {
      setState(() => _error = 'логин короче $_minLogin символов');
      return;
    }
    if (next.isNotEmpty && next.length < _minPassword) {
      setState(() => _error = 'новый пароль короче $_minPassword символов');
      return;
    }
    if (next.isNotEmpty && next != _repeat.text) {
      setState(() => _error = 'новый пароль и повтор не совпадают');
      return;
    }
    if ((login.isEmpty || login == widget.login) && next.isEmpty) {
      setState(() => _error = 'менять нечего: логин прежний, новый пароль не задан');
      return;
    }
    Navigator.pop(
      context,
      _Credentials(
        currentPassword: _current.text,
        // Прежний логин отправлять незачем: сервер и так не меняет то, что совпадает.
        login: login == widget.login ? '' : login,
        newPassword: next,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Логин и пароль'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _login,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'логин'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'текущий пароль'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'новый пароль',
              hintText: 'оставьте пустым, чтобы не менять',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _repeat,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'повторите новый пароль'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!, style: const TextStyle(color: C.danger, fontSize: 13)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
