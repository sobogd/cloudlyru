import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'ai_api.dart';
import 'ai_types.dart';

/// Состояние списка чатов: темы, признак загрузки и последняя ошибка.
class ChatsState {
  /// Чаты владельца, свежие сверху.
  final List<AiChat> chats;

  /// Идёт загрузка списка (для индикатора).
  final bool loading;

  /// Задан ли ключ xAI в окружении сервера.
  ///
  /// `false` означает, что раздел не заработает ни при каких действиях в приложении: ключ
  /// живёт в секретах репозитория и попадает на сервер при выкладке. Признак нужен, чтобы
  /// вместо пустого списка показать это словами.
  final bool configured;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Список чатов и состояние загрузки.
  const ChatsState({
    this.chats = const [],
    this.loading = false,
    this.configured = true,
    this.error,
  });

  /// Копия состояния; [error] по умолчанию не трогается — ошибку снимает [clearError].
  ChatsState copyWith({List<AiChat>? chats, bool? loading, bool? configured}) => ChatsState(
        chats: chats ?? this.chats,
        loading: loading ?? this.loading,
        configured: configured ?? this.configured,
        error: error,
      );

  /// Копия с проставленной ошибкой.
  ChatsState withError(String message) =>
      ChatsState(chats: chats, loading: loading, configured: configured, error: message);

  /// Копия без ошибки и без признака загрузки.
  ChatsState ready({List<AiChat>? chats, bool? configured}) => ChatsState(
        chats: chats ?? this.chats,
        loading: false,
        configured: configured ?? this.configured,
      );
}

/// Провайдер списка чатов.
final chatsProvider = NotifierProvider<ChatsController, ChatsState>(ChatsController.new);

/// Список чатов: загрузка, создание, переименование и удаление.
///
/// Список живёт в провайдере, а не в состоянии экрана, чтобы возврат из переписки не тянул его
/// заново и не мигал пустым экраном.
class ChatsController extends Notifier<ChatsState> {
  /// Клиент ручек чата поверх текущего облачного клиента (адрес и сессия — из него).
  AiApi get _api => AiApi(ref.read(appStateProvider).api);

  @override
  ChatsState build() => const ChatsState();

  /// Читает список чатов с сервера.
  ///
  /// Заодно узнаёт, задан ли на сервере ключ: без ключа список пуст не потому, что чатов нет,
  /// а потому, что раздел не настроен, и на экране это разные сообщения.
  Future<void> load() async {
    state = state.copyWith(loading: true).ready(chats: state.chats);
    try {
      final chats = await _api.chats();
      // ключ проверяем только при пустом списке: ходить за моделями на каждый показ вкладки
      // незачем, а признак нужен ровно для пустого экрана
      final configured = chats.isNotEmpty ? true : (await _api.models()).configured;
      state = state.ready(chats: chats, configured: configured);
    } on AiApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Создаёт чат и возвращает его (или `null`, если не вышло).
  ///
  /// Созданный чат сразу подставляется в начало списка: сервер сортирует чаты по времени
  /// последнего сообщения, и новый там и окажется — ждать перезагрузки списка незачем.
  ///
  /// Стиль берётся из последнего выбора человека ([UiStateStore.chatStyle]): новый разговор
  /// продолжает выбранную манеру речи, а не сбрасывается в «обычную».
  Future<AiChat?> create({String? model}) async {
    final style = ref.read(settingsProvider).ui.chatStyle;
    try {
      final chat = await _api.createChat(model: model, style: style);
      state = state.ready(chats: [chat, ...state.chats]);
      return chat;
    } on AiApiException catch (e) {
      state = state.withError(e.message);
      return null;
    }
  }

  /// Переименовывает чат (тема правится и на сервере, и в списке).
  Future<void> rename(AiChat chat, String title) async {
    try {
      final updated = await _api.patchChat(chat.id, title: title);
      state = state.ready(chats: [
        for (final c in state.chats) c.id == updated.id ? AiChat(
              id: updated.id,
              title: updated.title,
              model: updated.model,
              updatedAt: updated.updatedAt ?? c.updatedAt,
              messages: c.messages,
            ) : c,
      ]);
    } on AiApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Удаляет чат вместе с его сообщениями.
  Future<void> remove(String chatId) async {
    try {
      await _api.deleteChat(chatId);
      state = state.ready(chats: [for (final c in state.chats) if (c.id != chatId) c]);
    } on AiApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Подтягивает тему и время чата, когда переписка их изменила (сервер назвал чат по первому
  /// вопросу). Дешёвая локальная правка: полный список перечитывать ради одной строки незачем.
  void touch(String chatId, {String? title, String? model}) {
    state = state.ready(chats: [
      for (final c in state.chats)
        c.id == chatId
            ? AiChat(
                id: c.id,
                title: title ?? c.title,
                model: model ?? c.model,
                updatedAt: DateTime.now(),
                messages: c.messages,
              )
            : c,
    ]);
  }
}

/// Состояние открытой переписки.
class ChatThreadState {
  /// Чат, который открыт; пустая строка — переписка ещё не открыта.
  final String chatId;

  /// Тема чата (сервер выводит её из первого вопроса).
  final String title;

  /// Модель, которой отвечает этот чат.
  final String model;

  /// Стиль ответа чата (`AiStyle.id`).
  final String style;

  /// Модели, доступные ключу сервера, — для выбора модели в шапке.
  final List<AiModel> models;

  /// Стили ответа, доступные на сервере, — для выбора в шапке.
  final List<AiStyle> styles;

  /// Переписка в порядке отправки.
  final List<AiMessage> messages;

  /// Идёт загрузка истории.
  final bool loading;

  /// Идёт генерация ответа: кнопка отправки становится «Стоп», поле ввода закрывается.
  final bool sending;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Расход токенов на последний ответ.
  final AiUsage? usage;

  /// Модель сейчас ищет в интернете — на экране это отдельная подпись вместо «печатает».
  final bool searching;

  /// Переписка и состояние её загрузки.
  const ChatThreadState({
    this.chatId = '',
    this.title = '',
    this.model = '',
    this.style = 'normal',
    this.models = const [],
    this.styles = const [],
    this.messages = const [],
    this.loading = false,
    this.sending = false,
    this.error,
    this.usage,
    this.searching = false,
  });

  /// Копия состояния с заменёнными полями; ошибку и расход трогают только явные методы.
  ChatThreadState copyWith({
    String? title,
    String? model,
    String? style,
    List<AiModel>? models,
    List<AiStyle>? styles,
    List<AiMessage>? messages,
    bool? loading,
    bool? sending,
    AiUsage? usage,
    bool? searching,
  }) =>
      ChatThreadState(
        chatId: chatId,
        title: title ?? this.title,
        model: model ?? this.model,
        style: style ?? this.style,
        models: models ?? this.models,
        styles: styles ?? this.styles,
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        sending: sending ?? this.sending,
        error: error,
        usage: usage ?? this.usage,
        searching: searching ?? this.searching,
      );

  /// Копия с проставленной ошибкой.
  ChatThreadState withError(String message) => ChatThreadState(
        chatId: chatId,
        title: title,
        model: model,
        style: style,
        models: models,
        styles: styles,
        messages: messages,
        loading: loading,
        sending: sending,
        error: message,
        usage: usage,
        searching: searching,
      );

  /// Копия без ошибки.
  ChatThreadState clearError() => ChatThreadState(
        chatId: chatId,
        title: title,
        model: model,
        style: style,
        models: models,
        styles: styles,
        messages: messages,
        loading: loading,
        sending: sending,
        usage: usage,
        searching: searching,
      );

  /// Последнее сообщение переписки (ответ, который дописывается потоком), либо `null`.
  AiMessage? get last => messages.isEmpty ? null : messages.last;
}

/// Провайдер открытой переписки.
final chatThreadProvider =
    NotifierProvider<ChatThreadController, ChatThreadState>(ChatThreadController.new);

/// Переписка одного чата: история с сервера, отправка вопроса и дописывание ответа потоком.
///
/// Один контроллер на открытый чат, а не семейство по id: открыт всегда ровно один чат —
/// экран переписки лежит отдельным маршрутом поверх списка.
class ChatThreadController extends Notifier<ChatThreadState> {
  /// Подписка на поток ответа; `null` — генерации нет.
  StreamSubscription<AiChunk>? _sub;

  /// Ожидание окончания генерации: `send` не возвращается, пока ответ не дописан или отменён.
  Completer<void>? _done;

  /// Отмену запросил человек — отличает «Стоп» от обрыва связи: в первом случае ошибку
  /// показывать не нужно, во втором — нужно.
  bool _cancelledByUser = false;

  /// Клиент ручек чата поверх текущего облачного клиента.
  AiApi get _api => AiApi(ref.read(appStateProvider).api);

  @override
  ChatThreadState build() {
    // уход с экрана не должен оставлять висящий запрос: разрыв соединения гасит и запрос
    // сервера к провайдеру
    ref.onDispose(() {
      _sub?.cancel();
      _finish();
    });
    return const ChatThreadState();
  }

  /// Открывает чат: читает историю сообщений и список моделей.
  ///
  /// Модели нужны шапке (выбор модели): их список зависит от ключа сервера, поэтому приходит
  /// оттуда, а не хардкодится в приложении.
  Future<void> open(AiChat chat) async {
    state = ChatThreadState(
      chatId: chat.id,
      title: chat.title,
      model: chat.model,
      style: chat.style,
      loading: true,
    );
    try {
      final messages = await _api.messages(chat.id);
      if (state.chatId != chat.id) return; // чат успели сменить, пока шла загрузка
      state = state.copyWith(messages: messages, loading: false);
    } on AiApiException catch (e) {
      state = state.copyWith(loading: false).withError(e.message);
    }
    try {
      final reply = await _api.models();
      if (state.chatId != chat.id) return;
      state = state.copyWith(models: reply.models);
    } on AiApiException {
      // без списка моделей переписка работает: модель уже выбрана и сохранена в чате
    }
    try {
      final styles = await _api.styles();
      if (state.chatId != chat.id) return;
      state = state.copyWith(styles: styles);
    } on AiApiException {
      // без списка стилей тоже: стиль чата уже известен, просто переключить его не из чего
    }
  }

  /// Меняет стиль ответа чата и запоминает выбор для следующих чатов.
  ///
  /// Стиль уходит на сервер: подсказку собирает он, приложение её не знает.
  Future<void> setStyle(String style) async {
    final chatId = state.chatId;
    if (chatId.isEmpty || style == state.style) return;
    state = state.copyWith(style: style);
    await ref.read(settingsProvider).ui.setChatStyle(style);
    try {
      await _api.patchChat(chatId, style: style);
    } on AiApiException catch (e) {
      // стиль уже показан выбранным, но сервер его не принял — говорим об этом прямо,
      // иначе человек будет думать, что модель отвечает в новом стиле, а она не будет
      state = state.withError(e.message);
    }
  }

  /// Меняет модель чата (её запоминает сервер, поэтому выбор переживает перезапуск).
  Future<void> setModel(String model) async {
    final chatId = state.chatId;
    if (chatId.isEmpty) return;
    state = state.copyWith(model: model);
    try {
      await _api.patchChat(chatId, model: model);
    } on AiApiException catch (e) {
      state = state.withError(e.message);
      return;
    }
    ref.read(chatsProvider.notifier).touch(chatId, model: model);
  }

  /// Отправляет вопрос: дописывает его в переписку и запускает поток ответа.
  Future<void> send(String text) async {
    final prompt = text.trim();
    final chatId = state.chatId;
    if (prompt.isEmpty || chatId.isEmpty || state.sending) return;
    state = state.copyWith(
      messages: [
        ...state.messages,
        AiMessage(id: '', role: 'user', content: prompt),
        const AiMessage.pending(),
      ],
    ).clearError();
    await _run(chatId, prompt);
  }

  /// Повторяет последний вопрос после ошибки.
  ///
  /// Ничего не дописывает: вопрос уже в переписке, а ответ на него не пришёл.
  Future<void> retry() async {
    final chatId = state.chatId;
    final lastUser = state.messages.lastWhere((m) => m.isUser, orElse: () => const AiMessage.pending());
    if (chatId.isEmpty || state.sending || lastUser.content.isEmpty) return;
    state = state.copyWith(
      messages: [...state.messages, const AiMessage.pending()],
    ).clearError();
    await _run(chatId, lastUser.content);
  }

  /// Прерывает генерацию: рвёт поток и оставляет на экране уже полученный текст.
  ///
  /// Уже написанное не откатывается: оборванный ответ всё ещё содержит то, что модель успела
  /// сказать, а сервер сохраняет эту часть в БД — при повторном открытии чата она на месте.
  Future<void> stop() async {
    final sub = _sub;
    if (sub == null) return;
    _cancelledByUser = true;
    await sub.cancel();
    _finish();
  }

  /// Запускает поток ответа на [question], который уже лежит в состоянии последним вопросом.
  Future<void> _run(String chatId, String question) async {
    state = state.copyWith(sending: true);
    _cancelledByUser = false;
    final done = Completer<void>();
    _done = done;

    _sub = _api.send(chatId, question).listen(
      _applyChunk,
      onError: (Object e) {
        if (!_cancelledByUser) _fail(e);
        _finish();
      },
      onDone: _finish,
    );

    await done.future;
  }

  /// Дописывает полученное событие в состояние экрана.
  ///
  /// Состояние обновляется на каждое событие: так текст появляется по мере генерации. Список
  /// пересобирается целиком (состояние неизменяемое) — на длинных ответах это дешёво, потому
  /// что экран перестраивает только последний пузырь.
  void _applyChunk(AiChunk chunk) {
    if (chunk.title != null) {
      state = state.copyWith(title: chunk.title);
      ref.read(chatsProvider.notifier).touch(state.chatId, title: chunk.title);
    }
    if (chunk.error != null) {
      state = state.withError(chunk.error!);
      return;
    }
    if (chunk.usage != null) state = state.copyWith(usage: chunk.usage);
    if (chunk.searching != null) state = state.copyWith(searching: chunk.searching);

    final last = state.last;
    if (last == null || last.isUser) return;
    final text = chunk.text;
    final reasoning = chunk.reasoning;
    if (text == null && reasoning == null) return;
    final messages = [...state.messages];
    messages[messages.length - 1] = last.copyWith(
      content: text == null ? null : last.content + text,
      reasoning: reasoning == null ? null : last.reasoning + reasoning,
    );
    state = state.copyWith(messages: messages);
  }

  /// Показывает ошибку потока и убирает пустую заготовку ответа.
  ///
  /// Пустая заготовка после ошибки — это пузырь без текста, который ничего не объясняет:
  /// причину показывает сообщение об ошибке, а вопрос остаётся на месте, чтобы его повторить.
  void _fail(Object e) {
    final message = e is AiApiException ? e.message : 'Не удалось получить ответ.';
    final messages = [...state.messages];
    if (messages.isNotEmpty && !messages.last.isUser && messages.last.content.isEmpty) {
      messages.removeLast();
    }
    state = state.copyWith(messages: messages).withError(message);
  }

  /// Завершает генерацию: снимает признак, убирает пустую заготовку и отпускает ожидание.
  ///
  /// Вызывается из трёх мест — конец потока, ошибка и отмена, — поэтому защищена от повторного
  /// входа: второе завершение уже ничего не делает.
  void _finish() {
    final done = _done;
    _done = null;
    _sub = null;
    if (state.sending) {
      final messages = [...state.messages];
      if (messages.isNotEmpty && !messages.last.isUser && messages.last.content.isEmpty) {
        messages.removeLast();
      }
      // признак «ищет» снимаем вместе с генерацией: иначе подпись осталась бы висеть
      state = state.copyWith(messages: messages, sending: false, searching: false);
      ref.read(chatsProvider.notifier).touch(state.chatId);
    }
    if (done != null && !done.isCompleted) done.complete();
  }
}
