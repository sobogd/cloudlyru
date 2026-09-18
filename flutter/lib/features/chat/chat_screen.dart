import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/widgets.dart';
import 'ai_keys.dart';
import 'ai_provider.dart';
import 'ai_types.dart';
import 'chat_controller.dart';

/// Раздел «Чат»: переписка с моделью ИИ и поле ввода.
///
/// Пока это прототип — одна переписка без сохранения: история чатов, список тем и поиск по ним
/// это следующий этап, поэтому закрытие приложения разговор стирает. Ключ ввести в приложении
/// нельзя: он вшит в сборку (`AiKeys`), и весь раздел работает только там, где сборку собрали
/// с ключом.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// Состояние экрана: поле ввода, прокрутка переписки и признак «человек внизу списка».
class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Текст, который человек набирает. Живёт здесь, а не в контроллере: черновик не относится
  /// к переписке и не должен переживать уход с экрана как часть состояния чата.
  final _input = TextEditingController();

  /// Прокрутка переписки — ею управляет автопрокрутка при генерации.
  final _scroll = ScrollController();

  /// Стоит ли прокрутка внизу переписки.
  ///
  /// Нужен, чтобы растущий ответ тянул экран за собой только тогда, когда человек и так смотрит
  /// конец разговора: иначе автопрокрутка выдёргивала бы его из середины длинного ответа,
  /// который он в этот момент читает.
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackScroll);
    // Список моделей запрашиваем при первом открытии раздела, а не при создании провайдера:
    // до первого показа вкладки раздел не существует, и запрос в сеть на старте приложения
    // был бы лишним. Ждём первый кадр, потому что до него нет смысла трогать провайдеры.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(chatControllerProvider.notifier).loadModels();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Обновляет признак «прокрутка внизу» по каждому движению списка.
  ///
  /// Порог в 80 пикселей, а не строгое равенство: при генерации список растёт между кадрами, и
  /// точное сравнение с максимумом почти всегда давало бы «не внизу», из-за чего автопрокрутка
  /// перестала бы работать вовсе.
  void _trackScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _atBottom = max - _scroll.position.pixels < 80;
  }

  /// Дотягивает переписку до конца после перерисовки кадра.
  ///
  /// Отложенно, потому что длина списка в момент вызова ещё не учитывает новый текст: прыжок
  /// к прежнему максимуму не дотянул бы до конца ответа.
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
    await ref.read(chatControllerProvider.notifier).send(text);
  }

  /// Очищает переписку, спросив подтверждение.
  ///
  /// Подтверждение здесь потому, что переписка пока не сохраняется нигде: очистка стирает
  /// разговор безвозвратно.
  Future<void> _clear() async {
    if (ref.read(chatControllerProvider).messages.isEmpty) return;
    final ok = await confirmDialog(
      context,
      'Очистить чат',
      'Переписка будет стёрта. История чатов пока не сохраняется — восстановить её нечем.',
      danger: true,
      confirmLabel: 'Очистить',
    );
    if (!ok || !mounted) return;
    await ref.read(chatControllerProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider);

    // Автопрокрутка: подписка на состояние, а не на отдельный счётчик дельт — растущий ответ
    // и добавленное сообщение одинаково требуют дотянуть список до конца.
    ref.listen(chatControllerProvider, (_, next) {
      if (next.messages.isEmpty) return;
      if (_atBottom) _scrollToBottomSoon();
    });

    return Scaffold(
      // Цвет шапки задаёт `appBarTheme` из `theme.dart`, как и на остальных разделах.
      appBar: AppBar(
        title: const Text('Чат', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          _modelPicker(state),
          IconButton(
            tooltip: 'Очистить чат',
            onPressed: state.messages.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          // Без ключа в сборке раздел объясняет, почему чат не работает, вместо поля ввода:
          // иначе человек набирал бы вопрос и получал 401.
          if (!AiKeys.hasGrok) const _NoKeyNotice(),
          Expanded(
            child: state.messages.isEmpty
                ? _empty(state)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: state.messages.length,
                    itemBuilder: (context, i) => _bubble(state.messages[i]),
                  ),
          ),
          if (state.error != null) _errorBar(state),
          if (state.usage != null) _usageLine(state),
          if (AiKeys.hasGrok) _composer(state),
        ],
      ),
    );
  }

  /// Выбор модели в шапке: список из того, что отдал провайдер по нашему ключу.
  ///
  /// Список не хардкодится (набор зависит от ключа, а модели появляются и снимаются), поэтому
  /// до его загрузки в шапке видно только название текущей модели и раскрывать нечего.
  Widget _modelPicker(ChatState state) {
    final label = Text(
      state.effectiveModel,
      style: const TextStyle(color: C.fg2, fontSize: 13),
    );
    if (state.models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: state.loadingModels
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : label,
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Модель',
      onSelected: (id) => ref.read(chatControllerProvider.notifier).setModel(id),
      itemBuilder: (context) => [
        for (final m in state.models)
          PopupMenuItem<String>(
            value: m.id,
            child: Text(
              m.label,
              style: TextStyle(color: m.id == state.effectiveModel ? C.accent : C.fg, fontSize: 13),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            label,
            const Icon(Icons.arrow_drop_down, color: C.fg2),
          ],
        ),
      ),
    );
  }

  /// Что показать на пустом экране: подсказку и, если список моделей уже есть, текущую модель.
  Widget _empty(ChatState state) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AiKeys.hasGrok
                ? 'Задайте вопрос — ответ появится здесь.\n\nМодель: ${state.effectiveModel}'
                : 'Чат работает на модели xAI (Grok). Ключ вшивается в сборку приложения, '
                    'поэтому в этой сборке он не задан.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );

  /// Сообщение об ошибке над полем ввода.
  ///
  /// Ошибка не всплывающая, а часть экрана: пока человек не повторит запрос, вопрос остаётся
  /// без ответа, и причина должна быть видна, а не исчезнуть через пару секунд.
  Widget _errorBar(ChatState state) => Container(
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
            // «Повторить» предлагаем только там, где повтор имеет смысл: при неверном ключе
            // повтор вернёт ту же ошибку, и кнопка выглядела бы издевательством.
            if (state.errorKind != AiErrorKind.auth && !state.generating)
              TextButton(
                onPressed: () => ref.read(chatControllerProvider.notifier).retry(),
                child: const Text('Повторить'),
              ),
          ],
        ),
      );

  /// Строка расхода токенов за последний ответ.
  ///
  /// Показываем отдельно от текста ответа и мелко: это справка, а не часть разговора. Цены за
  /// миллион токенов видны в списке моделей — здесь только факт расхода, чтобы он не был тайной.
  Widget _usageLine(ChatState state) {
    final u = state.usage!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          'Токенов: ${u.promptTokens} → ${u.completionTokens}',
          style: const TextStyle(color: C.fg3, fontSize: 11),
        ),
      ),
    );
  }

  /// Поле ввода и кнопка отправки (во время генерации — «Стоп»).
  Widget _composer(ChatState state) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
                enabled: !state.generating,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: C.fg, fontSize: 14),
                decoration: InputDecoration(
                  hintText: state.generating ? 'Модель отвечает…' : 'Спросите что-нибудь',
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
            const SizedBox(width: 8),
            state.generating
                ? IconButton(
                    tooltip: 'Стоп',
                    onPressed: () => ref.read(chatControllerProvider.notifier).stop(),
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

  /// Одно сообщение переписки: вопрос человека справа, ответ модели слева.
  ///
  /// Сторона разная не для красоты: так переписка читается глазами без подписей автора, а
  /// ответы модели с блоками кода визуально шире.
  Widget _bubble(AiMessage message) {
    final isUser = message.role == AiRole.user;
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
                message.text,
                style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
              )
            else
              _answer(message.text),
          ],
        ),
      ),
    );
  }

  /// Текст ответа: обычные абзацы и блоки кода.
  ///
  /// Полноценный разбор markdown сюда не тянем — ответы моделей в основном текст и код, а
  /// блок кода без моноширинного шрифта нечитаем, тогда как заголовки и списки читаются и так.
  Widget _answer(String text) {
    // пустой текст у сообщения ассистента означает «ответ ещё не начался» — во время
    // генерации это нормальное состояние, и показывать нечего
    if (text.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 2),
        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final parts = _splitCode(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final part in parts)
          part.isCode
              ? _codeBlock(part.text)
              : SelectableText(
                  part.text,
                  style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
                ),
      ],
    );
  }

  /// Блок кода: моноширинный текст и кнопка «копировать».
  ///
  /// Копирование здесь важнее оформления: код из ответа почти всегда переносят в редактор, а
  /// выделять его пальцем на телефоне неудобно.
  Widget _codeBlock(String code) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: C.canvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.brd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Копировать',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (mounted) snack(context, 'Код скопирован');
                },
                icon: const Icon(Icons.copy, color: C.fg3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: SelectableText(
                code,
                style: const TextStyle(
                  color: C.fg,
                  fontSize: 12.5,
                  height: 1.35,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      );
}

/// Разбор ответа на куски: обычный текст и блоки кода в тройных обратных кавычках.
///
/// Возвращает части по порядку следования в тексте. Незакрытый блок (ответ ещё генерируется)
/// считается кодом до конца текста: иначе на глазах человека кусок кода мигал бы между
/// оформлениями, пока модель его дописывает.
List<({String text, bool isCode})> _splitCode(String text) {
  const fence = '```';
  final parts = <({String text, bool isCode})>[];
  var rest = text;
  while (true) {
    final start = rest.indexOf(fence);
    if (start < 0) {
      if (rest.trim().isNotEmpty) parts.add((text: rest, isCode: false));
      break;
    }
    final before = rest.substring(0, start);
    if (before.trim().isNotEmpty) parts.add((text: before, isCode: false));
    final after = rest.substring(start + fence.length);
    final end = after.indexOf(fence);
    if (end < 0) {
      // первая строка блока — имя языка (`dart`, `bash`): в ответе его не показываем, оно
      // нужно только подсветке, которой здесь нет
      parts.add((text: _stripLanguage(after), isCode: true));
      break;
    }
    parts.add((text: _stripLanguage(after.substring(0, end)), isCode: true));
    rest = after.substring(end + fence.length);
  }
  return parts;
}

/// Срезает имя языка с первой строки блока кода — саму строку оставляем пустой.
///
/// Без этого в начале каждого блока висело бы лишнее слово (`dart`, `json`), которое в тексте
/// ответа смысла не несёт.
String _stripLanguage(String code) {
  final nl = code.indexOf('\n');
  if (nl < 0) return code;
  final first = code.substring(0, nl).trim();
  // имя языка — короткое слово без пробелов и знаков препинания; всё прочее (например, первая
  // строка самого кода) трогать нельзя
  if (first.isEmpty || first.length > 12 || first.contains(' ')) return code;
  return code.substring(nl + 1);
}

/// Свёрнутый блок «размышлений» модели над ответом.
///
/// Свёрнут по умолчанию: размышления длиннее ответа и в большинстве случаев не нужны, но
/// показать их надо — иначе непонятно, откуда взялся ответ и почему он такой длинный по времени.
class _ReasoningBlock extends StatefulWidget {
  /// Текст размышлений целиком; дописывается по мере генерации.
  final String text;

  const _ReasoningBlock({required this.text});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

/// Состояние блока: раскрыт он или нет. Открытость живёт здесь, а не в состоянии чата: это
/// оформление одного сообщения, и ему незачем переживать перерисовку переписки.
class _ReasoningBlockState extends State<_ReasoningBlock> {
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

/// Подсказка вместо поля ввода, когда сборку собрали без ключа xAI.
///
/// Отдельным блоком, а не сообщением об ошибке: это не сбой, а свойство сборки, и человеку тут
/// нечего повторять — ключ задаётся при сборке (`--dart-define=GROK_API_KEY=…`).
class _NoKeyNotice extends StatelessWidget {
  const _NoKeyNotice();

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_off_outlined, color: C.warn, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'В этой сборке не задан ключ xAI, поэтому чат не может отвечать. Ключ вшивается '
              'в сборку приложения (GROK_API_KEY в секретах репозитория), ввести его здесь нельзя.',
              style: TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
