import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

class FolderDetailScreen extends ConsumerStatefulWidget {
  final String folderId;
  const FolderDetailScreen({super.key, required this.folderId});

  @override
  ConsumerState<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends ConsumerState<FolderDetailScreen> {
  FolderMeta? _meta;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await ref.read(appStateProvider).api.folderMeta(widget.folderId);
      if (mounted) setState(() {
        _meta = m;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _rename() async {
    final m = _meta;
    if (m == null) return;
    final next = await promptDialog(context, 'Новое имя папки', initial: m.name);
    if (next == null || next.trim().isEmpty || next == m.name) return;
    try {
      await ref.read(appStateProvider).api.renameFolder(m.id, next.trim());
      setState(() => _notice = 'Имя изменено');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _cut() async {
    final m = _meta;
    if (m == null) return;
    try {
      await ref.read(appStateProvider).api.setClipboard('folder', m.id, 'cut');
      if (mounted) snack(context, 'Папка вырезана. Откройте нужную папку и нажмите «Вставить».');
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _delete() async {
    final m = _meta;
    if (m == null) return;
    final ok = await confirmDialog(context, 'Удалить папку «${m.name}»?', 'Папка с содержимым уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.deleteFolder(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: C.fg), onPressed: () => Navigator.pop(context)),
        title: Text(m?.name ?? 'Папка', style: const TextStyle(color: C.fg, fontSize: 16)),
        actions: [
          IconButton(tooltip: 'Переименовать', icon: const Icon(Icons.edit_outlined, color: C.fg), onPressed: _rename),
          IconButton(tooltip: 'Вырезать', icon: const Icon(Icons.content_cut, color: C.fg), onPressed: _cut),
          IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.danger), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          if (_notice != null) Text(_notice!, style: const TextStyle(color: C.ok)),
          if (m == null && _error == null)
            const Center(child: CircularProgressIndicator())
          else if (m != null)
            Panel(child: Column(children: [
              MetaRow('Имя', m.name),
              MetaRow('Расположение', m.path),
              MetaRow('Вложенные папки', '${m.folders}'),
              MetaRow('Файлы', '${m.entries}'),
              if (m.createdAt != null) MetaRow('Создана', fmtLocal(m.createdAt) ?? m.createdAt!),
              if (m.updatedAt != null) MetaRow('Изменена', fmtLocal(m.updatedAt) ?? m.updatedAt!),
            ])),
        ],
      ),
    );
  }
}
