import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'note_editor_screen.dart';

/// Экран раздела «Заметки»: список заметок и вход в редактор.
///
/// Порядок строк задаёт сервер (приоритет, затем свежие правки) и клиент его не пересобирает:
/// один источник правила — одна причина для расхождений с телефоном-соседом. Поэтому после
/// возврата из редактора список не правится на месте, а перечитывается целиком: заметку могли
/// сохранить, удалить или поднять в приоритете, и место строки в списке изменится.
///
/// Сам текст заметки в списке не хранится в модели-состоянии: снимок ответа сервера лежит
/// как есть, а превью считается на каждом построении.
class NotesScreen extends ConsumerStatefulWidget {
  /// Экран списка заметок.
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

/// Состояние списка: снимок заметок, ошибка загрузки и признак «идёт запрос».
class _NotesScreenState extends ConsumerState<NotesScreen> {
  /// Заметки; `null` — ответа ещё не было (показывается спиннер). Пустой список вызывает
  /// отдельное пустое состояние, поэтому «нет ответа» и «ответ пустой» различимы.
  List<Note>? _notes;

  /// Текст последней неудачи: заменяет собой список, потому что показывать наполовину
  /// устаревший список заметок хуже, чем честно сказать, что он не загрузился.
  String? _error;

  /// Идёт запрос списка: защита от повторного нажатия «Обновить» и от гонки двух загрузок.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Читает список заметок.
  ///
  /// Побочно: перерисовка экрана; ошибка идёт в [_error] и заменяет список.
  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final notes = await ref.read(appStateProvider).api.notes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errText(e);
        _loading = false;
      });
    }
  }

  /// Открывает редактор — существующей заметки ([note]) или новой (без аргумента).
  ///
  /// После возврата список перечитывается, если редактор что-то записал (он возвращает `true`):
  /// без этого новая заметка не появилась бы в списке до следующего открытия раздела. Когда
  /// человек ничего не менял, перезагрузка не нужна — лишний запрос к серверу.
  Future<void> _open([Note? note]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => NoteEditorScreen(note: note)),
    );
    if (mounted && changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Заметки', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Новая заметка',
        backgroundColor: C.accent,
        foregroundColor: C.accentFg,
        onPressed: () => _open(),
        child: const Icon(Icons.add),
      ),
      body: _body(),
    );
  }

  /// Тело экрана: спиннер, ошибка, пустое состояние или список.
  Widget _body() {
    final notes = _notes;
    if (notes == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    if (notes!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Заметок пока нет. Нажмите «+», чтобы добавить первую.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    // `now` берётся один раз на весь список: даты всех строк считаются по одному моменту,
    // иначе у соседних заметок «сегодня» могло бы смениться посреди построения.
    final now = DateTime.now();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        // снизу — запас под кнопку «+» и системную полосу навигации
        padding: EdgeInsets.only(bottom: 88 + navBarInset(context)),
        itemCount: notes.length,
        separatorBuilder: (_, _) => const Divider(height: 1, color: C.brd),
        itemBuilder: (context, i) => _tile(notes[i], now),
      ),
    );
  }

  /// Строка списка: полоска приоритета, начало текста и подпись «приоритет · дата правки».
  Widget _tile(Note note, DateTime now) {
    return ListTile(
      onTap: () => _open(note),
      // Цветная полоска слева читается быстрее подписи, но полагаться только на цвет нельзя:
      // тот же приоритет назван словом в подзаголовке — для тех, кто цвета не различает.
      leading: Container(
        width: 6,
        height: 36,
        decoration: BoxDecoration(
          color: priorityColor(note.priority),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      title: Text(
        notePreview(note.text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 14.5),
      ),
      subtitle: Text(
        '${priorityLabel(note.priority)} · ${listDate(DateTime.parse(note.updatedAt), now)}',
        style: const TextStyle(color: C.fg3, fontSize: 12.5),
      ),
    );
  }
}

/// Текст ошибки для показа человеку.
///
/// [ApiException] несёт готовое сообщение сервера или сети, поэтому его `toString` и есть то,
/// что нужно показать. Всё остальное — ошибка разбора или наш баг, и её сырой `toString` с типом
/// исключения человеку ничего не объясняет: показываем общую формулировку.
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось загрузить заметки';

/// Первые символы заметки для строки списка: переносы строк схлопываются в пробелы (в одну
/// строку списка они всё равно не влезут), длинный текст обрезается. Полный текст с сохранёнными
/// переносами виден в редакторе, поэтому обрезка здесь ничего не теряет.
String notePreview(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
}

/// Название приоритета для человека. Неизвестное значение сервера показывается низким: как и
/// с сортировкой, порча одной записи не должна ломать весь список.
String priorityLabel(String priority) => switch (priority) {
      'high' => 'Высокий',
      'medium' => 'Средний',
      _ => 'Низкий',
    };

/// Цвет полоски приоритета: высокий — красный, средний — жёлтый, низкий — приглушённый.
/// Цвета взяты из темы, чтобы не спорить с остальными экранами.
Color priorityColor(String priority) => switch (priority) {
      'high' => C.danger,
      'medium' => C.warn,
      _ => C.fg3,
    };
