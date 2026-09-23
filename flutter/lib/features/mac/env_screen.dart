import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Экран «Env-файлы»: список `.env` под `~/work` на маке и их редактор.
///
/// Содержимое `.env` — секреты, поэтому раздел показывает их как есть: доступ к нему закрыт
/// той же сессией приложения, что и остальные разделы, а значение токена панели знает только
/// бэкенд. Запись атомарная, перед сохранением панель делает бэкап на маке.
class EnvScreen extends ConsumerStatefulWidget {
  /// Экран списка env-файлов.
  const EnvScreen({super.key});

  @override
  ConsumerState<EnvScreen> createState() => _EnvScreenState();
}

/// Состояние списка env-файлов.
class _EnvScreenState extends ConsumerState<EnvScreen> {
  /// Список файлов; `null` — ответа ещё не было.
  List<Map<String, dynamic>>? _files;

  /// Текст последней неудачи.
  String? _err;

  /// Идёт запрос списка.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Перечитывает список.
  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macEnvs();
      final list = (d['files'] is List) ? (d['files'] as List) : const [];
      if (!mounted) return;
      setState(() {
        _files = list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _err = null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Env-файлы'),
        actions: [IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: _err != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Мак недоступен: $_err')))
          : files == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final f = files[i];
                    return ListTile(
                      dense: true,
                      title: Text('${f['path']}'),
                      subtitle: Text('${f['size']} байт'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => EnvEditorScreen(path: '${f['path']}'),
                      )),
                    );
                  },
                ),
    );
  }
}

/// Редактор одного `.env`-файла: чтение, правка и атомарное сохранение.
class EnvEditorScreen extends ConsumerStatefulWidget {
  /// Путь файла относительно корня (`~/work`) — тот же, что пришёл в списке.
  final String path;

  /// Экран редактора.
  const EnvEditorScreen({required this.path, super.key});

  @override
  ConsumerState<EnvEditorScreen> createState() => _EnvEditorScreenState();
}

/// Состояние редактора: текст файла и признаки загрузки/сохранения.
class _EnvEditorScreenState extends ConsumerState<EnvEditorScreen> {
  /// Контроллер текста; заполняется после чтения.
  final _text = TextEditingController();

  /// Идёт чтение/запись.
  bool _busy = false;

  /// Текст ошибки, если файл не прочитался/не сохранился.
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Читает содержимое файла.
  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macEnvRead(widget.path);
      if (!mounted) return;
      if (d['ok'] == false) {
        setState(() => _err = '${d['msg'] ?? 'не удалось прочитать'}');
      } else {
        _text.text = '${d['content'] ?? ''}';
        _err = null;
      }
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Сохраняет содержимое (панель делает бэкап до записи).
  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final d = await ref.read(appStateProvider).api.macEnvWrite(widget.path, _text.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${d['ok'] == false ? d['msg'] : 'Сохранено'}')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: const Text('Сохранить')),
        ],
      ),
      body: _err != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_err!)))
          : _busy && _text.text.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _text,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(border: InputBorder.none),
                  ),
                ),
    );
  }
}
