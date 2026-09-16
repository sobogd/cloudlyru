import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../theme.dart';

/// Выбор папки в облаке для связки: только выбор из существующего, ничего не создаётся.
///
/// Ходит по дереву вглубь тапом по строке, как проводник: подъём — стрелкой вверх в шапке.
/// Возвращает id и путь выбранной папки (`Navigator.pop`), а что с ними делать, решает
/// вызывающий экран — здесь про связки не знают.
///
/// Всё, что не имеет смысла связывать, скрыто или недоступно:
///   • [hiddenIds] — системные папки (медиатека «Фото»): её содержимое показывает раздел
///     «Фото», и связка залила бы туда же вторую копию;
///   • [takenIds] — папки, уже занятые другой связкой: две связки на одну папку облака
///     затёрли бы пары зеркала друг друга (см. `SyncLinkRules`).
///
/// Системная «назад» — обычный отказ: экран закрывается без результата.
class CloudFolderPickerScreen extends StatefulWidget {
  /// [api] — клиент веб-сессии: по нему читается дерево папок, [hiddenIds] — что не показывать,
  /// [takenIds] — что уже занято другой связкой.
  const CloudFolderPickerScreen({
    super.key,
    required this.api,
    this.hiddenIds = const <String>{},
    this.takenIds = const <String>{},
  });

  final CloudlyApi api;
  final Set<String> hiddenIds;
  final Set<String> takenIds;

  @override
  State<CloudFolderPickerScreen> createState() =>
      _CloudFolderPickerScreenState();
}

/// Состояние экрана: путь от корня облака, содержимое текущей папки и ход загрузки.
class _CloudFolderPickerScreenState extends State<CloudFolderPickerScreen> {
  /// Путь от корня: последний шаг — папка, содержимое которой показано.
  ///
  /// У первого шага id нет: корень облака адресуется отсутствием родителя, а его настоящий id
  /// приходит в ответе на листинг (`FolderView.parentId`) — им шаг и заполняется.
  final List<({String? id, String name})> _crumbs = [
    (id: null, name: 'Облако'),
  ];

  /// Папки текущего уровня и признак того, что за страницей есть ещё (см. [FolderView.hasMore]).
  List<({String id, String name})> _folders = const [];
  String? _nextAfter;
  bool _more = false;

  /// Идёт чтение уровня: список не показывается, пока не пришёл ответ.
  bool _loading = true;

  /// Текст отказа: показывается вместо списка, с кнопкой «Повторить».
  String? _error;

  /// id папки, которую читаем сейчас (родитель уровня), и признак «читаем следующую страницу».
  String? _parentId;
  bool _loadingMore = false;

  /// Id текущей папки: у корня он появляется только из ответа сервера.
  String get _currentId => _crumbs.last.id ?? '';

  /// Путь текущей папки для подписи — из имён шагов, корень в подпись не входит.
  String get _currentPath => _crumbs
      .skip(1)
      .map((c) => c.name)
      .join(' / ');

  @override
  void initState() {
    super.initState();
    unawaited(_load(null));
  }

  /// Прочитать уровень: [parentId] — папка, `null` — корень облака.
  ///
  /// Побочные эффекты: запрос к серверу и состояние экрана. Ошибка не выбрасывается: её текст
  /// показывается вместо списка, иначе человек видел бы пустую папку вместо отказа сети.
  Future<void> _load(String? parentId) async {
    setState(() {
      _loading = true;
      _error = null;
      _parentId = parentId;
    });
    try {
      final view = await widget.api.listFolder(parentId);
      if (!mounted || _parentId != parentId) return;
      setState(() {
        // корень узнаётся по ответу: листинг без родителя возвращает id корневой папки
        if (_crumbs.last.id == null && view.parentId.isNotEmpty) {
          _crumbs[_crumbs.length - 1] = (
            id: view.parentId,
            name: _crumbs.last.name,
          );
        }
        _folders = _visible(view.folders);
        _nextAfter = view.nextAfter;
        _more = view.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _parentId != parentId) return;
      setState(() {
        _loading = false;
        _error = _errText(e);
      });
    }
  }

  /// Следующая страница уровня: содержимое папки приходит порциями по именам.
  ///
  /// Ошибка ничего не ломает: уже показанные папки остаются, страницу можно запросить снова.
  Future<void> _loadMore() async {
    final after = _nextAfter;
    if (after == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final view = await widget.api.listFolder(_parentId, after: after);
      if (!mounted) return;
      setState(() {
        _folders = [..._folders, ..._visible(view.folders)];
        _nextAfter = view.nextAfter;
        _more = view.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Папки уровня без тех, что связывать нельзя.
  List<({String id, String name})> _visible(List<FolderEntry> folders) => [
    for (final f in folders)
      if (!widget.hiddenIds.contains(f.id)) (id: f.id, name: f.name),
  ];

  /// Зайти в папку: шаг добавляется в путь, уровень читается заново.
  void _enter(({String id, String name}) folder) {
    setState(() => _crumbs.add((id: folder.id, name: folder.name)));
    unawaited(_load(folder.id));
  }

  /// Подняться на уровень вверх: шаги пути после [index] уходят, уровень перечитывается.
  void _upTo(int index) {
    if (index >= _crumbs.length - 1) return;
    setState(() => _crumbs.removeRange(index + 1, _crumbs.length));
    unawaited(_load(_crumbs.last.id));
  }

  /// Закрыть экран с выбранной папкой: id — для связки, путь — для подписи в списке связок.
  void _choose() {
    final id = _currentId;
    if (id.isEmpty) return;
    Navigator.of(context).pop((id: id, path: _currentPath));
  }

  @override
  Widget build(BuildContext context) {
    final taken = widget.takenIds.contains(_currentId);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(
          // Стрелка вверх ведёт на уровень выше по дереву облака и в корне выключена:
          // системный «назад» здесь закрывает экран, а не поднимает по дереву
          icon: const Icon(Icons.arrow_upward, color: C.fg),
          onPressed: _crumbs.length > 1 ? () => _upTo(_crumbs.length - 2) : null,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Папка в облаке',
              style: TextStyle(color: C.fg, fontSize: 17),
            ),
            Text(
              _currentPath.isEmpty ? 'корень облака' : _currentPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: (_currentId.isEmpty || taken) ? null : _choose,
            child: const Text('Связать'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              taken
                  ? 'Эта папка уже связана с папкой на устройстве. Выберите другую или зайдите '
                        'во вложенную.'
                  : 'Папка выбирается из существующих — новых в облаке не заводится. '
                        'Содержимое папки на устройстве появится прямо здесь.',
              style: TextStyle(
                color: taken ? C.danger : C.fg3,
                fontSize: 11,
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body()),
          if (_more)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'показаны не все папки',
                      style: const TextStyle(color: C.fg3, fontSize: 11),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
                    child: const Text('Показать ещё'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Содержимое уровня: список папок, отказ с повтором или пустая папка.
  Widget _body() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: C.danger, fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => unawaited(_load(_parentId)),
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }
    if (_folders.isEmpty) {
      return Center(
        child: Text(
          _loading ? 'читаю папки…' : 'Вложенных папок нет',
          style: const TextStyle(color: C.fg3),
        ),
      );
    }
    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, i) {
        final folder = _folders[i];
        // занятая папка помечена в строке: иначе человек видел бы только «Связать» серой
        // кнопкой и не понимал, почему
        final busy = widget.takenIds.contains(folder.id);
        return ListTile(
          leading: const Icon(Icons.folder, color: C.accent),
          title: Text(folder.name, style: const TextStyle(color: C.fg)),
          subtitle: busy
              ? const Text(
                  'уже связана с устройством',
                  style: TextStyle(color: C.fg3, fontSize: 11),
                )
              : null,
          trailing: const Icon(Icons.chevron_right, color: C.fg3),
          onTap: () => _enter(folder),
        );
      },
    );
  }
}

/// Текст отказа для строки ошибки: понятное сообщение сервера или общая фраза.
///
/// Сырое исключение транспорта человеку ничего не объясняет, а `ApiException` несёт текст
/// сервера (в нём бывает суть: «папка не найдена», «нет доступа»).
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось прочитать папки облака';
