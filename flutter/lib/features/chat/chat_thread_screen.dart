import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme.dart';
import '../../util/markdown_view.dart';
import '../../util/widgets.dart';
import 'chat_controller.dart';
import 'chat_types.dart';

/// Экран переписки одного чата: сообщения, источники ответов и поле ввода.
///
/// История и ответы живут на сервере: он хранит переписку в БД, ходит к модели и поиску на
/// домашнем маке и логирует каждый запрос. Здесь только показ и ввод.
class ChatThreadScreen extends ConsumerStatefulWidget {
  /// Чат, который открывается: id, тема и модель на момент открытия.
  final ChatSummary chat;

  /// Экран переписки открытого чата.
  const ChatThreadScreen({super.key, required this.chat});

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

/// Состояние экрана: поле ввода, прокрутка и признак «человек внизу списка».
class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  /// Текст, который человек набирает; черновик не относится к переписке и живёт здесь.
  final _input = TextEditingController();

  /// Прокрутка переписки — ею управляет автопрокрутка при генерации.
  final _scroll = ScrollController();

  /// Стоит ли прокрутка внизу переписки.
  ///
  /// Нужен, чтобы растущий ответ тянул экран за собой только тогда, когда человек и так смотрит
  /// конец разговора: иначе автопрокрутка выдёргивала бы его из середины длинного ответа.
  bool _atBottom = true;

  /// Контроллер переписки, взятый один раз в `initState`.
  ///
  /// Не `late final` с инициализатором: его значение нужно и в `dispose` (погасить поток при
  /// уходе с экрана), а обращаться к провайдеру в момент уничтожения виджета уже нельзя.
  late final ChatThreadController _thread;

  @override
  void initState() {
    super.initState();
    _thread = ref.read(chatThreadProvider.notifier);
    _scroll.addListener(_trackScroll);
    // историю запрашиваем после первого кадра: провайдеры трогать в initState нельзя, а
    // показать пустой экран до ответа сервера — это мигание
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _thread.open(widget.chat);
    });
  }

  @override
  void dispose() {
    // Уход с экрана рвёт поток: иначе ответ дописывался бы в закрытую переписку, а мак
    // продолжал бы греть генерацию. Сервер по разрыву соединения гасит и свою работу.
    _thread.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Обновляет признак «прокрутка внизу» по каждому движению списка.
  ///
  /// Порог в 80 пикселей, а не строгое равенство: при генерации список растёт между кадрами, и
  /// точное сравнение с максимумом почти всегда давало бы «не внизу».
  void _trackScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _atBottom = max - _scroll.position.pixels < 80;
  }

  /// Дотягивает переписку до конца после перерисовки кадра.
  ///
  /// Отложенно: длина списка в момент вызова ещё не учитывает новый текст, и прыжок к прежнему
  /// максимуму не дотянул бы до конца ответа.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Отправляет набранный текст и очищает поле.
  ///
  /// Поле чистим сразу, не дожидаясь ответа: вопрос уже виден в переписке, а набранный текст
  /// в поле после отправки выглядел бы как неотправленный.
  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    // после отправки человек смотрит на свой вопрос и на начало ответа — прокрутку возвращаем
    // вниз принудительно, даже если он перед этим читал середину переписки
    _atBottom = true;
    await _thread.send(text);
  }

  /// Открывает источник во внешнем браузере.
  ///
  /// Ошибку показываем словами: без этого нажатие на ссылку «ничего не делало бы», и было бы
  /// неясно, виноват телефон или адрес.
  Future<void> _openSource(ChatSource source) async {
    final ok = await launchUrl(Uri.parse(source.url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) snack(context, 'Не удалось открыть ссылку');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatThreadProvider);

    // Автопрокрутка: подписка на состояние, а не на отдельный счётчик дельт — растущий ответ
    // и добавленное сообщение одинаково требуют дотянуть список до конца.
    ref.listen(chatThreadProvider, (_, next) {
      if (next.messages.isEmpty) return;
      if (_atBottom) _scrollToBottomSoon();
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.title.isEmpty ? widget.chat.title : state.title,
          style: const TextStyle(color: C.fg, fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _body(state)),
          if (state.error != null) _errorBar(state),
          if (state.usage != null) _usageLine(state),
          _composer(state),
        ],
      ),
    );
  }

  /// Тело экрана: загрузка истории или переписка.
  Widget _body(ChatThreadState state) {
    if (state.loading && state.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Задайте вопрос — ответ появится здесь.\n\n'
            'Модель: ${state.model.isEmpty ? widget.chat.model : state.model}\n'
            'Поиск в интернете: ${_searchModeLabel(state.searchMode)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: state.messages.length,
      itemBuilder: (context, i) =>
          _bubble(state.messages[i], isLast: i == state.messages.length - 1),
    );
  }

  /// Подпись режима поиска для пустого экрана и подсказок кнопки.
  String _searchModeLabel(String mode) => switch (mode) {
        'on' => 'всегда',
        'off' => 'не искать',
        _ => 'авто (ищет по вопросам о свежих данных)',
      };

  /// Сообщение об ошибке над полем ввода.
  ///
  /// Ошибка не всплывающая, а часть экрана: пока человек не повторит запрос, вопрос остаётся
  /// без ответа, и причина должна быть видна, а не исчезнуть через пару секунд.
  Widget _errorBar(ChatThreadState state) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.danger),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: C.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                state.error!,
                style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
              ),
            ),
            if (!state.sending)
              TextButton(
                onPressed: () => _thread.retry(),
                child: const Text('Повторить'),
              ),
          ],
        ),
      );

  /// Строка расхода за последний ответ.
  ///
  /// Мелко, над полем ввода: это справка, а не часть разговора. Стоимости в долларах здесь нет
  /// и быть не может — модель считает на домашнем маке, и цена ответа измеряется временем, а не
  /// деньгами; токены показываем потому, что по ним видно, во что обошёлся поиск и чтение страниц.
  Widget _usageLine(ChatThreadState state) {
    final usage = state.usage!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          'Токенов: ${usage.promptTokens} → ${usage.completionTokens}',
          style: const TextStyle(color: C.fg3, fontSize: 11),
        ),
      ),
    );
  }

  /// Поле ввода и кнопка отправки (во время генерации — «Стоп»).
  ///
  /// Снизу прибавляем системный отступ ([navBarInset]): экран открыт отдельным маршрутом, а
  /// `Scaffold` без своей нижней панели не резервирует место под полосу навигации Android.
  Widget _composer(ChatThreadState state) => Container(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + navBarInset(context)),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: C.brd)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                // Во время генерации поле закрыто: второй вопрос поверх первого дал бы две
                // ветки ответа в одной переписке.
                enabled: !state.sending,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: C.fg, fontSize: 14),
                decoration: InputDecoration(
                  hintText: state.sending ? 'Модель отвечает…' : 'Спросите что-нибудь',
                  hintStyle: const TextStyle(color: C.fg3, fontSize: 14),
                  filled: true,
                  fillColor: C.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: C.brd),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: C.brd),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 4),
            _searchButton(state),
            const SizedBox(width: 4),
            state.sending
                ? IconButton(
                    tooltip: 'Стоп',
                    onPressed: () => _thread.stop(),
                    icon: const Icon(Icons.stop_circle_outlined, color: C.danger, size: 32),
                  )
                : IconButton(
                    tooltip: 'Отправить',
                    // Кнопка активна только при непустом тексте: серая кнопка честнее кнопки,
                    // которая молча ничего не делает.
                    onPressed: _input.text.trim().isEmpty ? null : _send,
                    icon: Icon(
                      Icons.send,
                      size: 28,
                      color: _input.text.trim().isEmpty ? C.fg3 : C.accent,
                    ),
                  ),
          ],
        ),
      );

  /// Кнопка режима поиска в интернете.
  ///
  /// Поиск не мгновенный: выдача и чтение страниц занимают секунды. В режиме «авто» сервер ищет
  /// только по вопросам о свежих данных, а кнопка даёт человеку решить самому: «искать» —
  /// принудительно, «не искать» — по знаниям модели.
  Widget _searchButton(ChatThreadState state) {
    final (icon, color, hint) = switch (state.searchMode) {
      'on' => (Icons.travel_explore, C.accent, 'Поиск в интернете: включён'),
      'off' => (Icons.explore_off_outlined, C.fg3, 'Поиск в интернете: выключен'),
      _ => (Icons.travel_explore, C.fg3, 'Поиск в интернете: авто (по вопросу)'),
    };
    return PopupMenuButton<String>(
      tooltip: hint,
      onSelected: (mode) => _thread.setSearchMode(mode),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'auto', child: Text('Авто — искать, когда нужно')),
        PopupMenuItem(value: 'on', child: Text('Искать всегда')),
        PopupMenuItem(value: 'off', child: Text('Не искать')),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 24, color: color),
      ),
    );
  }

  /// Одно сообщение переписки: вопрос человека справа, ответ модели слева.
  ///
  /// Сторона разная не для красоты: так переписка читается глазами без подписей автора.
  Widget _bubble(ChatMessage message, {required bool isLast}) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        // Ширину ограничиваем: пузырь во всю ширину экрана на длинном ответе теряет границу
        // между вопросом и ответом.
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? C.accentSoft : C.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isUser ? C.accent : C.brd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // «Размышления» показываем до ответа и свёрнутыми: они длиннее самого ответа и
            // нужны редко, но полностью скрывать их — значит врать о том, что модель сделала.
            if (message.reasoning.isNotEmpty) _ReasoningBlock(text: message.reasoning),
            if (isUser)
              SelectableText(
                message.content,
                style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
              )
            else
              _answer(message, isLast: isLast),
            if (!isUser && message.sources.isNotEmpty) _sourcesBlock(message.sources),
          ],
        ),
      ),
    );
  }

  /// Текст ответа: markdown, отрисованный как форматированный текст.
  ///
  /// Модель отвечает заголовками, списками, таблицами и блоками кода, поэтому показывать ответ
  /// сырым текстом нельзя. Ссылки на источники модель ставит номером (`[1]`), а не адресом —
  /// адреса живут в сохранённых источниках, и подстановку делает [_withCitationLinks].
  Widget _answer(ChatMessage message, {required bool isLast}) {
    // пустой текст у ответа означает «генерация ещё не началась» — показываем ожидание, а если
    // идёт поиск и чтение страниц, говорим об этом словами: это занимает десятки секунд, и
    // молчащий спиннер в это время выглядит как зависание
    if (message.content.isEmpty) {
      final thread = ref.read(chatThreadProvider);
      if (isLast && thread.searching) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Ищу в интернете и читаю страницы…', style: TextStyle(color: C.fg3, fontSize: 13)),
            ],
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 2),
        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return MarkdownText(_withCitationLinks(message.content, message.sources));
  }

  /// Превращает номера источников в тексте (`[1]`) в markdown-ссылки на их адреса.
  ///
  /// Так задумано с двух сторон: модели проще назвать источник номером (её не заставляют
  /// выписывать длинные адреса и ошибаться в них), а приложение по номеру достаёт точный адрес
  /// из сохранённых источников. Номера, которых нет среди источников, остаются как есть: это
  /// не ссылка, а часть текста. Квадратные скобки внутри уже готовых ссылок не трогаем, иначе
  /// разметка поехала бы на повторной отрисовке.
  String _withCitationLinks(String text, List<ChatSource> sources) {
    if (sources.isEmpty) return text;
    final byPosition = {for (final s in sources) s.position: s.url};
    return text.replaceAllMapped(RegExp(r'(?<!\[)\[(\d{1,2})\](?!\()'), (m) {
      final url = byPosition[int.parse(m.group(1)!)];
      return url == null ? m.group(0)! : '[${m.group(1)}]($url)';
    });
  }

  /// Список источников ответа под текстом: номер, заголовок и домен, нажатие открывает ссылку.
  ///
  /// Нужен именно списком, а не только ссылками в тексте: по нему видно, чем модель
  /// пользовалась, — в том числе когда страницу прочитать не удалось и ответ построен на
  /// выдержке из выдачи.
  Widget _sourcesBlock(List<ChatSource> sources) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Источники', style: TextStyle(color: C.fg3, fontSize: 12)),
            const SizedBox(height: 4),
            for (final source in sources)
              InkWell(
                onTap: () => _openSource(source),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[${source.position}]',
                        style: const TextStyle(color: C.accent, fontSize: 12.5),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          // «только выдержка» — честная пометка: страницу открыть не удалось,
                          // и человек должен знать, что доказательство слабее
                          '${source.title.isEmpty ? source.host : source.title}'
                          '${source.read ? '' : ' (только выдержка)'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.fg2, fontSize: 12.5, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
}

/// Свёрнутый блок «размышлений» модели над ответом.
///
/// Свёрнут по умолчанию: размышления длиннее ответа и в большинстве случаев не нужны, но
/// показать их надо — иначе непонятно, откуда взялся ответ.
class _ReasoningBlock extends StatefulWidget {
  /// Текст размышлений целиком; дописывается по мере генерации.
  final String text;

  /// Блок размышлений.
  const _ReasoningBlock({required this.text});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

/// Состояние блока: раскрыт он или нет. Открытость живёт здесь, а не в состоянии чата: это
/// оформление одного сообщения, и ему незачем переживать перерисовку переписки.
class _ReasoningBlockState extends State<_ReasoningBlock> {
  /// Раскрыт ли блок.
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            children: [
              Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: C.fg3),
              const SizedBox(width: 4),
              Text(
                _open ? 'Размышления' : 'Размышления (${widget.text.length} симв.)',
                style: const TextStyle(color: C.fg3, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 6),
            child: SelectableText(
              widget.text,
              style: const TextStyle(color: C.fg3, fontSize: 12.5, height: 1.35),
            ),
          ),
      ],
    );
  }
}
