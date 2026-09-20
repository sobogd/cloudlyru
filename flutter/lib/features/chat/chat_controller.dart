import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'chat_api.dart';
import 'chat_types.dart';

/// Состояние списка чатов: темы, признак загрузки и последняя ошибка.
class ChatsState {
  /// Чаты владельца, свежие сверху.
  final List<ChatSummary> chats;

  /// Идёт загрузка списка (для индикатора).
  final bool loading;

  /// Доступна ли модель: `false` — сервер не видит модель на маке.
  ///
  /// `false` означает, что раздел не заработает ни при каких действиях в приложении: модель
  /// живёт на домашней машине, и пока она недоступна, спрашивать некого. Признак нужен, чтобы
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

  /// Копия состояния; ошибку снимает только [ready].
  ChatsState copyWith({List<ChatSummary>? chats, bool? loading, bool? configured}) => ChatsState(
        chats: chats ?? this.chats,
        loading: loading ?? this.loading,
        configured: configured ?? this.configured,
        error: error,
      );

  /// Копия с проставленной ошибкой.
  ChatsState withError(String message) =>
      ChatsState(chats: chats, loading: loading, configured: configured, error: message);

  /// Копия без ошибки и без признака загрузки.
  ChatsState ready({List<ChatSummary>? chats, bool? configured}) => ChatsState(
        chats: chats ?? this.chats,
        loading: false,
        configured: configured ?? this.configured,
      );
}

/// Провайдер списка чатов.
final chatsProvider = NotifierProvider<ChatsController, ChatsState>(ChatsController.new);

/// Список чатов: загрузка, создание, переименование и удаление.
///
/// Список живёт в провайдере, а не в состоянии экрана: так возврат из переписки не тянет его
/// заново и не мигает пустым экраном.
class ChatsController extends Notifier<ChatsState> {
  /// Клиент ручек чата поверх текущего облачного клиента (адрес и сессия — из него).
  ChatApi get _api => ChatApi(ref.read(appStateProvider).api);

  @override
  ChatsState build() => const ChatsState();

  /// Читает список чатов с сервера.
  ///
  /// Заодно узнаёт, доступна ли модель: пустой список без модели и пустой список с моделью —
  /// разные сообщения на экране. Список моделей спрашиваем только при пустом списке чатов:
  /// на каждый показ вкладки это был бы лишний запрос.
  Future<void> load() async {
    state = state.copyWith(loading: true).ready(chats: state.chats);
    try {
      final chats = await _api.chats();
      final configured = chats.isNotEmpty ? true : (await _api.models()).configured;
      state = state.ready(chats: chats, configured: configured);
    } on ChatApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Создаёт чат и возвращает его (или `null`, если не вышло).
  ///
  /// Созданный чат сразу подставляется в начало списка: сервер сортирует чаты по времени
  /// последнего сообщения, и новый окажется там же — ждать перезагрузки списка незачем.
  Future<ChatSummary?> create() async {
    try {
      final chat = await _api.createChat();
      state = state.ready(chats: [chat, ...state.chats]);
      return chat;
    } on ChatApiException catch (e) {
      state = state.withError(e.message);
      return null;
    }
  }

  /// Переименовывает чат: правится и на сервере, и в списке.
  Future<void> rename(ChatSummary chat, String title) async {
    try {
      final updated = await _api.renameChat(chat.id, title);
      state = state.ready(chats: [
        for (final c in state.chats)
          c.id == updated.id
              ? ChatSummary(
                  id: updated.id,
                  title: updated.title,
                  model: updated.model,
                  updatedAt: updated.updatedAt ?? c.updatedAt,
                  messages: c.messages,
                )
              : c,
      ]);
    } on ChatApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Удаляет чат вместе с его сообщениями.
  Future<void> remove(String chatId) async {
    try {
      await _api.deleteChat(chatId);
      state = state.ready(chats: [for (final c in state.chats) if (c.id != chatId) c]);
    } on ChatApiException catch (e) {
      state = state.withError(e.message);
    }
  }

  /// Подтягивает тему и время чата, когда переписка их изменила (сервер назвал чат по первому
  /// вопросу). Дешёвая локальная правка: полный список перечитывать ради одной строки незачем.
  void touch(String chatId, {String? title}) {
    state = state.ready(chats: [
      for (final c in state.chats)
        c.id == chatId
            ? ChatSummary(
                id: c.id,
                title: title ?? c.title,
                model: c.model,
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

  /// Тема чата (сервер выводит её из первого вопроса и присылает событием).
  final String title;

  /// Модель, которой отвечает этот чат.
  final String model;

  /// Переписка в порядке отправки.
  final List<ChatMessage> messages;

  /// Идёт загрузка истории.
  final bool loading;

  /// Идёт генерация ответа: кнопка отправки становится «Стоп», поле ввода закрывается.
  final bool sending;

  /// Причина последней неудачи или `null`.
  final String? error;

  /// Расход токенов на последний ответ.
  final ChatUsage? usage;

  /// Модель сейчас ищет в интернете и читает страницы — на экране это подпись вместо «печатает».
  final bool searching;

  /// Режим поиска: `auto` (решает сервер по вопросу), `on` или `off`.
  final String searchMode;

  /// Переписка и состояние её загрузки.
  const ChatThreadState({
    this.chatId = '',
    this.title = '',
    this.model = '',
    this.messages = const [],
    this.loading = false,
    this.sending = false,
    this.error,
    this.usage,
    this.searching = false,
    this.searchMode = 'auto',
  });

  /// Копия состояния с заменёнными полями; ошибку и расход трогают только явные методы.
  ChatThreadState copyWith({
    String? title,
    String? model,
    List<ChatMessage>? messages,
    bool? loading,
    bool? sending,
    ChatUsage? usage,
    bool? searching,
    String? searchMode,
  }) =>
      ChatThreadState(
        chatId: chatId,
        title: title ?? this.title,
        model: model ?? this.model,
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        sending: sending ?? this.sending,
        error: error,
        usage: usage ?? this.usage,
        searching: searching ?? this.searching,
        searchMode: searchMode ?? this.searchMode,
      );

  /// Копия с проставленной ошибкой.
  ChatThreadState withError(String message) => ChatThreadState(
        chatId: chatId,
        title: title,
        model: model,
        messages: messages,
        loading: loading,
        sending: sending,
        error: message,
        usage: usage,
        searching: searching,
        searchMode: searchMode,
      );

  /// Копия без ошибки.
  ChatThreadState clearError() => ChatThreadState(
        chatId: chatId,
        title: title,
        model: model,
        messages: messages,
        loading: loading,
        sending: sending,
        usage: usage,
        searching: searching,
        searchMode: searchMode,
      );

  /// Последнее сообщение переписки (ответ, который дописывается потоком), либо `null`.
  ChatMessage? get last => messages.isEmpty ? null : messages.last;
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
  StreamSubscription<ChatChunk>? _sub;

  /// Ожидание окончания генерации: [send] не возвращается, пока ответ не дописан или отменён.
  Completer<void>? _done;

  /// Отмену запросил человек — отличает «Стоп» от обрыва связи: в первом случае ошибку
  /// показывать не нужно, во втором — нужно.
  bool _cancelledByUser = false;

  /// Клиент ручек чата поверх текущего облачного клиента.
  ChatApi get _api => ChatApi(ref.read(appStateProvider).api);

  @override
  ChatThreadState build() {
    // уход с экрана не должен оставлять висящий запрос: разрыв соединения гасит и работу
    // сервера (поиск, чтение страниц, генерацию)
    ref.onDispose(() {
      _sub?.cancel();
      _finish();
    });
    return const ChatThreadState();
  }

  /// Открывает чат: читает историю сообщений вместе с источниками ответов.
  Future<void> open(ChatSummary chat) async {
    state = ChatThreadState(
      chatId: chat.id,
      title: chat.title,
      model: chat.model,
      searchMode: ref.read(settingsProvider).ui.chatSearch,
      loading: true,
    );
    try {
      final messages = await _api.messages(chat.id);
      if (state.chatId != chat.id) return; // чат успели сменить, пока шла загрузка
      state = state.copyWith(messages: messages, loading: false);
    } on ChatApiException catch (e) {
      state = state.copyWith(loading: false).withError(e.message);
    }
  }

  /// Меняет режим поиска и запоминает выбор на будущее.
  ///
  /// Режим один на всё приложение: это привычка («ищи только когда прошу»), а не свойство
  /// отдельного разговора.
  Future<void> setSearchMode(String mode) async {
    if (mode == state.searchMode) return;
    state = state.copyWith(searchMode: mode);
    await ref.read(settingsProvider).ui.setChatSearch(mode);
  }

  /// Отправляет вопрос: дописывает его в переписку и запускает поток ответа.
  Future<void> send(String text) async {
    final prompt = text.trim();
    final chatId = state.chatId;
    if (prompt.isEmpty || chatId.isEmpty || state.sending) return;
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(role: 'user', content: prompt),
        const ChatMessage.pending(),
      ],
    ).clearError();
    await _run(chatId, prompt);
  }

  /// Повторяет последний вопрос после ошибки.
  ///
  /// Ничего не дописывает: вопрос уже в переписке, а ответ на него не пришёл.
  Future<void> retry() async {
    final chatId = state.chatId;
    final lastUser = state.messages.lastWhere(
      (m) => m.isUser,
      orElse: () => const ChatMessage.pending(),
    );
    if (chatId.isEmpty || state.sending || lastUser.content.isEmpty) return;
    state = state.copyWith(messages: [...state.messages, const ChatMessage.pending()]).clearError();
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

    // «авто» отправляем как отсутствие поля: решение принимает сервер по тексту вопроса.
    final search = switch (state.searchMode) {
      'on' => true,
      'off' => false,
      _ => null,
    };
    _sub = _api.send(chatId, question, search: search).listen(
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
  /// пересобирается целиком (состояние неизменяемое) — на длинных ответах это дёшево, потому
  /// что экран перестраивает только последний пузырь.
  void _applyChunk(ChatChunk chunk) {
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
    // Источники приходят до генерации и относятся к ответу, который ещё пишется: кладём их в
    // последний пузырь, чтобы ссылки были видны, пока модель печатает.
    if (chunk.sources != null) _attachSources(chunk.sources!);

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

  /// Привязывает источники к последнему ответу (заготовке или уже написанному).
  void _attachSources(List<ChatSource> sources) {
    if (sources.isEmpty) return;
    final last = state.last;
    if (last == null || last.isUser) return;
    final messages = [...state.messages];
    messages[messages.length - 1] = last.copyWith(sources: sources);
    state = state.copyWith(messages: messages);
  }

  /// Показывает ошибку потока и убирает пустую заготовку ответа.
  ///
  /// Пустая заготовка после ошибки — это пузырь без текста, который ничего не объясняет:
  /// причину показывает сообщение об ошибке, а вопрос остаётся на месте, чтобы его повторить.
  void _fail(Object e) {
    final message = e is ChatApiException ? e.message : 'Не удалось получить ответ.';
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
