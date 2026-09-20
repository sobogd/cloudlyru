import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'chat_api.dart';

/// Экран «Память»: то, что владелец рассказал о себе и о том, как отвечать.
///
/// Текст уходит в системную часть каждого запроса (на сервере, `src/chat/prompts.ts`), поэтому
/// модель знает контекст, не переспрашивая его в каждом разговоре: где человек живёт, на чём
/// работает, что для него «вода», какие ответы ему нужны. Хранится на сервере — значит память
/// одна на все устройства и переживает переустановку приложения.
class MemoryScreen extends ConsumerStatefulWidget {
  /// Экран памяти.
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

/// Состояние экрана: загруженный текст, признак загрузки и сохранения, ошибка.
class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  /// Поле ввода памяти; заполняется после загрузки с сервера.
  final _text = TextEditingController();

  /// Идёт загрузка сохранённой памяти.
  bool _loading = true;

  /// Идёт сохранение (кнопка заблокирована, чтобы не отправить дважды).
  bool _saving = false;

  /// Причина последней неудачи в готовом для показа виде.
  String? _error;

  /// Была ли память изменена: кнопка «Сохранить» активна только тогда, когда есть что сохранять.
  bool _dirty = false;

  /// Клиент ручек чата, взятый один раз (обращаться к провайдеру из `dispose` уже нельзя).
  late final ChatApi _api;

  @override
  void initState() {
    super.initState();
    _api = ChatApi(ref.read(appStateProvider).api);
    _text.addListener(_trackChanges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Отмечает, что текст отличается от сохранённого.
  void _trackChanges() {
    if (!_dirty) setState(() => _dirty = true);
  }

  /// Читает память с сервера.
  Future<void> _load() async {
    try {
      final memory = await _api.memory();
      if (!mounted) return;
      _text.text = memory;
      setState(() {
        _loading = false;
        _error = null;
        _dirty = false;
      });
    } on ChatApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Сохраняет память и уходит с экрана.
  ///
  /// Уходим только после успеха: иначе человек решил бы, что текст сохранён, а он остался бы
  /// на экране и потерялся при закрытии.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _api.saveMemory(_text.text);
      if (!mounted) return;
      snack(context, 'Память сохранена');
      Navigator.of(context).pop();
    } on ChatApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Память', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          TextButton(
            onPressed: (!_dirty || _saving || _loading) ? null : _save,
            child: Text(_saving ? 'Сохраняю…' : 'Сохранить'),
          ),
        ],
      ),
      body: _body(),
    );
  }

  /// Тело экрана: загрузка, ошибка или поле ввода с объяснением.
  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
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
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + navBarInset(context)),
      children: [
        const Text(
          'Этот текст уходит модели вместе с каждым вопросом: как к вам обращаться, что уже '
          'известно, в каком стиле отвечать. Пишите коротко и по делу — он занимает место в '
          'запросе и тратит время на чтение.',
          style: TextStyle(color: C.fg3, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          minLines: 8,
          maxLines: 20,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
          decoration: InputDecoration(
            hintText: 'Например: отвечай кратко, без вступлений. Живу в Испании, счета в евро.',
            hintStyle: const TextStyle(color: C.fg3, fontSize: 13.5, height: 1.35),
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
          ),
        ),
      ],
    );
  }
}
