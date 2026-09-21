import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/format.dart';
import '../../util/markdown_view.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_model_picker.dart';
import 'agent_types.dart';

/// Переписка с агентом в выбранной папке проекта: сообщения, работа инструментов и ввод.
///
/// Всё, что здесь происходит, происходит на маке: процесс pi работает в папке проекта, читает
/// и правит файлы, запускает команды, а модель считает токены — локальная llama.cpp или
/// удалённый провайдер, если он выбран. Приложение показывает, что агент делает, сколько занято
/// контекста и сколько это стоило, и отправляет то, что человек написал.
class AgentThreadScreen extends ConsumerStatefulWidget {
  /// Открытая сессия: её идентификатор и модель на момент открытия.
  final AgentSessionInfo session;

  /// Проект, в чьей папке работает агент (нужен для заголовка и подписей).
  final AgentProject project;

  /// Экран разговора с агентом.
  const AgentThreadScreen({
    super.key,
    required this.session,
    required this.project,
  });

  @override
  ConsumerState<AgentThreadScreen> createState() => _AgentThreadScreenState();
}

/// Состояние экрана: поле ввода, прокрутка, признак «человек внизу» и тикер времени работы.
class _AgentThreadScreenState extends ConsumerState<AgentThreadScreen> {
  /// Текст, который человек набирает; черновик живёт здесь, а не в разговоре.
  final _input = TextEditingController();

  /// Прокрутка переписки — ею управляет автопрокрутка при работе агента.
  final _scroll = ScrollController();

  /// Идём ли за новым содержимым.
  ///
  /// Включается, когда человек у нижнего края, и выключается, как только он отлистал вверх:
  /// иначе растущий ответ выдёргивал бы его из середины разговора. Обратно включается у
  /// нижнего края или кнопкой «вниз».
  bool _follow = true;

  /// Идёт наша собственная прокрутка.
  ///
  /// Нужна, чтобы наш же прыжок вниз не выглядел как «человек прокрутил»: слушатель прокрутки
  /// иначе считал бы позицию и мог бы снова включить следование, из-за чего список залипал бы
  /// у нижнего края и отлистать вверх было невозможно.
  bool _selfScroll = false;

  /// Показаны ли подробные сведения о сессии (токены, счётчики, время, путь к файлу).
  bool _details = false;

  /// Тикер времени работы: пока агент работает, экран раз в секунду пересчитывает «идёт 1:20».
  ///
  /// Без него строка «агент работает…» не отвечает на главный вопрос — сколько уже ждать, а
  /// прогон на локальной модели занимает минуты.
  Timer? _ticker;

  /// Контроллер разговора, взятый один раз в `initState`.
  late final AgentThreadController _thread;

  @override
  void initState() {
    super.initState();
    _thread = ref.read(agentThreadProvider.notifier);
    _scroll.addListener(_trackScroll);
    // историю запрашиваем после первого кадра: провайдеры трогать в initState нельзя
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _thread.attach(widget.session);
    });
  }

  @override
  void dispose() {
    // Уход с экрана отпускает поток, но НЕ останавливает агента: работа продолжается на маке, а
    // экран при возврате подключится к идущему прогону и покажет ответ целиком. Останавливает
    // только «Стоп», закрывает процесс — «Закрыть на маке» в меню.
    _ticker?.cancel();
    _thread.detach();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Обновляет признак «идём за новым» по каждому движению списка.
  ///
  /// Порог в 80 пикселей, а не строгое равенство: при работе агента список растёт между кадрами,
  /// и точное сравнение с максимумом почти всегда давало бы «не внизу». Свои прыжки пропускаем
  /// ([_selfScroll]) — иначе они же и включали бы следование обратно.
  void _trackScroll() {
    if (!_scroll.hasClients || _selfScroll) return;
    _follow = _scroll.position.maxScrollExtent - _scroll.position.pixels < 80;
  }

  /// Отправляет набранный текст и очищает поле.
  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    // после отправки человек смотрит на свой вопрос и начало ответа — возвращаемся вниз
    // принудительно, даже если он перед этим читал середину переписки
    _follow = true;
    await _thread.send(text);
  }

  /// Включает и выключает тикер времени по признаку «идёт работа».
  void _syncTicker(bool sending) {
    if (sending && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!sending && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// Открывает выбор модели: локальная llama.cpp на маке или удалённый провайдер по API.
  Future<void> _pickModel() async {
    final session = ref.read(agentThreadProvider).session;
    final chosen = await showModelPicker(
      context,
      ref,
      harness: session?.harness.isEmpty ?? true ? 'pi' : session!.harness,
      current: session?.model,
    );
    if (chosen == null || !mounted) return;
    await _thread.setModel(chosen);
    if (mounted) snack(context, 'Модель: ${chosen.label}');
  }

  /// Сжимает контекст разговора: длинная работа иначе перестанет влезать в окно модели.
  Future<void> _compact() async {
    final ok = await confirmDialog(
      context,
      'Сжать контекст',
      'Агент перескажет разговор и продолжит с короткой историей. Старые сообщения останутся '
          'в файле сессии, но в контекст модели больше не попадут.',
      confirmLabel: 'Сжать',
    );
    if (!ok || !mounted) return;
    await _thread.compact();
  }

  /// Удаляет сессию на маке вместе с историей и возвращает к списку сессий.
  Future<void> _delete() async {
    final session = ref.read(agentThreadProvider).session;
    if (session == null) return;
    final ok = await confirmDialog(
      context,
      'Удалить сессию',
      'Разговор будет удалён на маке вместе с историей. Восстановить его нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    final result = await _thread.deleteSession();
    if (!mounted || result == null) return;
    if (result.anyDeleted) {
      Navigator.of(context).pop();
      snack(context, 'Сессия удалена');
      return;
    }
    if (result.anyRestored) {
      // Файл вернул живой процесс: разговор ведёт remote-control или открытый терминал Claude
      // Code, и удалить его из приложения нельзя. Говорим это прямо, а не показываем успех.
      snack(
        context,
        'Этот разговор ведёт живой процесс Claude Code: файл восстановлен, удалить его отсюда '
        'нельзя — только в самом Claude',
      );
      return;
    }
    snack(context, 'Удалять было нечего: файл сессии не найден');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentThreadProvider);
    _syncTicker(state.sending);

    // Автопрокрутка подпиской на состояние, а не счётчиком дельт: растущий ответ и новая
    // карточка инструмента одинаково требуют дотянуть список до конца.
    ref.listen(agentThreadProvider, (_, next) {
      if (next.items.isEmpty) return;
      if (_follow) _scrollToBottomSoon();
    });

    return Scaffold(
      appBar: AppBar(
        // В шапке две строки: имя сессии сверху, под ним мелким шрифтом папка, в которой она
        // запущена, и выбранная для неё модель. Сама панель снизу за это больше не отвечает.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              (state.session?.name.isNotEmpty ?? false)
                  ? state.session!.name
                  : widget.project.name,
              style: const TextStyle(color: C.fg, fontSize: 17),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              [
                widget.project.name,
                state.session?.modelLabel ?? widget.session.modelLabel,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(color: C.fg3, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Сведения о сессии',
            onPressed: () => setState(() => _details = !_details),
            icon: Icon(_details ? Icons.info : Icons.info_outline),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            onSelected: (v) => switch (v) {
              'model' => _pickModel(),
              'compact' => _compact(),
              'close' => _closeOnMac(),
              _ => _delete(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'model', child: Text('Модель')),
              PopupMenuItem(
                value: 'compact',
                enabled: !state.sending,
                child: const Text('Сжать контекст'),
              ),
              const PopupMenuItem(
                value: 'close',
                child: Text('Закрыть на маке'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Удалить сессию'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body(state)),
          if (!_details) _jumpButton(state),
          if (_details) _detailsPanel(state),
          if (state.error != null) _errorBar(state),
          _composer(state),
        ],
      ),
    );
  }

  /// Закрывает процесс pi на маке, оставляя разговор в истории.
  Future<void> _closeOnMac() async {
    final session = ref.read(agentThreadProvider).session;
    if (session == null) return;
    await _thread.closeSession();
    if (mounted) snack(context, 'Сессия закрыта на маке, история сохранена');
  }

  /// Тело экрана: загрузка истории или переписка.
  Widget _body(AgentThreadState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Агент работает в папке ${widget.project.path}.\n\n'
            'Он может читать и править файлы проекта и запускать команды — '
            'спрашивать подтверждение он не будет.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: state.items.length,
      itemBuilder: (context, i) => _item(state.items[i]),
    );
  }

  /// Кнопка «вниз»: показывается, только когда человек отлистал от конца разговора.
  ///
  /// Нужна потому, что автопрокрутка после этого молчит: без кнопки вернуться к новому тексту
  /// можно было бы лишь вручную до самого низа, а ответ пишется минутами.
  Widget _jumpButton(AgentThreadState state) {
    if (_follow || state.items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: C.surface2,
          shape: const StadiumBorder(side: BorderSide(color: C.brd)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: _jumpToBottom,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_downward, size: 14, color: C.fg2),
                  SizedBox(width: 6),
                  Text(
                    'К новому',
                    style: TextStyle(color: C.fg2, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Один элемент переписки: вопрос, ответ агента, команда оболочки или служебная строка.
  Widget _item(AgentItem item) {
    if (item.kind == 'note') return _note(item.text);
    if (item.kind == 'bash') return _bashCard(item);

    final isUser = item.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        // ширину ограничиваем: пузырь во всю ширину на длинном ответе теряет границу между
        // вопросом и ответом
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.92,
        ),
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
            // Размышления приходят блоком в общем порядке (в старом ответе без блоков —
            // отдельным полем выше текста): они длиннее ответа и нужны редко, но полностью
            // скрывать их — значит врать о том, что модель сделала.
            if (isUser)
              SelectableText(
                item.text,
                style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
              )
            else if (item.blocks.isNotEmpty)
              // Блоки идут в том порядке, в каком агент работал: текст, карточка команды,
              // снова текст. Так новый текст оказывается под тем, что было до него.
              for (final block in item.blocks) _block(item, block)
            else ...[
              // ответ от моста без блоков (старая сборка) — рисуем как раньше
              if (item.reasoning.isNotEmpty)
                _ReasoningBlock(text: item.reasoning),
              if (item.text.isNotEmpty) MarkdownText(item.text),
              for (final tool in item.tools) _toolCard(tool),
            ],
            if (item.isAssistant && item.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            // Ошибка прогона — часть ответа, а не отдельное сообщение: так видно, на каком шаге
            // разговор оборвался (например, «Request was aborted» после «Стоп»).
            if (item.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  item.error,
                  style: const TextStyle(
                    color: C.warn,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Один блок ответа: кусок текста, «размышления» или карточка вызова инструмента.
  ///
  /// Карточка ищется по идентификатору в [AgentItem.tools]: сам вывод инструмента живёт там
  /// одним экземпляром, а блок задаёт только место карточки в ответе.
  Widget _block(AgentItem item, AgentBlock block) {
    if (block.isTool) {
      final tool = item.tools.where((t) => t.id == block.toolId).firstOrNull;
      return tool == null ? const SizedBox.shrink() : _toolCard(tool);
    }
    if (block.isReasoning) return _ReasoningBlock(text: block.text);
    return MarkdownText(block.text);
  }

  /// Служебная строка: автоответ на подтверждение, которого человек не давал.
  ///
  /// Показывается именно в переписке, а не в логе: раздел работает без подтверждений, и
  /// единственный способ узнать, что агент сделал сам, — увидеть это рядом с ответом.
  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, color: C.fg3, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: C.fg3, fontSize: 12, height: 1.3),
          ),
        ),
      ],
    ),
  );

  /// Карточка прямой команды оболочки (её выполнял не агент, а сам харнесс по просьбе клиента).
  Widget _bashCard(AgentItem item) => Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: C.surface2,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.brd),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          '\$ ${item.command}',
          style: const TextStyle(
            color: C.fg2,
            fontSize: 12.5,
            fontFamily: 'monospace',
          ),
        ),
        if (item.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              item.text,
              style: const TextStyle(
                color: C.fg3,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
      ],
    ),
  );

  /// Карточка вызова инструмента: что агент сделал, с чем и что получил.
  ///
  /// Это главное отличие агентского раздела от чата: здесь видно не только ответ, но и
  /// действия — команду, правку файла, поиск по коду. Свёрнута по умолчанию: вывод бывает
  /// на сотни строк, а нужен редко.
  Widget _toolCard(AgentTool tool) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: _ToolCard(tool: tool),
  );

  /// Ошибка над полем ввода: пока человек не повторит запрос, ответа нет, и причина должна
  /// быть видна, а не исчезнуть через пару секунд.
  Widget _errorBar(AgentThreadState state) => Container(
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

  /// Верхняя граница поля ввода — полоса прогресса заполнения контекста.
  Widget _contextBorder(AgentThreadState state) {
    final percent = state.session?.contextPercent ?? 0;

    return SizedBox(
      height: 14,
      child: Stack(
        children: [
          Container(
            color: C.surface2,
          ),
          Align(
            alignment: Alignment.center,
            child: LinearProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(
                percent >= 85
                    ? C.danger
                    : (percent >= 65 ? C.warn : C.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Подробные сведения о сессии: время, счётчики, расход токенов и файл на маке.
  ///
  /// Свёрнуто по умолчанию: это справка, а не часть разговора, но именно здесь видно, во что
  /// обошлась сессия и где лежит её история.
  Widget _detailsPanel(AgentThreadState state) {
    final session = state.session!;
    final rows = <(String, String)>[
      ('Проект', session.path),
      ('Харнесс', session.harnessName.isEmpty ? 'pi' : session.harnessName),
      ('Модель', session.modelLabel),
      ('Где считает', session.whereLabel),
      if (session.thinkingLevel.isNotEmpty)
        ('Размышления', session.thinkingLevel),
      (
        'Начата',
        session.startedAt == null
            ? '—'
            : fullDate(session.startedAt!.toLocal()),
      ),
      (
        'Последняя активность',
        session.updatedAt == null
            ? '—'
            : fullDate(session.updatedAt!.toLocal()),
      ),
      if (state.runStartedAt != null && state.sending)
        ('Текущий прогон', 'идёт ${_elapsed(state.runStartedAt)}'),
      (
        'Сообщений',
        '${_num(session.messages)} (вопросов ${_num(session.userMessages)}, '
            'ответов ${_num(session.assistantMessages)})',
      ),
      ('Вызовов инструментов', _num(session.toolCalls)),
      if (session.cost > 0) ('Стоимость', session.cost.toStringAsFixed(4)),
      if (session.sessionFile.isNotEmpty) ('Файл на маке', session.sessionFile),
    ];

    return Container(
      width: double.infinity,
      color: C.surface2,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Сведения о сессии',
            style: TextStyle(color: C.fg2, fontSize: 12),
          ),
          const SizedBox(height: 6),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      label,
                      style: const TextStyle(color: C.fg3, fontSize: 11.5),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: const TextStyle(
                        color: C.fg2,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Поле ввода на всю ширину низа экрана и кнопки справа.
  ///
  /// Текстарея занимает весь низ без боковых и нижних отступов — правый внутренний отступ
  /// оставлен только под кнопки. Сверху её ограничивает полоса контекста с подписью
  /// ([_contextBorder]). Системный отступ под полосу навигации Android прибавляем сами: экран
  /// открыт отдельным маршрутом, и `Scaffold` без своей нижней панели его не резервирует.
  Widget _composer(AgentThreadState state) => Container(
    color: C.canvas,
    padding: EdgeInsets.only(bottom: navBarInset(context)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        _contextBorder(state),
        Stack(
          children: [
            TextField(
              controller: _input,
              // Поле доступно и во время работы: дописанное сообщение уходит в очередь и
              // доезжает до агента, как только он освободится, — ждать с пустым полем незачем
              enabled: true,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(color: C.fg, fontSize: 15),
              decoration: InputDecoration(
                hintText: state.sending
                    ? 'Дописать — уйдёт в очередь'
                    : 'Что сделать в проекте?',
                hintStyle: const TextStyle(color: C.fg3, fontSize: 15),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                // справа — место под кнопку отправки (и «Стоп» рядом с ней во время работы),
                // слева — обычный отступ текста от края экрана
                // const здесь нельзя: правый отступ зависит от состояния отправки
                contentPadding: EdgeInsets.fromLTRB(
                  14,
                  10,
                  state.sending ? 100 : 52,
                  10,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            // Кнопки у правого нижнего края: отправка доступна и во время работы агента —
            // сообщение встанет в очередь. «Стоп» рядом, потому что остановить прогон и
            // дописать сообщение — разные действия.
            Positioned(
              right: 4,
              bottom: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: state.sending ? 'Отправить в очередь' : 'Отправить',
                    // кнопка активна только при непустом тексте: серая кнопка честнее кнопки,
                    // которая молча ничего не делает
                    onPressed: _input.text.trim().isEmpty ? null : _send,
                    icon: Icon(
                      state.sending ? Icons.playlist_add : Icons.send,
                      size: 28,
                      color: _input.text.trim().isEmpty ? C.fg3 : C.accent,
                    ),
                  ),
                  if (state.sending)
                    IconButton(
                      tooltip: 'Стоп',
                      onPressed: () => _thread.stop(),
                      icon: const Icon(
                        Icons.stop_circle_outlined,
                        color: C.danger,
                        size: 32,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );

  /// Дотягивает переписку до конца после перерисовки кадра.
  ///
  /// Отложенно: длина списка в момент вызова ещё не учитывает новый текст, и прыжок к прежнему
  /// максимуму не дотянул бы до конца ответа.
  ///
  /// Следование проверяется здесь, а не там, где прыжок поставлен в очередь: между этими двумя
  /// моментами человек успевает отлистать вверх — и раньше список всё равно прыгал вниз, после
  /// чего снова считал себя «внизу» и залипал там навсегда. Пока человек держит палец на экране,
  /// не прыгаем вовсе.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || !_scroll.hasClients) return;
      if (_scroll.position.isScrollingNotifier.value) return;
      _selfScroll = true;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      _selfScroll = false;
    });
  }

  /// Возвращает список к концу разговора по кнопке и снова включает следование.
  void _jumpToBottom() {
    setState(() => _follow = true);
    _scrollToBottomSoon();
  }

  /// Сколько идёт текущая работа словами: «12 с», «1 мин 20 с», «5 мин 3 с».
  ///
  /// Пустая строка, если прогон не идёт или время старта неизвестно: показывать «0 с» на
  /// готовом ответе было бы враньём.
  String _elapsed(DateTime? startedAt) {
    if (startedAt == null) return '';
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    if (seconds < 0) return '';
    if (seconds < 60) return '$seconds с';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes мин $rest с';
  }

  /// Число с разделителями разрядов: «27 747» читается быстрее, чем «27747».
  String _num(int value) {
    final text = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}

/// Карточка одного вызова инструмента: имя, подпись действия, свёрнутый вывод.
///
/// Развёрнутость живёт здесь, а не в состоянии разговора: это оформление одной карточки, и
/// ему незачем переживать перерисовку всей переписки.
class _ToolCard extends StatefulWidget {
  /// Вызов инструмента со всем, что о нём известно.
  final AgentTool tool;

  /// Карточка вызова инструмента.
  const _ToolCard({required this.tool});

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

/// Состояние карточки: развёрнута ли она.
class _ToolCardState extends State<_ToolCard> {
  /// Показан ли вывод целиком.
  bool _open = false;

  /// Значок инструмента: по нему видно вид действия, не читая имя.
  IconData get _icon => switch (widget.tool.name) {
    'bash' => Icons.terminal,
    'read' => Icons.description_outlined,
    'write' => Icons.note_add_outlined,
    'edit' => Icons.edit_outlined,
    'grep' => Icons.search,
    'find' || 'ls' => Icons.folder_open_outlined,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final tool = widget.tool;
    final summary = tool.summary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tool.isError ? C.danger : C.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: tool.output.isEmpty
                ? null
                : () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(_icon, size: 15, color: C.fg3),
                const SizedBox(width: 6),
                Text(
                  tool.name,
                  style: const TextStyle(
                    color: C.fg2,
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: C.fg3,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (tool.running)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (tool.isError)
                  const Icon(Icons.error_outline, size: 15, color: C.danger)
                else
                  const Icon(Icons.check, size: 15, color: C.ok),
                if (tool.output.isNotEmpty)
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: C.fg3,
                  ),
              ],
            ),
          ),
          if (_open && tool.output.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                tool.output,
                style: const TextStyle(
                  color: C.fg3,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Свёрнутый блок «размышлений» модели над ответом.
///
/// Свёрнут по умолчанию: у локальной модели размышления выключены, но если их включат, они
/// будут длиннее ответа — показывать их надо, а мешать чтению не должны.
class _ReasoningBlock extends StatefulWidget {
  /// Текст размышлений целиком; дописывается по мере генерации.
  final String text;

  /// Блок размышлений.
  const _ReasoningBlock({required this.text});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

/// Состояние блока: раскрыт он или нет.
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
              Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: C.fg3,
              ),
              const SizedBox(width: 4),
              Text(
                _open
                    ? 'Размышления'
                    : 'Размышления (${widget.text.length} симв.)',
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
              style: const TextStyle(
                color: C.fg3,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}
