import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Экран выбора файлов из облака для вложения в письмо: несколько файлов, навигация по папкам.
///
/// Возвращает `List<FolderEntry>` выбранных файлов (`Navigator.pop` со значением).
/// Логика листинга та же, что у «Файлов»: `listFolder` по текущей папке, страницы догружаются
/// до пяти за перечитку, остаток — кнопкой «Показать ещё».
typedef _Crumb = ({String? id, String name});

class FilePickerScreen extends ConsumerStatefulWidget {
  const FilePickerScreen({super.key});

  @override
  ConsumerState<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends ConsumerState<FilePickerScreen> {
  List<_Crumb> _stack = const [(id: null, name: 'Главная')];
  FolderView? _view;
  final Set<String> _selected = {};
  String? _error;
  String? _more;
  bool _busy = false;

  String? get _currentId => _stack.last.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _more = null;
    });
    final api = ref.read(appStateProvider).api;
    final parent = _currentId;
    try {
      var view = await api.listFolder(parent);
      var pages = 1;
      while (view.hasMore && view.nextAfter != null && pages < 5) {
        view = _merge(view, await api.listFolder(parent, after: view.nextAfter));
        pages++;
      }
      if (!mounted || parent != _currentId) return;
      setState(() {
        _view = view;
        _more = (view.hasMore && view.nextAfter != null) ? view.nextAfter : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  FolderView _merge(FolderView a, FolderView b) => FolderView(
        parentId: a.parentId,
        folders: [...a.folders, ...b.folders],
        entries: [...a.entries, ...b.entries],
        hasMore: b.hasMore,
        nextAfter: b.nextAfter,
      );

  void _loadMore() {
    final after = _more;
    final cur = _view;
    if (after == null || cur == null || _busy) return;
    setState(() => _busy = true);
    ref
        .read(appStateProvider)
        .api
        .listFolder(_currentId, after: after)
        .then((next) {
          if (!mounted || _view != cur) return;
          setState(() => _view = _merge(cur, next));
          _more = (next.hasMore && next.nextAfter != null) ? next.nextAfter : null;
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = _errText(e));
        })
        .whenComplete(() {
          if (mounted) setState(() => _busy = false);
        });
  }

  void _toggle(FolderEntry e) {
    setState(() {
      if (!_selected.remove(e.id)) _selected.add(e.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final selected = _selected;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(
          icon: const Icon(Icons.close, color: C.fg),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _stack.map((c) => c.name).join(' / '),
          style: const TextStyle(color: C.fg, fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: selected.isEmpty ? null : () => Navigator.pop(context, _entries()),
            child: Text(
              selected.isEmpty ? 'Прикрепить' : 'Прикрепить (${selected.length})',
              style: const TextStyle(color: C.accent),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(14, 4, 14, 14 + navBarInset(context)),
        children: [
          if (_stack.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.arrow_back, size: 16, color: C.fg3),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _stack.map((c) => c.name).join(' / '),
                      style: const TextStyle(color: C.fg3, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: const TextStyle(color: C.danger)),
            ),
          if (view != null) ...[
            for (final f in view.folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder, color: C.fg3),
                title: Text(f.name, style: const TextStyle(color: C.fg, fontSize: 14)),
                onTap: () {
                  setState(() => _stack = [..._stack, (id: f.id, name: f.name)]);
                  _load();
                },
              ),
            for (final e in view.entries) _entryTile(e),
            if (view.folders.isEmpty && view.entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('папка пуста', style: TextStyle(color: C.fg3)),
              ),
            if (_more != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: TextButton(
                    onPressed: _busy ? null : _loadMore,
                    child: const Text('Показать ещё'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _entryTile(FolderEntry e) {
    final size = e.size;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: _selected.contains(e.id),
      onChanged: (_) => _toggle(e),
      title: Text(e.name, style: const TextStyle(color: C.fg, fontSize: 14)),
      subtitle: (size == null) ? null : Text(fmtSize(size), style: const TextStyle(color: C.fg3, fontSize: 12)),
    );
  }

  List<FolderEntry> _entries() {
    final view = _view;
    if (view == null) return [];
    return view.entries.where((e) => _selected.contains(e.id)).toList();
  }
}

String _errText(Object e) => e is ApiException ? e.message : 'не удалось выполнить операцию';
