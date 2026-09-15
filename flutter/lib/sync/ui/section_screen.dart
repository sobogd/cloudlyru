import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import '../data/selection_rules.dart';
import '../device/device_files.dart';
import '../device/media_rules.dart';
import '../section.dart';
import '../sync_controller.dart';
import 'folder_tree_screen.dart';
import 'mirror_card.dart';

/// Сколько файлов показываем в списке: больше в ручном листании всё равно не нужно.
const int _listLimit = 2000;

/// Сколько держим результат обхода: переключение экранов не должно обходить диск заново.
const int _scanFreshMs = 60 * 1000;

/// Последний обход раздела в памяти.
///
/// Обход диска на десятках тысяч файлов — это секунды работы и сотни системных вызовов,
/// а по экранам ходят туда-сюда; свежий результат переиспользуем, по кнопке «Обновить» —
/// обходим заново.
class _ScanCache {
  static String? _key;
  static int _at = 0;
  static List<DeviceFile> _files = const [];
  static String _note = '';

  static (List<DeviceFile>, String)? get(String key) {
    final fresh = DateTime.now().millisecondsSinceEpoch - _at <= _scanFreshMs;
    if (key != _key || !fresh) return null;
    return (_files, _note);
  }

  /// Кнопка «Обновить»: кэш выбрасываем, обход идёт заново.
  static void clear() => _at = 0;

  static void put(String key, List<DeviceFile> files, String note) {
    _key = key;
    _at = DateTime.now().millisecondsSinceEpoch;
    _files = files;
    _note = note;
  }
}

/// Раздел со списком файлов выбранных папок, свежие — сверху. Ни статусов, ни прогресса
/// выгрузки здесь нет: раздел только показывает, что лежит на телефоне.
///
/// Обход диска идёт в фоне и умеет останавливаться: на телефоне десятки тысяч файлов,
/// и держать из-за них интерфейс нельзя.
class SectionScreen extends ConsumerStatefulWidget {
  const SectionScreen({super.key, required this.section});

  final Section section;

  @override
  ConsumerState<SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends ConsumerState<SectionScreen> {
  List<DeviceFile> _files = const [];
  List<String> _roots = const [];
  String _note = '';
  String _progress = '';
  bool _scanning = false;
  bool _cancelScan = false;

  /// Какие файлы уже лежат в облаке: считается по базе зеркала, чтобы в списке было видно
  /// не только «всего», но и по каждому файлу.
  Set<String> _synced = const {};

  SyncController get _sync => ref.read(syncControllerProvider);

  @override
  void initState() {
    super.initState();
    _roots = _selectedRoots();
    if (_roots.isNotEmpty) unawaited(_scan());
  }

  List<String> _selectedRoots() {
    final selection = _sync.selection;
    if (selection == null) return const [];
    return SelectionRules.scanRoots(selection.paths(widget.section));
  }

  String get _cacheKey => '${widget.section.storageKey}|${_roots.join('|')}';

  Future<void> _scan({bool force = false}) async {
    final roots = _selectedRoots();
    if (roots.isEmpty) {
      setState(() {
        _roots = const [];
        _files = const [];
        _note = '';
      });
      return;
    }
    _roots = roots;
    if (force) _ScanCache.clear();
    final key = _cacheKey;
    final cached = _ScanCache.get(key);
    if (cached != null) {
      // свежий обход уже есть в памяти: показываем сразу, диск не трогаем
      setState(() {
        _files = cached.$1;
        _note = cached.$2;
      });
      unawaited(_loadSynced(cached.$1));
      return;
    }

    _cancelScan = false;
    setState(() {
      _scanning = true;
      _progress = 'сканирую папки…';
    });
    // прогресс приходит из обхода десятками строк в секунду: перерисовываем его по таймеру,
    // а не на каждое сообщение — иначе кадры уходят на текст, который человек не читает
    final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted) setState(() {});
    });
    try {
      final result = await _sync.files.scan(
        _roots,
        limit: _listLimit,
        onProgress: (m) => _progress = m,
        isCancelled: () => _cancelScan || !mounted,
      );
      if (!mounted) return;
      final note = StringBuffer('файлов: ${result.total}');
      if (result.total > result.files.length) {
        note.write(', показаны первые ${result.files.length}');
      }
      if (result.unreadable > 0) {
        note.write(', папок без доступа: ${result.unreadable}');
      }
      if (result.capped) note.write(', обход упёрся в предел');
      if (_cancelScan) {
        // остановленный обход — не полный: в кэш его класть нельзя, иначе «Обновить»
        // ещё минуту показывал бы половину списка как готовый ответ
        setState(() {
          _files = result.files;
          _note = 'обход остановлен: найдено ${result.files.length}';
        });
      } else {
        _ScanCache.put(key, result.files, note.toString());
        setState(() {
          _files = result.files;
          _note = note.toString();
        });
        unawaited(_loadSynced(result.files));
      }
    } catch (e) {
      if (mounted) setState(() => _note = 'не удалось пройти папки: $e');
    } finally {
      ticker.cancel();
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Сверка «этот файл уже в облаке»: пара «путь + размер + дата» — то же правило, по которому
  /// зеркало считает файл выгруженным.
  Future<void> _loadSynced(List<DeviceFile> files) async {
    if (widget.section != Section.files) return;
    final store = _sync.mirrorStore;
    if (store == null) return;
    final rows = await store.files();
    if (!mounted) return;
    final out = <String>{};
    for (final file in files) {
      final row = rows[file.path];
      if (row != null && row.size == file.size && row.mtime == file.mtime) {
        out.add(file.path);
      }
    }
    setState(() => _synced = out);
  }

  Future<void> _openFolders() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FolderTreeScreen(section: widget.section),
      ),
    );
    // Обход после возврата запускает слушатель выбора в build: он сработает и на «поменяли
    // папку на другую с тем же числом», и на «стало больше». Второй обход здесь означал бы,
    // что телефон обходят дважды за одно действие.
  }

  Future<void> _enqueue() async {
    final result = await _sync.refreshQueue();
    if (!mounted) return;
    snack(context, result?.text() ?? 'очередь не обновлена');
  }

  String get _title => switch (widget.section) {
    Section.photos => 'Фото и видео',
    Section.files => 'Файлы',
  };

  String get _emptyTitle => switch (widget.section) {
    Section.photos => 'Папки для фото и видео не выбраны',
    Section.files => 'Папки для файлов не выбраны',
  };

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(syncControllerProvider.select((c) => c.access));
    final status = ref.watch(
      syncControllerProvider.select((c) => c.mirrorStatus),
    );

    // выбор папок меняется на другом экране: вернувшись, раздел должен показать новый набор.
    // Сравниваем сам набор путей, а не их число: «поменяли папку на другую» числа не меняет,
    // а список файлов при этом совсем другой. Значением слушателя идёт строка, а не список:
    // списки в Dart сравниваются по ссылке, и слушатель срабатывал бы на каждое обновление
    // состояния — то есть на каждый шаг выгрузки.
    ref.listen(
      syncControllerProvider.select((c) {
        final paths =
            c.selection?.paths(widget.section).toList() ?? const <String>[];
        paths.sort();
        return paths.join('\n');
      }),
      (prev, next) {
        if (prev != next) unawaited(_scan(force: true));
      },
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_title, style: const TextStyle(color: C.fg, fontSize: 17)),
            Text(
              switch (true) {
                _ when _roots.isEmpty => 'папки не выбраны',
                _ when _scanning => _progress.isEmpty ? 'сканирую…' : _progress,
                _ => _note,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (_scanning)
            TextButton(
              onPressed: () => setState(() => _cancelScan = true),
              child: const Text('Стоп'),
            )
          else
            IconButton(
              tooltip: 'Обновить',
              onPressed: _roots.isEmpty
                  ? null
                  : () => unawaited(_scan(force: true)),
              icon: const Icon(Icons.refresh, color: C.fg),
            ),
          IconButton(
            tooltip: 'Папки раздела',
            onPressed: () => unawaited(_openFolders()),
            icon: const Icon(Icons.folder_open_outlined, color: C.fg),
          ),
        ],
      ),
      body: switch (true) {
        _ when access == SyncAccess.denied => _noAccess(),
        _ when _roots.isEmpty => _nothingChosen(),
        _ => Column(
          children: [
            if (widget.section == Section.files)
              MirrorCard(status: status)
            else
              _photoSummary(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                _roots.join('\n'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.fg3, fontSize: 11),
              ),
            ),
            if (_scanning) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _files.isEmpty && !_scanning
                  ? _centered('Ничего не найдено в выбранных папках')
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (context, i) => _fileRow(_files[i]),
                    ),
            ),
          ],
        ),
      },
    );
  }

  Widget _fileRow(DeviceFile file) {
    final inCloud = widget.section == Section.files
        ? _synced.contains(file.path)
        : null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                MediaRules.isVideo(file.name)
                    ? Icons.movie_outlined
                    : (MediaRules.isImage(file.name)
                          ? Icons.image_outlined
                          : Icons.insert_drive_file_outlined),
                color: C.accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg, fontSize: 15),
                    ),
                    Text(
                      '${file.dir} · ${fmt(file.size)} · ${_dateText(file.mtime)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.fg3, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (inCloud != null)
                Text(
                  inCloud ? 'в облаке' : 'ждёт',
                  style: TextStyle(
                    color: inCloud ? C.fg3 : C.accent,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  /// Раздел «Фото» льётся в медиатеку плоско и вручную: показываем, сколько нашлось,
  /// и даём поставить найденное в очередь.
  Widget _photoSummary() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Panel(
        child: Row(
          children: [
            Expanded(
              child: Text(
                _scanning ? 'ищу фото и видео…' : 'найдено: ${_files.length}',
                style: const TextStyle(color: C.fg, fontSize: 13),
              ),
            ),
            FilledButton(
              onPressed: _scanning || _files.isEmpty
                  ? null
                  : () => unawaited(_enqueue()),
              child: const Text('Поставить в очередь'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noAccess() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Нужен доступ ко всем файлам',
              style: TextStyle(
                color: C.fg,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Без него не видно ни дерева папок, ни файлов. Приложение личное, ставится APK-ом.',
              style: TextStyle(color: C.fg3, fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () => _sync.requestAccess(),
              child: const Text('Открыть настройки'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nothingChosen() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _emptyTitle,
            style: const TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Отметьте галочками папки телефона — их содержимое появится здесь, '
            'свежие файлы сверху.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => unawaited(_openFolders()),
            child: const Text('Выбрать папки'),
          ),
        ],
      ),
    );
  }

  Widget _centered(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 13)),
      ),
    );
  }
}

/// Дата файла: полная, а не «когда»-относительная — в списке телефона важнее точное время
/// снимка или правки, чем «3 дня назад».
String _dateText(int mtime) {
  if (mtime <= 0) return 'дата неизвестна';
  return fullDate(DateTime.fromMillisecondsSinceEpoch(mtime));
}
