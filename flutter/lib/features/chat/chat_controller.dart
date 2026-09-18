import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'ai_keys.dart';
import 'ai_provider.dart';
import 'ai_types.dart';
import 'grok_provider.dart';

/// Модель по умолчанию, пока список моделей не получен.
///
/// Нужна на случай, когда ключ в сборке есть, а списка моделей нет (нет сети, xAI недоступен):
/// без неё чат отказывался бы отправлять что угодно, хотя отправить запрос можно — модель
/// принимается по идентификатору. Как только список пришёл, используется выбор из него.
const _defaultModel = 'grok-4.6';

/// Состояние экрана чата: переписка, доступные модели, признак генерации и последняя ошибка.
///
/// Объект неизменяемый, каждое изменение порождает новое состояние ([copyWith]) — на этом
/// построена перерисовка экрана: он просто читает текущее состояние и не следит за отдельными
/// полями.
class ChatState {
  /// Переписка текущего чата, по порядку: системных сообщений тут нет (их собирает контроллер
  /// перед запросом), история начинается с первого вопроса человека.
  final List<AiMessage> messages;

  /// Модели, доступные ключу, — как их отдал провайдер. Пустой список означает «ещё не
  /// загружены или не удалось»: в этом случае чат работает на [_defaultModel].
  final List<AiModel> models;

  /// Идёт ли загрузка списка моделей (для индикатора в шапке).
  final bool loadingModels;

  /// Идёт ли генерация ответа прямо сейчас — в этом состоянии кнопка отправки становится
  /// кнопкой «Стоп», а поле ввода блокируется.
  final bool generating;

  /// Выбранная модель (`AiModel.id`) или `null`, если выбор ещё не сделан.
  final String? model;

  /// Причина последней неудачи в готовом для показа виде или `null`, если всё в порядке.
  final String? error;

  /// Вид последней ошибки — по нему экран решает, что предложить: повторить запрос или
  /// подсказать про ключ.
  final AiErrorKind? errorKind;

  /// Расход токенов на последний завершённый ответ.
  final AiUsage? usage;

  /// Состояние чата целиком.
  const ChatState({
    this.messages = const [],
    this.models = const [],
    this.loadingModels = false,
    this.generating = false,
    this.model,
    this.error,
    this.errorKind,
    this.usage,
  });

  /// Копия состояния с заменёнными полями.
  ///
  /// `error`/`errorKind`/`usage` сбрасываются только явным `null` через [clearError] и
  /// [clearUsage]: в `copyWith` `null` означает «не трогать», иначе любое обновление текста
  /// ответа стирало бы сообщение об ошибке.
  ChatState copyWith({
    List<AiMessage>? messages,
    List<AiModel>? models,
    bool? loadingModels,
    bool? generating,
    String? model,
    AiUsage? usage,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        models: models ?? this.models,
        loadingModels: loadingModels ?? this.loadingModels,
        generating: generating ?? this.generating,
        model: model ?? this.model,
        error: error,
        errorKind: errorKind,
        usage: usage ?? this.usage,
      );

  /// Копия состояния с проставленной ошибкой.
  ///
  /// Отдельный метод, а не аргумент [copyWith], потому что `copyWith` ошибку не трогает
  /// (см. его комментарий), а этот путь как раз должен её записать.
  ChatState withError(AiErrorKind kind, String message) => ChatState(
        messages: messages,
        models: models,
        loadingModels: loadingModels,
        generating: generating,
        model: model,
        error: message,
        errorKind: kind,
        usage: usage,
      );

  /// Копия состояния без ошибки — перед новой попыткой.
  ChatState clearError() => ChatState(
        messages: messages,
        models: models,
        loadingModels: loadingModels,
        generating: generating,
        model: model,
        usage: usage,
      );

  /// Последнее сообщение — то, которое дописывается потоком; `null` у пустой переписки.
  AiMessage? get last => messages.isEmpty ? null : messages.last;

  /// Модель, которой будет отправлен запрос: выбранная или запасная.
  String get effectiveModel => model ?? _defaultModel;

  /// Модель из списка провайдера, выбранная сейчас (для подписи в шапке); `null` — если её
  /// в списке нет.
  AiModel? get currentModel {
    for (final m in models) {
      if (m.id == effectiveModel) return m;
    }
    return null;
  }
}

/// Провайдер контроллера чата: единственный владелец переписки и активного запроса.
///
/// Контроллер живёт, пока живёт дерево провайдеров (то есть до конца работы приложения):
/// раздел в `IndexedStack` не пересоздаётся, и переписка переживает переходы по вкладкам.
/// На диск она пока не пишется — история чатов это следующий этап, и до него закрытие
/// приложения стирает разговор.
final chatControllerProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);

/// Контроллер чата: держит переписку, отправляет запросы и дописывает ответ по мере генерации.
///
/// Провайдер ИИ создаётся на каждый запрос, а не хранится полем: ключ вшит в сборку и не
/// меняется, а так контроллер не держит внутри себя состояние соединения.
class ChatController extends Notifier<ChatState> {
  /// Подписка на поток текущего ответа; `null` — генерации нет.
  ///
  /// Хранится, чтобы кнопка «Стоп» могла отменить поток: отмена подписки доходит до
  /// `finally` в провайдере и рвёт HTTP-запрос.
  StreamSubscription<AiChunk>? _sub;

  /// Ожидание окончания текущей генерации: `send` не возвращается, пока ответ не дописан,
  /// оборван или отменён.
  Completer<void>? _done;

  /// Отмену запросил человек — отличает «Стоп» от обрыва связи: в первом случае ошибку
  /// показывать не нужно, во втором — нужно.
  bool _cancelledByUser = false;

  /// Начальное состояние: переписка пустая, модель берётся из сохранённого выбора.
  ///
  /// Список моделей здесь не запрашивается: `build` синхронный, а запрос асинхронный, поэтому
  /// его запускает экран при открытии раздела ([loadModels]).
  @override
  ChatState build() {
    // уход с экрана или пересоздание провайдера не должен оставлять висящий HTTP-запрос
    ref.onDispose(() {
      _sub?.cancel();
      _finish();
    });
    return ChatState(model: ref.read(settingsProvider).ui.chatModel);
  }

  /// Загружает список моделей, доступных ключу, и выбирает модель, если выбор ещё не сделан.
  ///
  /// Ошибка загрузки не блокирует чат: она показывается сообщением, а запросы уходят на
  /// [_defaultModel]. Так недоступный список моделей не превращается в неработающий чат.
  Future<void> loadModels() async {
    if (state.loadingModels || !AiKeys.hasGrok) return;
    state = state.copyWith(loadingModels: true).clearError();
    try {
      final models = await _provider().listModels();
      if (models.isEmpty) {
        state = state.copyWith(loadingModels: false);
        return;
      }
      state = state.copyWith(loadingModels: false, models: models);
      // выбор делаем только если человек его ещё не сделал или сохранённой модели больше нет
      if (state.currentModel == null) await setModel(_pickDefault(models));
    } on AiException catch (e) {
      state = state.copyWith(loadingModels: false).withError(e.kind, e.message);
    }
  }

  /// Запоминает выбранную модель: и в состоянии, и в настройках, чтобы выбор пережил перезапуск.
  Future<void> setModel(String id) async {
    state = state.copyWith(model: id);
    await ref.read(settingsProvider).ui.setChatModel(id);
  }

  /// Отправляет вопрос: дописывает его в переписку и запускает генерацию ответа.
  ///
  /// Пустой текст и повторное нажатие во время генерации игнорируются — второй запрос поверх
  /// первого дал бы два ответа в одной переписке.
  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || state.generating) return;
    state = state.copyWith(
      messages: [...state.messages, AiMessage(role: AiRole.user, text: prompt)],
    ).clearError();
    await _generate();
  }

  /// Повторяет последний запрос после ошибки — тем же составом переписки.
  ///
  /// Ничего не дописывает: последнее сообщение в переписке уже вопрос человека, на который
  /// ответа не пришло.
  Future<void> retry() async {
    if (state.generating) return;
    if (state.last?.role != AiRole.user) return;
    state = state.clearError();
    await _generate();
  }

  /// Прерывает генерацию: рвёт поток и оставляет на экране уже полученный текст.
  ///
  /// Уже написанное не откатывается: оборванный ответ всё ещё содержит то, что модель успела
  /// сказать, и терять это при нажатии «Стоп» незачем.
  Future<void> stop() async {
    final sub = _sub;
    if (sub == null) return;
    _cancelledByUser = true;
    await sub.cancel();
    _finish();
  }

  /// Очищает переписку. Идущая генерация сначала прерывается: оставлять её было бы странно —
  /// ответ дописывался бы в уже пустой чат.
  Future<void> clear() async {
    await stop();
    state = ChatState(model: state.model, models: state.models).clearError();
  }

  /// Запускает генерацию ответа на последнее сообщение переписки.
  ///
  /// Возвращается, когда поток закончился, оборвался или был отменён.
  Future<void> _generate() async {
    if (!AiKeys.hasGrok) {
      state = state.withError(
        AiErrorKind.auth,
        'Ключ xAI не задан в этой сборке: чат работает только там, где сборку собрали с ключом.',
      );
      return;
    }

    // пустой ответ-заготовка: поток дописывает его по дельтам, а человек сразу видит, что
    // запрос ушёл (вместо пустого места до первого слова модели)
    state = state.copyWith(
      generating: true,
      messages: [...state.messages, const AiMessage(role: AiRole.assistant, text: '')],
    );
    _cancelledByUser = false;
    final done = Completer<void>();
    _done = done;

    final stream = _provider().stream(
      model: state.effectiveModel,
      messages: _requestMessages(),
    );
    _sub = stream.listen(
      _applyChunk,
      onError: (Object e) {
        // отменённый запрос ошибкой не считается: его отменил сам человек
        if (!_cancelledByUser) _fail(e);
        _finish();
      },
      onDone: _finish,
    );

    await done.future;
  }

  /// Переписка в том виде, в каком она уходит провайдеру: системная часть плюс история.
  ///
  /// Системное сообщение задаёт рамку разговора: без него модель отвечает как обычный
  /// ассистент, а не как часть нашего приложения. «Размышления» прошлых ответов в историю не
  /// попадают — провайдеры их во входных сообщениях не принимают (см. [AiMessage.reasoning]).
  List<AiMessage> _requestMessages() => [
        const AiMessage(
          role: AiRole.system,
          text: 'Ты — помощник внутри приложения CloudlyRu (личное облако файлов и фото). '
              'Отвечай по делу, на языке вопроса, без лишних вступлений.',
        ),
        ...state.messages.where((m) => m.text.isNotEmpty),
      ];

  /// Дописывает полученную порцию в последнее сообщение переписки.
  ///
  /// Состояние обновляется на каждую порцию: так текст появляется на экране по мере генерации.
  /// Список пересобирается целиком, потому что состояние неизменяемое — на коротких ответах
  /// это незаметно, а на длинных перерисовка списка остаётся дешёвой (экран перестраивает
  /// только последний элемент).
  void _applyChunk(AiChunk chunk) {
    final last = state.last;
    if (last == null || last.role != AiRole.assistant) return;
    final text = chunk.text;
    final reasoning = chunk.reasoning;
    final messages = [...state.messages];
    messages[messages.length - 1] = last.copyWith(
      text: text == null ? null : last.text + text,
      reasoning: reasoning == null ? null : last.reasoning + reasoning,
    );
    state = state.copyWith(messages: messages, usage: chunk.usage);
  }

  /// Показывает ошибку потока и убирает пустую заготовку ответа.
  ///
  /// Пустая заготовка после ошибки — это пузырь без текста, который ничего не объясняет:
  /// причину показывает сообщение об ошибке, а вопрос человека остаётся на месте, чтобы его
  /// можно было повторить.
  void _fail(Object e) {
    final err = e is AiException
        ? e
        : const AiException(AiErrorKind.other, 'Не удалось получить ответ.');
    final messages = [...state.messages];
    if (messages.isNotEmpty &&
        messages.last.role == AiRole.assistant &&
        messages.last.text.isEmpty &&
        messages.last.reasoning.isEmpty) {
      messages.removeLast();
    }
    state = state.copyWith(messages: messages).withError(err.kind, err.message);
  }

  /// Завершает генерацию: снимает признак, убирает пустую заготовку и отпускает ожидание.
  ///
  /// Вызывается из трёх мест — конец потока, ошибка и отмена, — поэтому защищена от повторного
  /// входа: второе завершение уже ничего не делает.
  void _finish() {
    final done = _done;
    _done = null;
    _sub = null;
    if (state.generating) {
      final messages = [...state.messages];
      if (messages.isNotEmpty &&
          messages.last.role == AiRole.assistant &&
          messages.last.text.isEmpty &&
          messages.last.reasoning.isEmpty) {
        messages.removeLast();
      }
      state = state.copyWith(messages: messages, generating: false);
    }
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Выбирает модель для первого запуска: предпочтительную, если она доступна, иначе первую.
  static String _pickDefault(List<AiModel> models) {
    for (final m in models) {
      if (m.id == _defaultModel) return m.id;
    }
    return models.first.id;
  }

  /// Провайдер ИИ, которым отправляются запросы.
  ///
  /// Пока это единственный провайдер приложения; тип возвращается интерфейсом [AiProvider],
  /// потому что контроллеру не важно, кто отвечает, — а следующему провайдеру (OpenAI, Gemini,
  /// Anthropic) достаточно будет появиться здесь, не трогая ни экран, ни состояние.
  AiProvider _provider() => GrokProvider(apiKey: AiKeys.grok);
}
