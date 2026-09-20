import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/markdown_view.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_types.dart';

/// Переписка с агентом в выбранной папке проекта: сообщения, работа инструментов и ввод.
///
/// Всё, что здесь происходит, происходит на маке: процесс pi работает в папке проекта, читает
/// и правит файлы, запускает команды, а модель считает локальная llama.cpp. Приложение только
/// показывает, что агент делает, и отправляет то, что человек написал.
class AgentThreadScreen extends ConsumerStatefulWidget {
  /// Открытая сессия: её идентификатор и модель на момент открытия.
  final AgentSessionInfo session;

  /// Проект, в чьей папке работает агент (нужен для заголовка и подписей).
  final AgentProject project;

  /// Экран разговора с агентом.
  const AgentThreadScreen({super.key, required this.session, required this.project});

  @override
  ConsumerState<AgentThreadScreen> createState() => _AgentThreadScreenState();
}

/// Состояние экрана: поле ввода, прокрутка и признак «человек внизу списка».
class _AgentThreadScreenState extends ConsumerState<AgentThreadScreen> {
  /// Текст, который человек набирает; черновик живёт здесь, а не в разговоре.
  final _input = TextEditingController();

  /// Прокрутка переписки — ею управляет автопрокрутка при работе агента.
  final _scroll = ScrollController();

  /// Стоит ли прокрутка внизу переписки.
  ///
  /// Нужен, чтобы растущий ответ тянул экран за собой только тогда, когда человек и так
  /// смотрит конец разговора: иначе автопрокрутка выдёргивала бы его из середины.
  bool _atBottom = true;

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
    // уход с экрана рвёт поток и закрывает процесс pi на маке: держать контекст модели в
    // памяти ради закрытого разговора незачем, история осталась в файле сессии
    _thread.stop();
    _thread.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Обновляет признак «прокрутка внизу» по каждому движению списка.
  ///
  /// Порог в 80 пикселей, а не строгое равенство: при работе агента список растёт между
  /// кадрами, и точное сравнение с максимумом почти всегда давало бы «не внизу».
  void _trackScroll() {
    if (!_scroll.hasClients) return;
    _atBottom = _scroll.position.maxScrollExtent - _scroll.position.pixels < 80;
  }

  /// Отправляет набранный текст и очищает поле.
  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _atBottom = true;
    await _thread.send(text);
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentThreadProvider);

    // Автопрокрутка подпиской на состояние, а не счётчиком дельт: растущий ответ и новая
    // карточка инструмента одинаково требуют дотянуть список до конца.
    ref.listen(agentThreadProvider, (_, next) {
      if (next.items.isEmpty) return;
      if (_atBottom) _scrollToBottomSoon();
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(
          (state.session?.name.isNotEmpty ?? false) ? state.session!.name : widget.project.name,
          style: const TextStyle(color: C.fg, fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Сжать контекст',
            onPressed: state.sending ? null : _compact,
            icon: const Icon(Icons.compress),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body(state)),
          if (state.error != null) _errorBar(state),
          if (state.session != null) _statusLine(state),
          _composer(state),
        ],
      ),
    );
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
            'Модель: ${state.session?.model ?? widget.session.model}\n'
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
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.92),
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
            // Размышления показываем до ответа и свёрнутыми: они длиннее самого ответа и нужны
            // редко, но полностью скрывать их — значит врать о том, что модель сделала.
            if (item.reasoning.isNotEmpty) _ReasoningBlock(text: item.reasoning),
            if (isUser)
              SelectableText(
                item.text,
                style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
              )
            else ...[
              if (item.text.isNotEmpty) MarkdownText(item.text),
              if (item.text.isEmpty && item.tools.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
            for (final tool in item.tools) _toolCard(tool),
            // Ошибка прогона — часть ответа, а не отдельное сообщение: так видно, на каком
            // шаге разговор оборвался (например, «Request was aborted» после «Стоп»).
            if (item.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  item.error,
                  style: const TextStyle(color: C.warn, fontSize: 12.5, height: 1.3),
                ),
              ),
          ],
        ),
      ),
    );
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
              style: const TextStyle(color: C.fg2, fontSize: 12.5, fontFamily: 'monospace'),
            ),
            if (item.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  item.text,
                  style: const TextStyle(color: C.fg3, fontSize: 12, fontFamily: 'monospace'),
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
              TextButton(onPressed: () => _thread.retry(), child: const Text('Повторить')),
          ],
        ),
      );

  /// Строка состояния под перепиской: что делает агент сейчас и сколько занято контекста.
  ///
  /// Нужна потому, что прогон агента занимает минуты (чтение файлов, команды, локальная
  /// модель): без неё человек видит молчащий экран и решает, что всё зависло. Расход
  /// контекста тут же — по нему понятно, когда пора сжимать разговор.
  Widget _statusLine(AgentThreadState state) {
    final session = state.session!;
    final parts = <String>[
      if (state.sending) state.step.isEmpty ? 'агент работает…' : state.step,
      if (!state.sending && state.usage != null)
        'токенов: ${state.usage!.input} → ${state.usage!.output}',
      if (session.contextTokens != null && session.contextWindow != null)
        'контекст: ${session.contextTokens} из ${session.contextWindow}',
      if (session.model.isNotEmpty) session.model,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          if (state.sending) ...[
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// Поле ввода и кнопка отправки (во время работы агента — «Стоп»).
  ///
  /// Снизу прибавляем системный отступ ([navBarInset]): экран открыт отдельным маршрутом, а
  /// `Scaffold` без своей нижней панели не резервирует место под полосу навигации Android.
  Widget _composer(AgentThreadState state) => Container(
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
                // во время работы агента поле закрыто: второй вопрос поверх первого дал бы
                // две ветки в одном контексте
                enabled: !state.sending,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: C.fg, fontSize: 14),
                decoration: InputDecoration(
                  hintText: state.sending ? 'Агент работает…' : 'Что сделать в проекте?',
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
            state.sending
                ? IconButton(
                    tooltip: 'Стоп',
                    onPressed: () => _thread.stop(),
                    icon: const Icon(Icons.stop_circle_outlined, color: C.danger, size: 32),
                  )
                : IconButton(
                    tooltip: 'Отправить',
                    // кнопка активна только при непустом тексте: серая кнопка честнее кнопки,
                    // которая молча ничего не делает
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

  /// Дотягивает переписку до конца после перерисовки кадра.
  ///
  /// Отложенно: длина списка в момент вызова ещё не учитывает новый текст, и прыжок к
  /// прежнему максимуму не дотянул бы до конца ответа.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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
            onTap: tool.output.isEmpty ? null : () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(_icon, size: 15, color: C.fg3),
                const SizedBox(width: 6),
                Text(
                  tool.name,
                  style: const TextStyle(color: C.fg2, fontSize: 12.5, fontFamily: 'monospace'),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg3, fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (tool.running)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                else if (tool.isError)
                  const Icon(Icons.error_outline, size: 15, color: C.danger)
                else
                  const Icon(Icons.check, size: 15, color: C.ok),
                if (tool.output.isNotEmpty)
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: C.fg3),
              ],
            ),
          ),
          if (_open && tool.output.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                tool.output,
                style: const TextStyle(color: C.fg3, fontSize: 12, fontFamily: 'monospace', height: 1.3),
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
