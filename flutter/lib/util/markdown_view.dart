import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'widgets.dart';

/// Показ markdown в приложении: ответ модели в чате и содержимое `.md`-файла в деталке.
///
/// Один виджет на оба места намеренно: разметка должна выглядеть одинаково, где бы её ни
/// показывали, а до этого стиль и обработчик блока кода жили приватно внутри экрана чата —
/// второй копии для файлов быть не должно, иначе стили разъедутся.
///
/// Разбором занимается `flutter_markdown_plus` (GFM: заголовки, списки, таблицы, ссылки),
/// а блоку кода оставлен свой вид с кнопкой «копировать» — его собирает [CodeBlockBuilder].
class MarkdownText extends StatelessWidget {
  /// Текст с разметкой как он пришёл: ответ модели или содержимое файла.
  final String data;

  const MarkdownText(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      // Выделять текст нужно в обоих местах: из ответа копируют команды, из файла — куски
      // документа, а выделение пальцем на телефоне работает только при `selectable`.
      selectable: true,
      // Ссылки открываем в браузере: своего просмотрщика страниц в приложении нет, а «нажать
      // и ничего не произошло» — худший вариант для текста со ссылками на источники.
      onTapLink: (label, href, title) => openMarkdownLink(context, href),
      styleSheet: markdownStyle(context),
      builders: {'pre': CodeBlockBuilder()},
    );
  }
}

/// Открывает ссылку из разметки во внешнем приложении.
///
/// Сбой не молчим: адрес приходит из текста, который писал не пользователь (ответ модели или
/// чужой файл), и он бывает нерабочим — тогда человек должен увидеть, что дело в ссылке,
/// а не в приложении. Длинный адрес в сообщении обрезается: целиком он не помещается
/// в подсказку и вытесняет из неё саму причину.
///
/// Побочно: запускает внешнее приложение; при неудаче показывает `snack`. Проверка
/// `context.mounted` нужна потому, что запуск асинхронный, а экран за это время могли закрыть.
Future<void> openMarkdownLink(BuildContext context, String? href) async {
  if (href == null || href.isEmpty) return;
  try {
    final ok = await launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) snack(context, 'Не удалось открыть ссылку');
  } catch (_) {
    if (context.mounted) {
      snack(context, 'Ссылка не открывается: ${href.length > 60 ? '${href.substring(0, 60)}…' : href}');
    }
  }
}

/// Стиль разметки под палитру приложения.
///
/// Своих цветов у markdown нет: без этого заголовки и код выглядели бы чужеродно (тема
/// приложения тёмная, а пакет по умолчанию берёт цвета Material).
MarkdownStyleSheet markdownStyle(BuildContext context) => MarkdownStyleSheet.fromTheme(
      Theme.of(context),
    ).copyWith(
      p: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
      h1: const TextStyle(color: C.fg, fontSize: 19, fontWeight: FontWeight.w600, height: 1.3),
      h2: const TextStyle(color: C.fg, fontSize: 17, fontWeight: FontWeight.w600, height: 1.3),
      h3: const TextStyle(color: C.fg, fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
      listBullet: const TextStyle(color: C.fg, fontSize: 14, height: 1.35),
      a: const TextStyle(color: C.accent, fontSize: 14, decoration: TextDecoration.underline),
      em: const TextStyle(color: C.fg2, fontStyle: FontStyle.italic),
      strong: const TextStyle(color: C.fg, fontWeight: FontWeight.w700),
      code: const TextStyle(
        color: C.fg,
        fontSize: 12.5,
        fontFamily: 'monospace',
        backgroundColor: C.canvas,
      ),
      blockquote: const TextStyle(color: C.fg2, fontSize: 14, height: 1.35),
      blockquoteDecoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: C.brd2, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: C.brd)),
      ),
      tableBorder: TableBorder.all(color: C.brd),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      tableHead: const TextStyle(color: C.fg, fontSize: 13, fontWeight: FontWeight.w600),
      tableBody: const TextStyle(color: C.fg2, fontSize: 13),
    );

/// Стиль обычного текста и содержимого блока кода: моноширинный шрифт того же кегля.
///
/// Общая константа, а не два одинаковых литерала: сырой текст файла (`.txt`, `.csv`, `.json`)
/// и код внутри разметки должны выглядеть одинаково.
const monoTextStyle = TextStyle(color: C.fg, fontSize: 12.5, height: 1.35, fontFamily: 'monospace');

/// Блок кода из разметки: моноширинный текст и кнопка «копировать».
///
/// Копирование здесь важнее оформления: код почти всегда переносят в редактор, а выделять его
/// пальцем на телефоне неудобно. Виджет отдельный, потому что его собирает [CodeBlockBuilder] —
/// обработчик разметки, а не сам экран.
class CodeBlock extends StatelessWidget {
  /// Код как он пришёл в разметке, без строки с именем языка.
  final String code;

  const CodeBlock(this.code, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: C.canvas,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Копировать',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) snack(context, 'Код скопирован');
              },
              icon: const Icon(Icons.copy, color: C.fg3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SelectableText(code, style: monoTextStyle),
          ),
        ],
      ),
    );
  }
}

/// Отрисовка блока кода в markdown (`pre`) своим виджетом.
///
/// Имя языка (`dart`, `json`) из разметки не показываем: оно нужно подсветке, которой здесь
/// нет, а в тексте выглядело бы лишним словом. Первая строка содержимого `pre` — это
/// как раз имя языка, поэтому её срезаем.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final raw = element.textContent;
    final nl = raw.indexOf('\n');
    final firstLine = nl < 0 ? raw : raw.substring(0, nl).trim();
    final isLanguage = nl >= 0 && firstLine.isNotEmpty && firstLine.length <= 12 && !firstLine.contains(' ');
    return CodeBlock(isLanguage ? raw.substring(nl + 1) : raw);
  }
}
