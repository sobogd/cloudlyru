import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';

/// Модалка перевода письма: сначала ожидание, потом русский текст.
///
/// Перевод делает сервер (локальная модель на маке) и отдаёт целиком, поэтому сама модалка
/// запрос не стримит: пока ответа нет — индикатор, после — обычный выделяемый текст. Разметки
/// здесь нет намеренно: переводится видимый текст письма, а не вёрстка, и показывать его
/// модалкой дешевле и надёжнее, чем подменять документ внутри WebView.
///
/// Экран письма при этом не трогается вовсе: закрыть модалку — и перед тобой снова оригинал.
class MailTranslationSheet extends ConsumerStatefulWidget {
  /// Письмо, которое переводим.
  final String messageId;

  const MailTranslationSheet({super.key, required this.messageId});

  @override
  ConsumerState<MailTranslationSheet> createState() => _MailTranslationSheetState();
}

/// Состояние модалки: ждём, показываем перевод или объясняем отказ.
class _MailTranslationSheetState extends ConsumerState<MailTranslationSheet> {
  /// Готовый перевод; `null` — ещё ждём (или уже ошибка, см. [_error]).
  String? _text;
  /// Причина отказа для человека: сеть, «мак спит», письмо не разобралось.
  String? _error;

  @override
  /// Открытие модалки сразу запускает перевод — отдельной кнопки «начать» нет.
  void initState() {
    super.initState();
    _load();
  }

  /// Просит сервер перевести письмо и раскладывает ответ по состоянию.
  ///
  /// Пустой перевод считается ошибкой, а не результатом: письмо без текста сервер отвергает
  /// сам, значит пустая строка здесь — это сбой модели, и молчаливая пустая модалка выглядела
  /// бы как «кнопка не работает».
  Future<void> _load() async {
    // При открытии модалки сбрасывать нечего (оба поля пусты), а при повторе надо убрать
    // прошлый отказ: иначе на экране остался бы он же, пока идёт новый запрос.
    if (_text != null || _error != null) {
      setState(() {
        _error = null;
        _text = null;
      });
    }
    try {
      final data = await ref.read(appStateProvider).api.mailTranslate(widget.messageId);
      final text = (data['text'] as String? ?? '').trim();
      if (!mounted) return;
      if (text.isEmpty) {
        setState(() => _error = 'Модель вернула пустой перевод.');
      } else {
        setState(() => _text = text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        // Высокая модалка: письмо — это текст, и ему нужна почти вся высота экрана.
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Перевод на русский',
                        style: TextStyle(color: C.fg, fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close, color: C.fg3),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }

  /// Содержимое модалки: отказ с повтором, ожидание или сам перевод.
  Widget _content() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
              const SizedBox(height: 12),
              // Повтор здесь уместен: самый частый отказ — недоступная модель, а она возвращается
              // сама (мак проснулся, туннель поднялся).
              TextButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    final text = _text;
    if (text == null) {
      // Первый перевод идёт десятки секунд: без индикатора модалка выглядела бы зависшей.
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: SelectableText(text, style: const TextStyle(color: C.fg, fontSize: 15, height: 1.45)),
    );
  }
}
