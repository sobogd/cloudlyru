import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';

/// Пауза после последнего нажатия, через которую уходит автосохранение.
///
/// Смысл выдержки — не отправлять запрос на каждую букву: пока человек печатает, сохранение
/// откладывается, а сохраняется то, что набрано к моменту остановки. Слишком короткая пауза
/// даёт поток запросов, слишком длинная — потерю последних символов при быстром выходе.
const _autosaveDelay = Duration(milliseconds: 1200);

/// Редактор заметки: полный текст, приоритет и действия «сохранить»/«удалить».
///
/// Экран служит и созданию, и правке: [note] = null — новая заметка. Новую заметку на сервере
/// не заводят заранее (иначе «+» без единого символа плодил бы пустышки), а создают при первом
/// непустом сохранении; с этого момента редактор хранит `id` и дальше правит ту же запись.
///
/// Текст сохраняется сам: спустя [_autosaveDelay] после последнего нажатия, сразу при смене
/// приоритета и при выходе с экрана. Кнопка «Сохранить» нужна для немедленной записи, когда
/// ждать выдержку не хочется. Переносы строк, сделанные в поле ввода, доходят до сервера как
/// есть — это и есть содержимое заметки.
class NoteEditorScreen extends ConsumerStatefulWidget {
  /// Правимая заметка; `null` — редактор новой заметки.
  final Note? note;

  /// Редактор заметки.
  const NoteEditorScreen({super.key, this.note});

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

/// Состояние редактора: текст, приоритет, флаги сохранения и перехвата выхода.
class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  /// Поле ввода текста заметки; для новой — пустое, для существующей — её текст.
  late final TextEditingController _text;

  /// Приоритет, выбранный на экране.
  late String _priority;

  /// `id` заметки на сервере; `null` — ещё не создана.
  String? _id;

  /// Есть несохранённые правки: на это опирается перехват выхода и пауза автосохранения.
  bool _dirty = false;

  /// Идёт запись на сервер: гаснет после ответа, на нём же перерисовывается «Сохраняю…».
  bool _saving = false;

  /// Выход уже начат: второй перехват (повторный «назад») не запускает его заново.
  bool _leaving = false;

  /// Экран закрывается: `PopScope` перестаёт держать маршрут (см. [_close]).
  bool _closing = false;

  /// Заметка хоть раз записалась: это ответ списку, нужно ли его перечитывать.
  bool _saved = false;

  /// Текущая запись на сервер. Через него автосохранение и выход сериализуются: два запроса
  /// никогда не идут параллельно, а второй дожидается первого и записывает актуальное состояние.
  Future<String?>? _inFlight;

  /// Таймер паузы автосохранения.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _id = widget.note?.id;
    _priority = widget.note?.priority ?? 'low';
    _text = TextEditingController(text: widget.note?.text ?? '');
    _text.addListener(_onChanged);
  }

  @override
  void dispose() {
    // Запись к этому моменту уже сделана выходом (`PopScope`/кнопка) — таймер только снимаем,
    // чтобы он не сработал по уже исчезнувшему состоянию.
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  /// Правка текста: помечает заметку изменённой и откладывает автосохранение.
  ///
  /// Выдержка перезапускается на каждое нажатие, поэтому запрос уходит только после того, как
  /// человек перестал печатать.
  void _onChanged() {
    if (!_dirty) setState(() => _dirty = true);
    _debounce?.cancel();
    _debounce = Timer(_autosaveDelay, () => unawaited(_autosave()));
  }

  /// Смена приоритета: сохраняется сразу, без выдержки.
  ///
  /// Это одно нажатие, а не поток символов, и правка должна доехать до сервера даже тогда,
  /// когда человек тут же закрывает экран.
  void _setPriority(String priority) {
    if (priority == _priority) return;
    setState(() {
      _priority = priority;
      _dirty = true;
    });
    _debounce?.cancel();
    unawaited(_autosave());
  }

  /// Автосохранение: тихая запись. Ошибку показываем подсказкой, экран не закрываем — правки
  /// ещё в поле, и человек может попробовать снова.
  Future<void> _autosave() async {
    if (_leaving) return;
    final error = await _persist();
    if (!mounted) return;
    if (error == null) {
      setState(() => _dirty = false);
    } else {
      snack(context, error);
    }
  }

  /// Кнопка «Сохранить»: немедленная запись с подтверждением, без выхода с экрана.
  Future<void> _saveNow() async {
    _debounce?.cancel();
    final error = await _persist();
    if (!mounted) return;
    if (error != null) {
      snack(context, error);
      return;
    }
    setState(() => _dirty = false);
    snack(context, 'Заметка сохранена');
  }

  /// Удаление заметки с подтверждением: насовсем, корзины у заметок нет.
  Future<void> _delete() async {
    final id = _id;
    if (id == null) {
      // Несозданную заметку удалять нечего — просто выходим.
      _close();
      return;
    }
    final ok = await confirmDialog(
      context,
      'Удалить заметку',
      'Заметка будет стёрта безвозвратно. Восстановить её нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    _debounce?.cancel();
    try {
      await ref.read(appStateProvider).api.deleteNote(id);
      if (!mounted) return;
      // Заметки больше нет: снимаем id и запрет на выход, иначе `PopScope` попытается
      // сохранить только что удалённое.
      _id = null;
      _saved = true;
      _dirty = false;
      _close();
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    }
  }

  /// Выход с экрана: сначала запись, потом закрытие.
  ///
  /// Пока правки не сохранены, маршрут не закрывается (`PopScope`), потому что системный «назад»
  /// иначе потерял бы последние набранные символы. Если записать не удалось, экран остаётся —
  /// закрыть его значило бы выбросить текст, который человек только что ввёл.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _debounce?.cancel();
    final error = await _persist();
    if (!mounted) return;
    if (error != null) {
      _leaving = false;
      snack(context, error);
      return;
    }
    setState(() => _dirty = false);
    _close();
  }

  /// Закрывает экран и возвращает списку признак «были записи» ([_saved]).
  ///
  /// `pop` откладывается до следующего кадра: `PopScope.canPop` рассчитан по прежнему состоянию,
  /// и вызов прямо сейчас снова перехватил бы закрытие. После перестроения флаг [_closing]
  /// пропускает `pop` без перехвата.
  void _close() {
    if (_closing) return;
    setState(() => _closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_saved);
    });
  }

  /// Записывает текущее состояние заметки, дожидаясь уже идущей записи.
  ///
  /// Возвращает `null` при успехе и текст ошибки при неудаче. Две записи никогда не идут
  /// параллельно: второй вызов ждёт первый и затем сохраняет уже актуальный текст — так
  /// автосохранение и выход не гонятся друг за другом, а последнее слово всегда за актуальным
  /// состоянием поля.
  Future<String?> _persist() async {
    final pending = _inFlight;
    if (pending != null) {
      await pending;
      return _persist();
    }
    final f = _doPersist();
    _inFlight = f;
    try {
      return await f;
    } finally {
      if (identical(_inFlight, f)) _inFlight = null;
    }
  }

  /// Одна запись на сервер.
  ///
  /// Пустой текст новой заметки сохранять нечего — возвращаем успех без запроса. Пустой текст
  /// существующей заметки её удаляет: заметка без содержимого бессмысленна, а стереть её из
  /// редактора иначе нечем (очистил текст — стёр заметку). Оба случая не ошибки, поэтому
  /// возвращают `null`.
  Future<String?> _doPersist() async {
    if (!mounted) return null;
    final text = _text.text;
    if (text.trim().isEmpty) {
      final id = _id;
      if (id == null) return null;
      try {
        setState(() => _saving = true);
        await ref.read(appStateProvider).api.deleteNote(id);
        _id = null;
        _saved = true;
        return null;
      } catch (e) {
        return _errText(e);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
    try {
      setState(() => _saving = true);
      final api = ref.read(appStateProvider).api;
      final saved = _id == null
          ? await api.createNote(text: text, priority: _priority)
          : await api.updateNote(_id!, text: text, priority: _priority);
      _id = saved.id;
      _saved = true;
      return null;
    } catch (e) {
      return _errText(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Пока есть несохранённые правки, маршрут не закрывается: сначала запись, потом выход.
      // `_closing` снимает этот запрет на время, когда запись уже прошла (см. [_close]).
      canPop: !_dirty || _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          // «Новая» только пока заметки нет ни на экране, ни на сервере: после первого автосейва
          // это уже обычная заметка, и заголовок не должен называть её новой.
          title: Text(
            (widget.note == null && _id == null) ? 'Новая заметка' : 'Заметка',
            style: const TextStyle(color: C.fg, fontSize: 18),
          ),
          actions: [
            IconButton(
              tooltip: 'Удалить',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
            TextButton(
              onPressed: _saving ? null : _saveNow,
              child: Text(_saving ? 'Сохраняю…' : 'Сохранить'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: _priorityPicker(),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + navBarInset(context)),
                child: TextField(
                  controller: _text,
                  // `expands` с неограниченными строками: поле занимает всю высоту экрана, чтобы
                  // длинная заметка не прокручивалась внутри маленького прямоугольника.
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  autofocus: widget.note == null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(color: C.fg, fontSize: 14.5, height: 1.35),
                  decoration: InputDecoration(
                    hintText: 'Текст заметки…',
                    hintStyle: const TextStyle(color: C.fg3, fontSize: 14, height: 1.35),
                    filled: true,
                    fillColor: C.surface,
                    contentPadding: const EdgeInsets.all(14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: C.brd),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: C.brd),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: C.accent),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Выбор приоритета: три уровня, по умолчанию низкий.
  Widget _priorityPicker() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'high', label: Text('Высокий')),
        ButtonSegment(value: 'medium', label: Text('Средний')),
        ButtonSegment(value: 'low', label: Text('Низкий')),
      ],
      selected: {_priority},
      showSelectedIcon: false,
      onSelectionChanged: (value) => _setPriority(value.first),
    );
  }
}

/// Текст ошибки для показа человеку: готовое сообщение [ApiException] или общая формулировка
/// для всего остального (ошибка разбора, наш баг), чей сырой `toString` ничего не объясняет.
String _errText(Object e) => e is ApiException ? e.message : 'не удалось сохранить заметку';
