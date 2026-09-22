import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
///
/// Экран годится на две роли, и различие только в шапке: отдельный экран поверх списка разговоров
/// (телефон) и правая панель раздела «Проекты» на широком экране ([embedded]). Тело, поле ввода
/// и работа с сессией в обеих ролях одни и те же — вторая копия переписки разошлась бы с первой
/// при первой же правке.
class AgentThreadScreen extends ConsumerStatefulWidget {
  /// Открытая сессия: её идентификатор и модель на момент открытия.
  final AgentSessionInfo session;

  /// Проект, в чьей папке работает агент (нужен для заголовка и подписей).
  final AgentProject project;

  /// Разговор открыт панелью рядом со списком, а не отдельным экраном.
  ///
  /// В этом виде шапку рисует сам экран ([_AgentThreadScreenState._paneHeader]) — по высоте и
  /// цвету ту же, что у `AppBar`, — и в ней есть кнопка «к списку».
  final bool embedded;

  /// Ширина панели, в которой открыт разговор; `null` — экран занимает всё окно.
  ///
  /// Нужна только для предела ширины пузырей: `MediaQuery` в двухпанельном виде дал бы ширину
  /// всего окна, и пузырь вылез бы за край панели.
  final double? paneWidth;

  /// Уход из панели: сброс выбранного разговора в списке.
  ///
  /// Назван отдельно от возврата назад, потому что панель — не маршрут: `Navigator.pop` здесь
  /// закрыл бы весь раздел. На отдельном экране `null` — там работает именно `Navigator`.
  final VoidCallback? onDismiss;

  /// Экран (или панель) разговора с агентом.
  const AgentThreadScreen({
    super.key,
    required this.session,
    required this.project,
    this.embedded = false,
    this.paneWidth,
    this.onDismiss,
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

  /// Ключи раскрытых служебных сообщений («размышлений», вызовов инструментов, команд).
  ///
  /// По ключу, а не по индексу в списке: пока ответ дописывается, пункты добавляются в конец,
  /// и нумерация уже раскрытых сообщений поехала бы. Ключ даёт [_entryKey].
  final _open = <String>{};

  /// Показан ли разговор с конца.
  ///
  /// Первый прыжок вниз — не «следование за новым текстом», а показ истории с конца: до него
  /// ни отлист человека, ни признак прокрутки во внимание не берутся, иначе длинный разговор
  /// открывался бы с самого начала.
  bool _initialJumpDone = false;

  /// Сколько кадров подряд уже пытаемся доехать до конца при открытии разговора.
  ///
  /// История приходит и раскладывается не одним кадром, и максимум прокрутки растёт уже после
  /// прыжка. Потолок нужен, чтобы содержимое, доезжающее бесконечно (например, картинки), не
  /// оставило экран в вечных прыжках.
  int _initialJumpTries = 0;

  /// Предел прокрутки в прошлой попытке: пока он растёт, мы ещё не в конце истории.
  double _initialJumpExtent = -1;

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
      if (!mounted) return;
      // Первый показ начинается заново на каждый открытый разговор: признак снят с прошлой
      // истории (или его не было вовсе).
      //
      // `attach` не ждём: у занятой сессии он дожидается конца текущего прогона (подключается к
      // нему), и ожидание здесь отложило бы прыжок в конец до конца работы агента. Историю
      // прихода состояния мы и так поймаем слушателем провайдера.
      _initialJumpDone = false;
      _initialJumpTries = 0;
      _initialJumpExtent = -1;
      _thread.attach(widget.session);
      _scrollToBottomSoon();
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
  /// ([_selfScroll]) — иначе они же и включали бы следование обратно. Пока идёт первый прыжок в
  /// конец ([_initialJumpDone]), движение списка не наше дело: его сдвигает сама укладывающаяся
  /// история, и считать это отлистом человека нельзя.
  void _trackScroll() {
    if (!_scroll.hasClients || _selfScroll) return;
    if (!_initialJumpDone) return;
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
      // Сообщение показываем до ухода с экрана: после `pop` и сброса выбора это состояние
      // может быть уже не смонтировано, а `ScaffoldMessenger` ищется по нему.
      snack(context, 'Сессия удалена');
      if (widget.embedded) {
        widget.onDismiss?.call();
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    if (result.anyRestored) {
      // Файл вернул живой процесс: разговор открыт в терминале Claude Code, и удалить его из
      // приложения нельзя. Говорим это прямо, а не показываем успех.
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
      // Пока грузится история, прыгать некуда: список в это время пуст и предел прокрутки
      // нулевой — прыжок «до конца» снял бы признак первого показа раньше срока, и приход
      // истории уже не отмотал бы переписку в конец.
      if (next.loading) {
        _initialJumpDone = false;
        _initialJumpTries = 0;
        _initialJumpExtent = -1;
        return;
      }
      if (next.items.isEmpty) return;
      if (_follow || !_initialJumpDone) _scrollToBottomSoon();
    });

    // Страховка на случай, если слушатель не сработал (например, история оказалась в состоянии
    // раньше, чем он подписался): пока первый показ не закончен, прыжок в конец ставится из
    // самой сборки. После него условие перестаёт выполняться.
    if (!_initialJumpDone && !state.loading && state.items.isNotEmpty) {
      _scrollToBottomSoon();
    }

    // Тело одинаково в обеих ролях: разница только в том, кто рисует шапку.
    final body = Column(
      children: [
        Expanded(child: _body(state)),
        if (_details) _detailsPanel(state),
        if (state.error != null) _errorBar(state),
        _composer(state),
      ],
    );

    if (widget.embedded) {
      return Column(
        children: [
          _paneHeader(state),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _title(state),
        actions: [_actions(state)],
        // фон — как у левого бара разделов ([C.island]): шапка разговора и колонка списка
        // читаются одной поверхностью, а не двумя разными полосами
        backgroundColor: C.island,
      ),
      body: body,
    );
  }

  /// Заголовок разговора: имя сессии сверху, под ним мелким шрифтом папка, в которой она
  /// запущена, и выбранная для неё модель.
  ///
  /// Одним и тем же виджетом и в `AppBar` отдельного экрана, и в шапке панели: строки не
  /// должны разъехаться — по ним видно, что именно открыто.
  Widget _title(AgentThreadState state) => Column(
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
  );

  /// Действия над разговором одним меню «троеточие»: сведения, модель, сжатие контекста
  /// и удаление.
  ///
  /// Всё в меню, а не отдельными кнопками: в шапке их должно быть ровно две — стрелка назад и
  /// троеточие — иначе на телефоне кнопки отъедают место у названия разговора. «Сведения»
  /// открывают ту же панель, что раньше показывала отдельная кнопка с «i».
  Widget _actions(AgentThreadState state) => PopupMenuButton<String>(
    tooltip: 'Ещё',
    onSelected: (v) => switch (v) {
      'details' => setState(() => _details = !_details),
      'model' => _pickModel(),
      'compact' => _compact(),
      _ => _delete(),
    },
    // плотнее и без внутренних отступов: кнопка стоит рядом со стрелкой и не должна занимать
    // под себя 48 пикселей со всех сторон
    style: IconButton.styleFrom(
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    iconSize: 22,
    itemBuilder: (context) => [
      PopupMenuItem(
        value: 'details',
        child: Text(_details ? 'Скрыть сведения' : 'Сведения о сессии'),
      ),
      const PopupMenuItem(value: 'model', child: Text('Модель')),
      PopupMenuItem(
        value: 'compact',
        enabled: !state.sending,
        child: const Text('Сжать контекст'),
      ),
      const PopupMenuItem(value: 'delete', child: Text('Удалить сессию')),
    ],
  );

  /// Шапка разговора в панели: тот же заголовок и те же действия, что в `AppBar`, плюс кнопка
  /// «к списку».
  ///
  /// Высота и фон — как у `AppBar` (56, [C.island]): шапка списка разговоров и шапка самого
  /// разговора стоят на одной линии и читаются одной полосой над двумя панелями.
  Widget _paneHeader(AgentThreadState state) => Container(
    height: 56,
    // фон — как у левого бара разделов ([C.island]): панель со списком слева и шапка панели
    // справа — одна поверхность, границу задаёт рамка между панелями
    color: C.island,
    child: Row(
      children: [
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'К списку разговоров',
          onPressed: widget.onDismiss,
          icon: const Icon(Icons.arrow_back),
          // плотнее и без внутренних отступов: в шапке всего две кнопки, и место нужно
          // названию разговора, а не пустому полю вокруг стрелки
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 8),
        Expanded(child: _title(state)),
        const SizedBox(width: 8),
        _actions(state),
        const SizedBox(width: 8),
      ],
    ),
  );

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
    // элементы разворачиваются в сообщения один раз на сборку: от них же зависит и их число
    final entries = _entries(state.items);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      // ответ агента показывается несколькими сообщениями: команда и текст — разные шаги
      // работы, и в одном пузыре они читаются как одна реплика модели
      itemCount: entries.length,
      itemBuilder: (context, i) => _entry(entries[i]),
    );
  }

  /// Разворачивает элементы разговора в плоский список сообщений.
  ///
  /// Один ответ агента приходит одним [AgentItem] с блоками внутри (текст, карточка команды,
  /// снова текст), и порядок этих блоков — это порядок работы агента. Рисовать их одним
  /// пузырём значит перемешивать команды и текст в одном сообщении, поэтому блок становится
  /// отдельным сообщением, а порядок блоков задаёт порядок списка.
  List<_Entry> _entries(List<AgentItem> items) {
    final entries = <_Entry>[];
    for (final item in items) {
      // блоки разбираем в свой список: ошибку прогона надо привязать к последнему сообщению
      // именно этого ответа, а не к предыдущему в разговоре
      final mine = <_Entry>[];
      if (item.kind == 'note') {
        mine.add(_Entry(_EntryKind.note, text: item.text));
      } else if (item.kind == 'bash') {
        mine.add(
          _Entry(_EntryKind.bash, text: item.text, command: item.command),
        );
      } else if (item.isUser) {
        mine.add(_Entry(_EntryKind.user, text: item.text));
      } else if (item.blocks.isEmpty) {
        // Ответ от старого моста, который блоков ещё не присылал: тот же порядок, что
        // задавали раньше — размышления, текст, затем карточки команд.
        if (item.reasoning.isNotEmpty) {
          mine.add(_Entry(_EntryKind.reasoning, text: item.reasoning));
        }
        if (item.text.isNotEmpty) {
          mine.add(_Entry(_EntryKind.text, text: item.text));
        }
        for (final tool in item.tools) {
          mine.add(_Entry(_EntryKind.tool, tool: tool));
        }
      } else {
        for (final block in item.blocks) {
          if (block.isTool) {
            // карточка адресуется идентификатором: сам вывод лежит в [AgentItem.tools], и
            // ссылка без него означала бы сообщение из ничего
            final tool = item.tools
                .where((t) => t.id == block.toolId)
                .firstOrNull;
            if (tool != null) mine.add(_Entry(_EntryKind.tool, tool: tool));
          } else if (block.isReasoning) {
            mine.add(_Entry(_EntryKind.reasoning, text: block.text));
          } else {
            mine.add(_Entry(_EntryKind.text, text: block.text));
          }
        }
      }
      // ответ заказан, но ещё ничего не пришло: пузырь со спиннером, чтобы было видно,
      // что работа идёт
      if (mine.isEmpty && item.isAssistant && item.isEmpty) {
        mine.add(const _Entry(_EntryKind.waiting));
      }
      // Ошибка прогона — часть того сообщения, на котором разговор оборвался: так видно,
      // на каком шаге это случилось (например, «Request was aborted» после «Стоп»).
      if (item.error.isNotEmpty && mine.isNotEmpty) {
        mine[mine.length - 1] = mine.last.copyWith(error: item.error);
      }
      entries.addAll(mine);
    }
    return entries;
  }

  /// Одно сообщение переписки.
  ///
  /// Все виды — текст, «размышления», карточка команды и прямая команда оболочки — рисуются
  /// одинаково: тот же пузырь, тот же кегль текста. Служебное содержимое отличается только
  /// приглушёнными цветами ([muted]): оно поясняет работу агента, а не является ответом.
  ///
  /// Свёрнутым по умолчанию идёт служебное: «размышления», карточка вызова инструмента и
  /// прямая команда оболочки. В переписке важны ответы, а не то, как агент к ним шёл; в
  /// свёрнутом виде у них видна первая строка — по ней узнаётся, о чём речь.
  Widget _entry(_Entry entry) => switch (entry.kind) {
    _EntryKind.note => _note(entry.text),
    _EntryKind.bash => _message(
      muted: true,
      copyText: entry.copyText,
      expandKey: _entryKey(entry),
      collapsedPreview: _firstLine('\$ ${entry.command}'),
      child: _BashCard(command: entry.command, output: entry.text),
    ),
    _EntryKind.tool => _message(
      muted: true,
      copyText: entry.copyText,
      expandKey: _entryKey(entry),
      collapsedPreview: _firstLine(entry.tool!.output),
      child: _ToolCard(tool: entry.tool!),
    ),
    _EntryKind.reasoning => _message(
      muted: true,
      copyText: entry.copyText,
      expandKey: _entryKey(entry),
      collapsedPreview: _firstLine(entry.text),
      child: _ReasoningBlock(text: entry.text),
    ),
    _EntryKind.user || _EntryKind.text || _EntryKind.waiting => _message(
      isUser: entry.kind == _EntryKind.user,
      copyText: entry.copyText,
      child: _bubbleContent(entry),
    ),
  };

  /// Первая непустая строка текста — то, что видно у свёрнутого служебного сообщения.
  ///
  /// Обрезается по длине: одна строка вывода команды или «размышлений» может быть хоть на
  /// весь экран, а в свёрнутом виде она — только намёк на содержимое.
  String _firstLine(String text) {
    final line = _compactLines(text).split('\n').first.trim();
    return line.length <= _collapsedChars
        ? line
        : '${line.substring(0, _collapsedChars).trimRight()}…';
  }

  /// Ключ состояния раскрытия для пункта переписки.
  ///
  /// Ключ обязан быть стабильным, а не «пункт №5 в списке»: пока ответ дописывается, пункты
  /// добавляются в конец, и номер позиции у уже раскрытого сообщения не менялся бы только по
  /// случайности. Для вызова инструмента годится его идентификатор от харнесса, для остальных —
  /// первые символы текста: двух одинаковых кусков в одной переписке не бывает.
  String _entryKey(_Entry entry) {
    final id = entry.tool?.id ?? '';
    if (id.isNotEmpty) return 'tool:$id';
    return '${entry.kind.name}:${entry.text.hashCode}:${entry.command.hashCode}';
  }

  /// Содержимое текстового сообщения: сам текст, ожидание ответа и ошибка прогона.
  Widget _bubbleContent(_Entry entry) {
    final isUser = entry.kind == _EntryKind.user;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.text.isNotEmpty)
          isUser
              ? SelectableText(
                  entry.text,
                  style: const TextStyle(
                    color: C.fg,
                    fontSize: _textSize,
                    height: 1.35,
                  ),
                )
              : MarkdownText(entry.text),
        // ответ заказан, но ещё ничего не пришло — видно, что работа идёт
        if (entry.kind == _EntryKind.waiting)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        // Ошибка прогона — часть того сообщения, на котором разговор оборвался: так видно,
        // на каком шаге это случилось (например, «Request was aborted» после «Стоп»).
        if (entry.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              entry.error,
              style: const TextStyle(
                color: C.warn,
                fontSize: _textSize,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }

  /// Предельная ширина пузыря: доля панели, в которой открыт разговор.
  ///
  /// Считается от ширины панели, а не окна ([widget.paneWidth]): в двухпанельном виде пузырь
  /// во всю ширину окна вылез бы за край правой панели и уехал под неё. Меньше 0.8 — чтобы
  /// сообщения оставались полосами переписки, а не страницами текста во всю ширину.
  double _bubbleMax(BuildContext context) =>
      (widget.paneWidth ?? MediaQuery.sizeOf(context).width) * 0.8;

  /// Одно сообщение переписки: пузырь и кнопки «скопировать» и «раскрыть» рядом с ним.
  ///
  /// Кнопки стоят вне пузыря — внутри они отнимали бы место у текста и читались бы как часть
  /// содержимого. Чтобы пара поместилась в отведённую ширину, предел пузыря уменьшается на
  /// ширину кнопок. У сообщения без текста (например, ожидания ответа) кнопок нет: ни
  /// копировать, ни раскрывать нечего.
  ///
  /// Раскрытие вынесено к кнопке копирования, а не спрятано внутри служебного сообщения: там
  /// его пришлось бы искать взглядом в тексте вывода, а рядом с копированием обе кнопки стоят
  /// на одном месте у каждого сообщения и не зависят от того, что внутри.
  Widget _message({
    required String copyText,
    required Widget child,
    bool isUser = false,
    bool muted = false,
    String? expandKey,
    String collapsedPreview = '',
  }) {
    final expanded = expandKey != null && _open.contains(expandKey);
    final bubble = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: _bubbleMax(context) - _togglesWidth,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // служебное сообщение приглушено другим фоном, а не оттенком текста: так его видно
          // боковым зрением, и оно не спорит с ответом агента
          color: muted ? C.surface2 : (isUser ? C.accentSoft : C.surface),
          borderRadius: BorderRadius.circular(14),
          // Рамка одна на все виды сообщений, включая неудачные вызовы: об ошибке говорит
          // красная иконка внутри карточки, а красная рамка делала бы из этого сообщения
          // самое заметное в переписке.
          border: Border.all(color: isUser ? C.accent : C.brd),
        ),
        // свёрнутое служебное сообщение — одна строка вместо всего текста: тап по строке
        // раскрывает её (хитбокс шире самой строки, чтобы попадать по ней пальцем)
        child: expanded || expandKey == null
            ? child
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggle(expandKey),
                child: CollapsedLine(text: collapsedPreview),
              ),
      ),
    );
    final buttons = <Widget>[
      if (copyText.trim().isNotEmpty) _CopyButton(text: copyText),
      if (expandKey != null)
        _ExpandButton(expanded: expanded, onPressed: () => _toggle(expandKey)),
    ];
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // кнопки стоят по центру пузыря по вертикали: у высокого сообщения они не уезжают
        // к нижнему краю и не выглядят приклеенными к тексту
        crossAxisAlignment: CrossAxisAlignment.center,
        children: isUser
            ? [...buttons.reversed, bubble]
            : [bubble, ...buttons],
      ),
    );
  }

  /// Раскрывает или сворачивает служебное сообщение пункта переписки.
  ///
  /// Состояние живёт по ключу пункта ([_entryKey]) и переживает перерисовки: ответ
  /// дописывается по кускам, и без этого раскрытое сообщение схлопывалось бы на каждом кадре.
  void _toggle(String key) => setState(() {
    if (!_open.remove(key)) _open.add(key);
  });

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

  /// Заполнение контекста — полоса во всю ширину над полем ввода.
  ///
  /// Тонкая полоса без рамок и внешних отступов, фон — как у поля ввода: она примыкает к
  /// нему сверху и читается его границей, а не отдельным элементом. Числа и проценты живут
  /// в «Сведениях о сессии» — здесь нужен только сам расход.
  Widget _contextBorder(AgentThreadState state) {
    final percent = state.session?.contextPercent ?? 0;

    return LinearProgressIndicator(
      value: (percent / 100).clamp(0.0, 1.0),
      minHeight: 3,
      // фон — как у самого поля ввода (`fillColor` в `inputDecorationTheme`), а не как у фона
      // экрана: полоса должна читаться границей поля, а не отдельной плашкой над ним
      backgroundColor: C.surface3,
      // M3 дорисовывает точку-стоп у конца полосы; здесь она была бы мусором
      stopIndicatorRadius: 0,
      valueColor: AlwaysStoppedAnimation(
        percent >= 85 ? C.danger : (percent >= 65 ? C.warn : C.accent),
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
  /// Пока идёт первый показ ([_initialJumpDone]), прыжок повторяется, пока не окажемся в самом
  /// конце и предел прокрутки перестанет меняться (см. [_retryInitialJump]). Дальше следование
  /// проверяется в сам момент прыжка, а не в момент постановки в очередь: между ними человек
  /// успевает отлистать вверх — и раньше список всё равно прыгал вниз, после чего снова считал
  /// себя «внизу» и залипал там навсегда. Пока человек держит палец на экране, не прыгаем вовсе.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initial = !_initialJumpDone;
      if (!initial && !_follow) return;
      if (initial) {
        // Пока грузится история, прыгать некуда: в списке ещё прошлый разговор (или он пуст).
        // Ждать здесь нечего — приход истории сам поменяет состояние, и слушатель позовёт
        // нас заново, с уже свежим счётом попыток.
        if (ref.read(agentThreadProvider).loading) return;
        // Список может быть ещё не построен: пробуем на следующем кадре, но не бесконечно.
        if (!_scroll.hasClients) {
          _retryInitialJump();
          return;
        }
      } else {
        if (!_scroll.hasClients) return;
        if (_scroll.position.isScrollingNotifier.value) return;
      }
      final bottom = _scroll.position.maxScrollExtent;
      _selfScroll = true;
      _scroll.jumpTo(bottom);
      _selfScroll = false;
      if (!initial) return;
      _retryInitialJump(
        atBottom: _scroll.position.pixels >= bottom - 1,
        stable: bottom == _initialJumpExtent,
        extent: bottom,
      );
    });
  }

  /// Считает попытку первого прыжка и решает, повторять ли её.
  ///
  /// Повтор нужен, пока не окажемся в самом конце и предел прокрутки перестанет меняться: у
  /// ленивого списка он сначала оценка, и настоящая высота хвоста появляется только после того,
  /// как хвост построен (а разметка и картинки добавляют высоты и позже). Потолок попыток —
  /// чтобы вечно доезжающее содержимое не держало экран в прыжках.
  ///
  /// Побочно: обновляет [_initialJumpExtent] и закрывает первый показ — [_initialJumpDone] и
  /// [_follow], после чего список ведёт себя как обычно.
  void _retryInitialJump({
    bool atBottom = false,
    bool stable = false,
    double? extent,
  }) {
    _initialJumpExtent = extent ?? _initialJumpExtent;
    _initialJumpTries++;
    if (_initialJumpTries < _maxInitialJumpTries && (!atBottom || !stable)) {
      _scrollToBottomSoon();
      return;
    }
    _initialJumpDone = true;
    // В первом показе истории вниз мог оттянуть сам список, а не человек: раз мы в конце,
    // считаем, что смотрим конец разговора, — иначе ответ агента писался бы без автопрокрутки.
    _follow = true;
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

/// Карточка вызова инструмента: подпись вызова и его вывод целиком.
///
/// Прятать вывод за нажатием не нужно: в переписке важно, что агент сделал, и лишний тап
/// за каждой командой только мешал бы. Имени инструмента и значка вида тоже нет — по подписи
/// (команда, путь, шаблон) и так видно, что произошло.
class _ToolCard extends StatelessWidget {
  /// Вызов инструмента со всем, что о нём известно.
  final AgentTool tool;

  /// Карточка вызова инструмента.
  const _ToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    final summary = tool.summary;
    // пустые строки вывода убираем: они съедают высоту сообщения, ничего не сообщая
    final output = _compactLines(tool.output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (summary.isNotEmpty)
              Flexible(
                child: SelectableText(
                  summary,
                  style: const TextStyle(
                    color: C.fg2,
                    fontSize: _textSize,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            // Значок состояния оставляем: без него не видно, вызов ещё идёт или упал.
            if (tool.running)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (tool.isError)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.error_outline, size: 16, color: C.danger),
              ),
          ],
        ),
        if (output.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              output,
              style: const TextStyle(
                color: C.fg3,
                fontSize: _textSize,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// Пункт переписки на экране: одно сообщение вместе со всем, что к нему относится.
///
/// Отдельным типом от [AgentItem]: тот описывает ответ агента целиком, а на экране он
/// разворачивается в несколько сообщений (см. `_AgentThreadScreenState._entries`).
class _Entry {
  /// Вид пункта: вопрос, кусок текста, «размышления», карточка команды, прямая команда
  /// оболочки, служебная строка или ещё не начатый ответ.
  final _EntryKind kind;

  /// Текст сообщения: вопрос, кусок ответа или вывод команды.
  final String text;

  /// Вызов инструмента — у вида [_EntryKind.tool].
  final AgentTool? tool;

  /// Команда — у вида [_EntryKind.bash].
  final String command;

  /// Ошибка прогона, показываемая под текстом этого сообщения.
  final String error;

  /// Пункт переписки.
  const _Entry(
    this.kind, {
    this.text = '',
    this.tool,
    this.command = '',
    this.error = '',
  });

  /// Что уйдёт в буфер по кнопке «скопировать».
  ///
  /// У команды — она сама и её вывод: отдельно друг от друга они бесполезны. У «размышлений»
  /// и текста — сам текст; у служебной строки копировать нечего, и кнопки у неё нет.
  String get copyText => switch (kind) {
    _EntryKind.tool => [
      tool?.summary ?? '',
      tool?.output ?? '',
    ].where((s) => s.trim().isNotEmpty).join('\n'),
    _EntryKind.bash => ['\$ $command', text]
        .where((s) => s.trim().isNotEmpty)
        .join('\n'),
    _ => text,
  };

  /// Копия с добавленной ошибкой прогона (остальные поля не меняются).
  _Entry copyWith({String? error}) => _Entry(
    kind,
    text: text,
    tool: tool,
    command: command,
    error: error ?? this.error,
  );
}

/// Вид пункта переписки на экране; по нему выбирается оформление сообщения.
enum _EntryKind { user, text, reasoning, tool, bash, note, waiting }

/// Копирует текст сообщения в буфер обмена и подтверждает это коротким сообщением.
///
/// Свободная функция, а не метод экрана: кнопка есть и у карточки команды, а карточка —
/// отдельный виджет. Проверка `context.mounted` обязательна — запись в буфер асинхронная, и
/// экран за это время могли закрыть.
Future<void> copyMessage(BuildContext context, String text) async {
  if (text.trim().isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) snack(context, 'Скопировано');
}

/// Предел попыток доехать до конца переписки при её открытии.
///
/// Кадров, а не миллисекунд: до этого предела список продолжает строиться, и прыжок в конец
/// повторяется. Больше сорока кадров — это уже дольше, чем человек готов ждать молчащей
/// прокрутки; если разметка доезжает позже, это видно, но список уже показывает конец.
const _maxInitialJumpTries = 40;

/// Убирает пустые строки из служебного текста: вывода команды и «размышлений».
///
/// И то и другое приходит с пустыми строками пачками (разделители прогресса, отступы
/// форматирования) — в переписке они ничего не сообщают, зато удлиняют сообщение. Отступы
/// в начале строки сохраняем: в выводе кода они значат вложенность.
String _compactLines(String text) => text
    .split('\n')
    .map((line) => line.trimRight())
    .where((line) => line.trim().isNotEmpty)
    .join('\n')
    .trim();

/// Кегль текста сообщений: один и тот же у ответа, команды и «размышлений».
///
/// Совпадает с `fontSize` обычного абзаца разметки (`markdownStyle`): ответ модели приходит
/// разметкой, и другой кегль у остальных сообщений выглядел бы вставкой из другого приложения.
const _textSize = 14.0;

/// Ширина кнопки «скопировать» вместе с её полями: на неё уменьшается предел ширины пузыря,
/// потому что кнопка стоит вне пузыря и пара должна целиком влезать в отведённое место.
const _copyButtonWidth = 30.0;

/// Ширина пары кнопок у служебного сообщения — «скопировать» и «раскрыть».
///
/// Кнопок может быть две, и предел ширины пузыря считается по обеим сразу: иначе у
/// раскрытого служебного сообщения пара кнопок вылезла бы за предел ширины переписки.
const _togglesWidth = 2 * _copyButtonWidth;

/// Сколько символов первой строки видно у свёрнутого служебного сообщения.
///
/// Строка всё равно режется по ширине экрана: числом ограничивается только то, что попадает
/// в виджет — рвать на нём километровую строку вывода команды нечего.
const _collapsedChars = 160;

/// Кнопка «раскрыть сообщение» — у «размышлений», вызовов инструментов и прямых команд.
///
/// Стоит рядом с кнопкой копирования: обе — действия над сообщением, и искать их разбросанными
/// по тексту не приходится. Стрелка вниз — раскрыть, вверх — свернуть.
class _ExpandButton extends StatelessWidget {
  /// Раскрыто ли сообщение сейчас: от этого зависит направление стрелки и подсказка.
  final bool expanded;

  /// Что делать при нажатии.
  final VoidCallback onPressed;

  /// Кнопка раскрытия.
  const _ExpandButton({required this.expanded, required this.onPressed});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: expanded ? 'Свернуть' : 'Показать целиком',
    onPressed: onPressed,
    // вид тот же, что у копирования: две кнопки в одном ряду не должны выглядеть по-разному
    icon: Icon(
      expanded ? Icons.unfold_less : Icons.unfold_more,
      size: 14,
      color: C.fg3.withValues(alpha: 0.45),
    ),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
  );
}

/// Свёрнутое служебное сообщение: одна строка — первое, что в нём есть.
///
/// Моноширинный шрифт и приглушённый цвет — те же, что у вывода, который строка заменяет:
/// по виду понятно, что это не ответ агента, а его работа.
class CollapsedLine extends StatelessWidget {
  /// Первая строка содержимого (обрезанная по длине).
  final String text;

  /// Свёрнутая строка.
  const CollapsedLine({required this.text, super.key});

  @override
  Widget build(BuildContext context) => Text(
    text.trim().isEmpty ? 'пусто' : text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: C.fg3,
      fontSize: _textSize,
      fontFamily: 'monospace',
      height: 1.35,
      // пустая строка вывода не должна выглядеть как щель в пузыре: место по высоте остаётся
      // тем же, что у настоящей строки
      fontStyle: text.trim().isEmpty ? FontStyle.italic : FontStyle.normal,
    ),
  );
}

/// Кнопка «скопировать сообщение» — одна и та же у пузырей и у карточек команд.
///
/// Нужна, чтобы копировать целиком, не выделяя текст пальцем: выделение на телефоне попадает
/// мимо нужных строк, а команду с выводом так копировать неудобно совсем.
class _CopyButton extends StatelessWidget {
  /// Текст, который уйдёт в буфер обмена.
  final String text;

  /// Кнопка копирования.
  const _CopyButton({required this.text});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Скопировать сообщение',
    // копировать пустое нечего: у ещё не начатого ответа и служебных строк кнопки и нет
    onPressed: text.trim().isEmpty ? null : () => copyMessage(context, text),
    // Приглушённее остальных иконок: кнопка стоит вне пузыря и не должна спорить за внимание
    // с содержимым сообщения — оттенок берём от fg3, своего цвета для неё в палитре нет.
    icon: Icon(
      Icons.content_copy,
      size: 14,
      color: C.fg3.withValues(alpha: 0.45),
    ),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
  );
}

/// Карточка прямой команды оболочки: строка команды и её вывод целиком.
///
/// Такую команду запускал не агент, а харнесс по просьбе клиента; прятать её вывод за
/// нажатием не нужно — раскрывать его пришлось бы каждый раз, чтобы просто прочитать ответ.
class _BashCard extends StatelessWidget {
  /// Команда целиком, как её запускали.
  final String command;

  /// Вывод команды.
  final String output;

  /// Карточка команды.
  const _BashCard({required this.command, required this.output});

  @override
  Widget build(BuildContext context) {
    // пустые строки вывода убираем: команда печатает их пачками, а несут они только высоту
    final text = _compactLines(output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          '\$ $command',
          style: const TextStyle(
            color: C.fg2,
            fontSize: _textSize,
            fontFamily: 'monospace',
          ),
        ),
        if (text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              text,
              style: const TextStyle(
                color: C.fg3,
                fontSize: _textSize,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// «Размышления» модели: полный текст, приглушённый и без раскрытия.
///
/// Мешать чтению они не будут и так: они идут отдельным сообщением, приглушённым фоном и
/// цветом. Прятать их за нажатием значило бы заставлять человека лезть за ними каждый раз —
/// а это часть того, что модель на самом деле сделала.
class _ReasoningBlock extends StatelessWidget {
  /// Текст размышлений целиком; дописывается по мере генерации.
  final String text;

  /// Блок размышлений.
  const _ReasoningBlock({required this.text});

  @override
  Widget build(BuildContext context) => SelectableText(
    // пустые строки в размышлениях убираем: модель ставит их пачками, а несут они только высоту
    _compactLines(text),
    style: const TextStyle(
      color: C.fg2,
      fontSize: _textSize,
      height: 1.35,
    ),
  );
}
