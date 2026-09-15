import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../upload/upload_queue.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'file_detail.dart';
import 'folder_detail.dart';

typedef Crumb = ({String? id, String name});

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  List<Crumb> _stack = const [(id: null, name: 'Главная')];
  FolderView? _view;
  String? _error;
  String? _notice;
  ClipboardView? _clip;
  String? _photoFolderId;

  String? get _currentId => _stack.last.id;

  @override
  void initState() {
    super.initState();
    final state = ref.read(appStateProvider);
    _photoFolderId = state.user?.photoFolderId;
    final ui = state.settings.ui.read();
    final savedStack = ui['files']?['stack'] as List?;
    if (savedStack != null && savedStack.isNotEmpty) {
      _stack = savedStack
          .whereType<Map>()
          .map(
            (e) =>
                (id: (e['id'] as String?), name: (e['name'] as String?) ?? ''),
          )
          .toList();
    }
    _load();
    _loadClip();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final v = await ref.read(appStateProvider).api.listFolder(_currentId);
      if (mounted) setState(() => _view = v);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadClip() async {
    try {
      final c = await ref.read(appStateProvider).api.clipboard();
      if (mounted) setState(() => _clip = c);
    } catch (_) {}
  }

  Future<void> _mkdir() async {
    final name = await promptDialog(context, 'Новая папка');
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref.read(appStateProvider).api.mkdir(name.trim(), _currentId);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _paste() async {
    final target = _view?.parentId ?? _currentId;
    if (target == null) return;
    try {
      final r = await ref.read(appStateProvider).api.pasteClipboard(target);
      setState(
        () => _notice =
            '${r['action'] == 'copied' ? 'Скопировано' : 'Перенесено'}: ${r['name']}',
      );
      await _load();
      await _loadClip();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _clearClip() async {
    try {
      await ref.read(appStateProvider).api.clearClipboard();
      setState(() => _clip = null);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _pickUpload() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final target = _view?.parentId ?? _currentId;
    await ref.read(appStateProvider).uploads.addFiles(files, target);
  }

  Future<void> _openFile(String entryId) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FileDetailScreen(entryId: entryId)),
    );
    if (changed == true) await _load();
  }

  Future<void> _openFolderMeta(String folderId) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FolderDetailScreen(folderId: folderId)),
    );
    if (changed == true) {
      await _load();
      setState(
        () => _stack = _stack.length > 1
            ? _stack.sublist(0, _stack.length - 1)
            : _stack,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appStateProvider);
    final uploads = state.uploads;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Text(
          _stack.last.name,
          style: const TextStyle(color: C.fg, fontSize: 17),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_upward, color: C.fg),
          onPressed: _stack.length <= 1
              ? null
              : () {
                  setState(() => _stack = _stack.sublist(0, _stack.length - 1));
                  _load();
                },
        ),
        actions: [
          if (_stack.length > 1)
            IconButton(
              tooltip: 'Инфо о папке',
              icon: const Icon(Icons.info_outline, color: C.fg),
              onPressed: _currentId == null
                  ? null
                  : () => _openFolderMeta(_currentId!),
            ),
          if (_clip != null)
            IconButton(
              tooltip: _clip!.available
                  ? 'Вставить сюда (${_clip!.mode == 'cut' ? 'перенести' : 'скопировать'} «${_clip!.name}»)'
                  : 'Источник «${_clip!.name}» больше недоступен',
              icon: const Icon(Icons.content_paste, color: C.fg),
              onPressed: _clip!.available ? _paste : null,
            ),
          IconButton(
            tooltip: 'Новая папка',
            icon: const Icon(Icons.create_new_folder_outlined, color: C.fg),
            onPressed: _mkdir,
          ),
          IconButton(
            tooltip: 'Загрузить файлы',
            icon: const Icon(Icons.upload_file, color: C.fg),
            onPressed: _pickUpload,
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: uploads,
            builder: (context, _) => uploads.rows.isEmpty
                ? const SizedBox.shrink()
                : UploadPanel(queue: uploads),
          ),
          if (_clip != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _clip!.mode == 'cut' ? Icons.content_cut : Icons.copy,
                    size: 14,
                    color: C.fg3,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _clip!.name,
                      style: const TextStyle(color: C.fg3, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16, color: C.fg3),
                    onPressed: _clearClip,
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                _error!,
                style: const TextStyle(color: C.danger, fontSize: 13),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                _notice!,
                style: const TextStyle(color: C.ok, fontSize: 13),
              ),
            ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    final v = _view;
    if (v == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final folders = (v?.folders ?? const <FolderEntry>[])
        .where((f) => f.id != _photoFolderId)
        .toList();
    final entries = v?.entries ?? const <FolderEntry>[];
    if (folders.isEmpty && entries.isEmpty) {
      return Center(
        child: Text(
          'Пусто — нажмите «Загрузить», чтобы добавить файлы в эту папку',
          style: const TextStyle(color: C.fg3),
          textAlign: TextAlign.center,
        ),
      );
    }
    final state = ref.read(appStateProvider);
    // Корень зеркала этого устройства: папка ничем не отличается от обычной, а удалить или
    // переименовать её — значит сломать зеркало. Показываем значок и на нём, и на том, что
    // лежит внутри: всё это синхронизируется с телефоном.
    final mirrorRootId = ref.watch(
      syncControllerProvider.select((c) => c.mirrorRootId),
    );
    final insideMirror = _stack.any((e) => e.id == mirrorRootId);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ...folders.map(
          (f) => ListTile(
            leading: const Icon(Icons.folder, color: C.accent),
            title: Text(f.name, style: const TextStyle(color: C.fg)),
            trailing: (f.id == mirrorRootId || insideMirror)
                ? Tooltip(
                    message: f.id == mirrorRootId
                        ? 'Зеркало этого устройства: содержимое совпадает с выбранными '
                              'папками телефона'
                        : 'Внутри зеркала устройства: эта папка синхронизируется с телефоном',
                    child: Icon(
                      Icons.sync,
                      size: 18,
                      color: f.id == mirrorRootId ? C.accent : C.fg3,
                    ),
                  )
                : null,
            onTap: () {
              setState(() => _stack = [..._stack, (id: f.id, name: f.name)]);
              _load();
            },
          ),
        ),
        ...entries.map(
          (e) => ListTile(
            leading: _Thumb(entryId: e.id, mime: e.mime, api: state.api),
            title: Text(e.name, style: const TextStyle(color: C.fg)),
            onTap: () => _openFile(e.id),
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final String entryId;
  final String? mime;
  final CloudlyApi api;
  const _Thumb({required this.entryId, this.mime, required this.api});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: api.thumbUrl(entryId),
          httpHeaders: api.authHeaders,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(color: C.surface3),
          errorWidget: (_, __, ___) => Icon(fileIcon(mime), color: C.fg3),
        ),
      ),
    );
  }
}

class UploadPanel extends StatelessWidget {
  final UploadQueue queue;
  const UploadPanel({super.key, required this.queue});

  @override
  Widget build(BuildContext context) {
    final rows = queue.rows;
    final doneN = rows.where((r) => r.state == 'done').length;
    final failN = rows.where((r) => r.state == 'failed').length;
    final active = rows.where((r) => r.state == 'uploading').length;
    final label = queue.busy
        ? 'загрузка ${doneN + (active > 0 ? 1 : 0)} из ${rows.length}'
        : failN > 0
        ? 'не загрузилось: $failN'
        : 'загружено $doneN из ${rows.length}';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: C.fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (queue.busy)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Отменить — убрать незагруженное',
                  icon: const Icon(Icons.close, size: 18, color: C.fg3),
                  onPressed: queue.cancel,
                )
              else if (failN > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: queue.retryFailed,
                      child: const Text('повторить'),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18, color: C.fg3),
                      onPressed: queue.dismissFailed,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          ...rows.map((r) => _row(r)),
        ],
      ),
    );
  }

  Widget _row(UploadRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            r.state == 'done'
                ? Icons.check_circle
                : r.state == 'failed'
                ? Icons.cancel
                : r.state == 'uploading'
                ? Icons.hourglass_top
                : Icons.schedule,
            size: 16,
            color: r.state == 'done'
                ? C.ok
                : r.state == 'failed'
                ? C.danger
                : C.fg3,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.name} · ${fmt(r.size)}',
                  style: const TextStyle(color: C.fg, fontSize: 12),
                ),
                if (r.state == 'failed')
                  Text(
                    r.error ?? 'ошибка',
                    style: const TextStyle(color: C.danger, fontSize: 11),
                  )
                else ...[
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: r.state == 'done' ? 1 : (r.pct / 100).clamp(0, 1),
                    minHeight: 3,
                    backgroundColor: C.surface3,
                    color: r.state == 'done' ? C.ok : C.accent,
                  ),
                  if (r.state == 'uploading')
                    Text(
                      r.phase == 'hash'
                          ? 'считаю sha256 · ${r.pct}%'
                          : r.phase == 'verify'
                          ? 'сервер проверяет целостность…'
                          : '${r.phase == 'relay' ? 'через сервер' : 'загружаю'} · ${r.pct}%${r.note != null ? ' · ${r.note}' : ''}',
                      style: const TextStyle(color: C.fg3, fontSize: 11),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
