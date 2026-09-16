import 'package:flutter/material.dart';

import '../theme.dart';

/// Иконка для строки списка по mime-типу файла.
///
/// Распознаём то, что отличается на вид: префиксы `image/`, `video/` и `audio/`, точные
/// `application/pdf` и архивы. Тип сравнивается в нижнем регистре — сервер отдаёт его как
/// есть, и `Application/ZIP` из чужого письма не должен промахиваться мимо таблицы. Всё
/// остальное, включая `null` (сервер не отдал тип), получает общий значок файла — угадывать
/// по расширению здесь нечего, а неверная иконка хуже нейтральной.
IconData fileIcon(String? mime) {
  if (mime == null) return Icons.insert_drive_file_outlined;
  final m = mime.toLowerCase().trim();
  if (m.startsWith('image/')) return Icons.image_outlined;
  if (m.startsWith('video/')) return Icons.movie_outlined;
  if (m.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (m == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (_archiveMimes.contains(m) || m.endsWith('+zip')) return Icons.inventory_2_outlined;
  return Icons.insert_drive_file_outlined;
}

/// Архивные типы, которые встречаются у файлов из писем и «Загрузок»: набор не исчерпывающий,
/// но покрывает то, что реально приходит с сервера (там mime нормализуется, см.
/// `src/common/mime.ts`).
const _archiveMimes = {
  'application/zip',
  'application/x-zip',
  'application/x-zip-compressed',
  'application/x-7z-compressed',
  'application/x-rar',
  'application/x-rar-compressed',
  'application/vnd.rar',
  'application/gzip',
  'application/x-gzip',
  'application/x-tar',
  'application/x-bzip2',
};

/// Строка «подпись — значение» для карточек с метаданными (деталка файла, папки, кадра).
///
/// Подпись занимает фиксированную ширину, поэтому значения в соседних строках начинаются на
/// одной вертикали и колонку можно читать глазами сверху вниз, даже когда подпись длинная.
class MetaRow extends StatelessWidget {
  final String label;
  final String value;

  /// Моноширинный шрифт для значений, где важны отдельные символы: sha256, id, точные размеры.
  final bool mono;

  /// Значение можно выделить и скопировать. Включено по умолчанию для моноширинных значений:
  /// их и копируют руками (сегодня это sha256 в деталке файла), а обычный [Text] выделить
  /// нельзя — приходится набирать символы глазами.
  final bool selectable;

  /// [label] и [value] — позиционные: почти всегда это литеральная подпись и готовое значение.
  const MetaRow(this.label, this.value, {this.mono = false, this.selectable = false, super.key});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: C.fg,
      fontSize: 13,
      fontFamily: mono ? 'monospace' : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // Ширина подписи рассчитана на самые длинные в проекте — «Вложенные папки»
            // и «Расположение»: они должны укладываться в одну строку.
            width: 130,
            child: Text(label, style: const TextStyle(color: C.fg2, fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: (selectable || mono)
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

/// Карточка-остров: скруглённая подложка с рамкой и внутренними полями, как блоки в прежнем
/// веб-клиенте (он жил в `web/src`, удалён коммитом 407a490).
///
/// Ширина всегда во всю доступную — панели разделов идут одна под другой, и «плавающая» ширина
/// по содержимому выглядела бы случайной.
class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.brd),
      ),
      child: child,
    );
  }
}

/// Спрашивает подтверждение в модальном диалоге и возвращает ответ человека.
///
/// Возвращает `true` только при нажатии подтверждающей кнопки; «Отмена», системный «назад»
/// и тап мимо диалога дают `false` — закрытие диалога не должно выглядеть согласием на
/// удаление. [danger] переключает кнопку на красную: опасное действие должно отличаться от
/// обычного. [confirmLabel] — подпись кнопки, когда «Удалить»/«ОК» не описывает действие
/// («Очистить», «Сбросить»): раньше она собиралась из одного лишь [danger], и необратимая
/// очистка корзины подтверждалась безликим «ОК».
///
/// Побочный эффект — сам показ диалога; ждём закрытия, поэтому вызывающий обязан проверить
/// `mounted` перед работой с результатом.
Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message, {
  bool danger = false,
  String? confirmLabel,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: C.danger)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel ?? (danger ? 'Удалить' : 'ОК')),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Запрашивает одну строку текста в диалоге (имя файла, папки, метка токена).
///
/// Возвращает введённый текст или `null`, если диалог закрыли без подтверждения — то же
/// `null`, что и у [confirmDialog], означает «человек передумал» — здесь это закрытие диалога
/// без подтверждения. [initial] подставляется в поле, чтобы при переименовании правили
/// существующее имя, а не набирали новое с нуля. Проверки значения тут нет — пустую строку
/// отсекает вызывающий экран.
///
/// Показ отдан отдельному виджету ([_PromptDialog]), а не замыканию: поле живёт на своём
/// контроллере, и контроллер должен освободиться вместе с полем. Освобождение сразу после
/// `showDialog` пришлось бы на обратную анимацию закрытия маршрута, когда `EditableText`
/// ещё в дереве, — это грозило бы «A TextEditingController was used after being disposed».
Future<String?> promptDialog(
  BuildContext context,
  String title, {
  String? initial,
}) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PromptDialog(title: title, initial: initial),
  );
}

/// Диалог с одним полем ввода: держит собственный контроллер ровно столько, сколько живёт
/// само поле, и освобождает его в [State.dispose] — уже после закрытия маршрута.
class _PromptDialog extends StatefulWidget {
  final String title;
  final String? initial;

  const _PromptDialog({required this.title, this.initial});

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(controller: _ctrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('ОК'),
        ),
      ],
    );
  }
}

/// Показывает короткое сообщение-всплывашку внизу экрана.
///
/// Уже висящие сообщения снимаются перед показом нового: ошибки приходят сериями (например,
/// пачка неудачных загрузок), и без этого человек смотрел бы очередь из старых сообщений,
/// пока до последнего не дойдёт ход.
void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}
