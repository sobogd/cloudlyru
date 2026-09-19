import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'ai_api.dart';

/// Экран «Память»: то, что владелец рассказал о себе и о том, как отвечать.
///
/// Текст уходит в системную часть каждого запроса (на сервере, `src/ai/prompts.ts`), поэтому
/// модель знает контекст, не переспрашивая его в каждом разговоре: где человек живёт, на чём
/// работает, что для него «вода», какие ответы ему нужны. Хранится на сервере — значит память
/// одна на все устройства и переживает переустановку приложения.
class MemoryScreen extends ConsumerStatefulWidget {
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
  late final AiApi _api;

  @override
  void initState() {
    super.initState();
    _api = AiApi(ref.read(appStateProvider).api);
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
  ///
  /// Если сервер не ответил, поле остаётся пустым, но текст не затирается молча: причина
  /// показывается сообщением, иначе человек решил бы, что память потерялась.
  Future<void> _load() async {
    try {
      final memory = await _api.memory();
      if (!mounted) return;
      // слушатель на поле снимаем на время подстановки: программное заполнение — не правка
      _text.removeListener(_trackChanges);
      _text.text = memory;
      _text.addListener(_trackChanges);
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } on AiApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Сохраняет память на сервере.
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await _api.saveMemory(_text.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      // сервер мог обрезать текст по своему потолку — показываем то, что он сохранил
      if (saved != _text.text) {
        _text.removeListener(_trackChanges);
        _text.text = saved;
        _text.addListener(_trackChanges);
      }
      snack(context, 'Память сохранена');
    } on AiApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // цвет шапки задаёт `appBarTheme` из `theme.dart`, как и на остальных экранах
      appBar: AppBar(
        title: const Text('Память', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          TextButton(
            onPressed: (!_dirty || _saving || _loading) ? null : _save,
            child: Text(_saving ? 'Сохраняю…' : 'Сохранить'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                const _Explanation(),
                if (_error != null) _errorBar(_error!),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  child: TextField(
                    controller: _text,
                    minLines: 8,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(color: C.fg, fontSize: 14, height: 1.4),
                    decoration: InputDecoration(
                      hintText: 'Живу в Испании, работаю с Flutter и NestJS. '
                          'Мне нужны короткие ответы без вступлений и без пересказа вопроса.',
                      hintStyle: const TextStyle(color: C.fg3, fontSize: 14, height: 1.4),
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
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${_text.text.length} символов',
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ],
            ),
    );
  }

  /// Сообщение об ошибке над полем: причина должна быть видна, а не исчезать через пару секунд.
  Widget _errorBar(String message) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
              child: Text(message, style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3)),
            ),
          ],
        ),
      );
}

/// Пояснение, что сюда писать и как это работает.
class _Explanation extends StatelessWidget {
  const _Explanation();

  @override
  Widget build(BuildContext context) {
    return const Panel(
      child: Text(
        'Этот текст уходит в каждый запрос к модели — как то, что вы рассказали о себе перед '
        'разговором. Пишите факты, которые она должна знать: где живёте, чем занимаетесь, на '
        'чём работаете, что для вас лишнее в ответах. Память хранится на сервере и общая для '
        'всех ваших чатов; она попадает в каждый запрос, поэтому чем она короче, тем дешевле '
        'разговор.',
        style: TextStyle(color: C.fg2, fontSize: 13, height: 1.35),
      ),
    );
  }
}
