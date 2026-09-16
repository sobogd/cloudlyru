import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/cloudly_api.dart';
import '../providers.dart';
import '../theme.dart';

/// Экран входа: единственный экран до авторизации, показывается корнем приложения, когда
/// в `AppState` ещё нет пользователя.
///
/// Экран ничего не знает про сервер: он передаёт логин и пароль в `AppState.login`, а тот сам
/// создаёт клиент, сохраняет cookie сессии и запускает синхронизацию. После успешного входа
/// пользователь появляется в состоянии, корень приложения перестраивается и подменяет этот
/// экран на `Shell` — никакой навигации отсюда не делается.
///
/// Адрес сервера правится здесь же, но спрятан под ссылкой «Адрес сервера»: по умолчанию он
/// уже верный, и поле на виду только мешало бы. Без этой возможности смена домена (или
/// переезд на свой сервер) требовала бы переустановки приложения.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

/// Состояние экрана входа: текст в полях и признак «идёт запрос».
///
/// Ошибка и занятость держатся локально, а не в `AppState`: они относятся к одному экрану и
/// должны исчезнуть вместе с ним при успешном входе.
class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();

  /// Адрес сервера: заполняется текущим значением на первом построении — оно уже прочитано
  /// из настроек на старте, а пустое поле провоцировало бы стереть адрес.
  late final TextEditingController _server =
      TextEditingController(text: ref.read(appStateProvider).settings.serverUrl);

  bool _busy = false;
  bool _showServer = false;
  String? _error;

  /// Освобождает контроллеры полей. Обязательно: они держат подписки на ввод, а экран входа
  /// уничтожается сразу после успешного входа.
  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _server.dispose();
    super.dispose();
  }

  /// Текст ошибки для показа под полями.
  ///
  /// [ApiException] несёт уже готовое сообщение (`toString` отдаёт его же). Голый
  /// [DioException] прилетает из `CloudlyApi.login`, который, в отличие от остального клиента,
  /// пока не оборачивает ошибки в [ApiException]; его `toString()` — многострочный английский
  /// дамп, и показывать такое человеку нельзя. Поэтому из него берём только понятное: ответ
  /// 401 — неверная пара логин/пароль, отсутствие ответа — сеть или неверный адрес.
  static String _errorText(Object e) {
    if (e is ApiException) return e.message;
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) return 'неверный логин или пароль';
      if (status != null) return 'сервер ответил ошибкой $status';
      return 'нет связи с сервером — проверьте адрес и подключение';
    }
    return 'не удалось войти: $e';
  }

  /// Отправляет логин и пароль на вход. Ничего не возвращает.
  ///
  /// Пароль уходит как есть, а логин — без пробелов по краям: их легко набрать копированием
  /// из письма, и сервер такой логин не узнает. Пустые поля до сервера не доходят: запрос с
  /// пустым логином — это лишняя попытка в серверном счётчике частоты.
  /// Второе нажатие кнопки во время запроса игнорируется, чтобы не создать две сессии подряд.
  ///
  /// Ошибку показывает прямо под полями — текстом сервера, без перевода: он объясняет причину
  /// точнее («неверный пароль», «слишком много попыток»). `mounted` проверяется перед каждым
  /// `setState`, потому что при успешном входе экран может быть уже выброшен из дерева, пока
  /// идёт запрос.
  Future<void> _submit() async {
    if (_busy) return;
    final login = _login.text.trim();
    final server = _server.text.trim();
    if (login.isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'нужны логин и пароль');
      return;
    }
    if (server.isEmpty) {
      setState(() => _error = 'нужен адрес сервера');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = ref.read(appStateProvider);
      // адрес применяется до входа: он берётся из настроек, а клиент под него пересобирается
      await state.useServer(server);
      await state.login(login, _password.text);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _errorText(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          // ширина ограничена, иначе на планшете поля растянулись бы во весь экран
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.cloud_outlined, size: 44, color: C.accent),
                const SizedBox(height: 12),
                const Text(
                  'CloudlyRu',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _login,
                  decoration: const InputDecoration(hintText: 'логин'),
                  // «далее» переводит фокус на пароль: так форма проходится одной клавиатурой
                  textInputAction: TextInputAction.next,
                  // логин — не слово из языка: автозамена и подсказки здесь только мешают
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  decoration: const InputDecoration(hintText: 'пароль'),
                  // пароль скрыт точками: на экране входа его не должно быть видно
                  obscureText: true,
                  // подсказки и автозамена в поле пароля только мешают вводу
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  // «готово» на клавиатуре отправляет форму — как кнопка «Войти»
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                // Адрес сервера нужен редко, поэтому ссылка, а не поле: раскрытое поле
                // выглядит обязательным и заставляет проверять его при каждом входе
                if (_showServer)
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(hintText: 'адрес сервера'),
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => setState(() => _showServer = true),
                      child: const Text('Адрес сервера', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                const SizedBox(height: 12),
                // текст сервера как есть: он точнее объясняет причину, чем любая своя подпись
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: C.danger, fontSize: 13)),
                  const SizedBox(height: 12),
                ],
                // на время запроса кнопка выключена и показывает прогресс — повторное нажатие
                // не создаст вторую сессию
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Войти'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
