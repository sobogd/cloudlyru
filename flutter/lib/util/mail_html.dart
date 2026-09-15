import 'dart:convert';

import 'package:flutter_html/flutter_html.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Тело письма, подготовленное к показу во flutter_html.
///
/// Сервер отдаёт разметку письма уже почищенной (см. src/mail/mail-html.ts), но чистит он
/// её под браузер: там тело живёт в iframe, которому всё равно, что внутри. flutter_html
/// разбирает ту же разметку сам и на части писем падает — а падение в build-фазе в release
/// превращается в серый прямоугольник вместо письма. Проверено на живых письмах и в тестах:
///
/// 1. `@media` в `<style>` роняет разбор CSS (`LateInitializationError` внутри csslib-визитора
///    flutter_html). Медиазапросы в приложении бессмысленны — ширина колонки не меняется, —
///    поэтому вырезаем их вместе с прочими at-правилами. Остальные правила блока сохраняем:
///    вёрстка письма часто держится и на них.
/// 2. Картинка в `data:` со переводом строки или без padding внутри base64 роняет декодер
///    (`FormatException`), а data-URI без `base64,` — ещё и индексом (`RangeError`).
///    Такие ссылки нормализуем, а невосстановимые убираем: пусть лучше не будет картинки,
///    чем всего письма.
/// 3. Таблицы. Письма свёрстаны таблицами, а `flutter_html_table` + `flutter_layout_grid` на
///    живом письме роняют разметку: тело схлопывается в полоску высотой в пару десятков точек
///    (в отладочной сборке — с градом исключений про обращение к size при расчёте размеров).
///    Поэтому таблицы разбираем на блоки: содержимое ячеек встаёт столбиком в том же порядке.
///    Так письмо читается на телефоне — многоколоночные рассылки в узком экране и так
///    перестраиваются медиазапросами в одну колонку.
///
/// Плюс страховка: оставшийся CSS прогоняем через тот же разбор, что делает flutter_html,
/// и если он всё ещё не разбирается — выбрасываем блоки `<style>` целиком. Стили потеряются,
/// письмо останется.
String prepareMailHtml(String html) {
  final doc = html_parser.parse(html);
  _cleanStyleTags(doc);
  _flattenTables(doc);
  _fixImages(doc);
  return doc.outerHtml;
}

void _cleanStyleTags(Document doc) {
  final styles = doc.getElementsByTagName('style');
  if (styles.isEmpty) return;

  for (final style in styles) {
    final cleaned = stripAtRules(style.text);
    if (cleaned != style.text) {
      style.nodes
        ..clear()
        ..add(Text(cleaned));
    }
  }

  // flutter_html склеивает содержимое всех <style> письма в одну строку и разбирает её целиком,
  // поэтому проверять надо ту же склейку, а не каждый блок по отдельности.
  final joined = styles.map((s) => s.text).join();
  if (_cssParses(joined)) return;

  for (final style in styles) {
    style.remove();
  }
}

/// Разбирается ли CSS так, как это делает flutter_html.
///
/// `Style.fromCss` — публичная обёртка над тем же `parseExternalCss`: если он падает,
/// упадёт и отрисовка.
bool _cssParses(String css) {
  try {
    Style.fromCss(css, null);
    return true;
  } catch (_) {
    return false;
  }
}

/// Вырезать at-правила (`@media`, `@keyframes`, `@supports`, `@font-face`, …) из CSS.
///
/// Строки и комментарии пропускаем как есть: `url(user@host/x.png)` или `content:"@"` —
/// не at-правило, и резать по ним CSS нельзя.
String stripAtRules(String css) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  while (i < css.length) {
    final ch = css[i];
    if (ch == '/' && i + 1 < css.length && css[i + 1] == '*') {
      final end = css.indexOf('*/', i + 2);
      final stop = end < 0 ? css.length : end + 2;
      out.write(css.substring(i, stop));
      i = stop;
      continue;
    }
    if (ch == '"' || ch == "'") {
      final stop = _endOfString(css, i);
      out.write(css.substring(i, stop));
      i = stop;
      continue;
    }
    if (ch == '{') {
      depth++;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '}') {
      if (depth > 0) depth--;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '@' && depth == 0) {
      i = _endOfAtRule(css, i);
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// Индекс сразу за закрывающей кавычкой строки, начавшейся в [start].
int _endOfString(String css, int start) {
  final quote = css[start];
  var i = start + 1;
  while (i < css.length) {
    final ch = css[i];
    if (ch == '\\') {
      i += 2;
      continue;
    }
    if (ch == quote) return i + 1;
    i++;
  }
  return css.length;
}

/// Индекс за концом at-правила: либо за `;` (директива), либо за парной `}` (блок).
int _endOfAtRule(String css, int start) {
  var i = start + 1;
  var depth = 0;
  var parens = 0;
  while (i < css.length) {
    final ch = css[i];
    if (ch == '"' || ch == "'") {
      i = _endOfString(css, i);
      continue;
    }
    if (ch == '/' && i + 1 < css.length && css[i + 1] == '*') {
      final end = css.indexOf('*/', i + 2);
      i = end < 0 ? css.length : end + 2;
      continue;
    }
    if (ch == '(') {
      parens++;
    } else if (ch == ')') {
      if (parens > 0) parens--;
    } else if (parens == 0) {
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth <= 0) return i + 1;
      } else if (ch == ';' && depth == 0) {
        return i + 1;
      }
    }
    i++;
  }
  return css.length;
}

void _fixImages(Document doc) {
  for (final img in doc.querySelectorAll('img')) {
    // Data-URI: убираем переносы внутри base64, а восстанавливаемые ссылки оставляем рабочими.
    final src = img.attributes['src']?.trim();
    if (src == null || !src.toLowerCase().startsWith('data:')) continue;
    final fixed = normalizeDataImage(src);
    if (fixed == null) {
      img.attributes.remove('src');
    } else {
      img.attributes['src'] = fixed;
    }
  }
}

/// Развернуть таблицы в блоки: содержимое ячеек — столбиком, в порядке чтения.
void _flattenTables(Document doc) {
  // Идём от вложенных к внешним: когда дойдёт очередь до внешней таблицы, внутренние уже блоки.
  for (final table in doc.querySelectorAll('table').toList().reversed) {
    _flattenTable(table);
  }
}

void _flattenTable(Element table) {
  final blocks = <Element>[];
  for (final row in table.querySelectorAll('tr')) {
    Element? stray;
    for (final node in row.nodes.toList()) {
      final cell = node is Element && (node.localName == 'td' || node.localName == 'th') ? node : null;
      if (cell != null) {
        stray = null;
        blocks.add(_cellBlock(cell));
        continue;
      }
      // Письма приходят и с мусором прямо в <tr> (например <img> без ячейки) — не теряем его.
      if (node is Text && node.data.trim().isEmpty) continue;
      if (stray == null) {
        stray = Element.tag('div')..attributes.addAll(_cellLook(row));
        blocks.add(stray);
      }
      stray.nodes.add(node);
    }
  }
  // Что-то лежащее в таблице мимо строк (бывает у кривых рассыльщиков) — тоже сохраняем.
  for (final node in table.nodes.toList()) {
    if (node is Element) {
      const structural = {'tbody', 'thead', 'tfoot', 'tr', 'caption', 'colgroup', 'col'};
      if (structural.contains(node.localName)) continue;
    }
    if (node is Text && node.data.trim().isEmpty) continue;
    blocks.add(Element.tag('div')..nodes.add(node));
  }

  if (blocks.isEmpty) {
    table.remove();
    return;
  }

  // Обёртка держит то, чем была таблица: фон, отступы, выравнивание.
  final wrapper = Element.tag('div')..attributes.addAll(_cellLook(table));
  wrapper.nodes.addAll(blocks);
  table.replaceWith(wrapper);
}

Element _cellBlock(Element cell) {
  final div = Element.tag('div')..attributes.addAll(_cellLook(cell));
  div.nodes.addAll(cell.nodes.toList());
  return div;
}

/// Стиль, переносимый с таблицы/ячейки на блок: цвет, фон, отступы, высота.
Map<String, String> _cellLook(Element el) {
  final style = StringBuffer((el.attributes['style'] ?? '').trim());
  if (style.isNotEmpty && !style.toString().trimRight().endsWith(';')) style.write(';');

  // Атрибуты вёрстки писем: bgcolor/align/valign — то же самое, что свойства CSS.
  final bg = el.attributes['bgcolor'];
  if (bg != null && bg.trim().isNotEmpty) style.write('background-color:${bg.trim()};');
  final align = el.attributes['align'];
  if (align != null && align.trim().isNotEmpty) style.write('text-align:${align.trim()};');
  // height держим: пустые ячейки-распорки задают вертикальные отступы письма.
  final height = el.attributes['height'];
  if (height != null && RegExp(r'^\d+$').hasMatch(height.trim())) style.write('height:${height.trim()}px;');

  final value = style.toString().trim();
  return value.isEmpty ? const {} : {'style': value};
}

/// Data-URI картинки в виде, который переживёт декодер flutter_html.
///
/// Возвращает null, если картинку показать нечем: такую ссылку лучше убрать совсем.
String? normalizeDataImage(String src) {
  final comma = src.indexOf(',');
  if (comma < 0) return null;
  final meta = src.substring(0, comma);
  final payload = src.substring(comma + 1);

  if (meta.toLowerCase().endsWith(';base64')) {
    // Переносы строк внутри base64 — обычное дело у рассыльщиков, а декодер на них падает.
    final clean = payload.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) return null;
    final decoded = _decodeBase64(clean);
    if (decoded == null) return null;
    return '$meta,$decoded';
  }

  // Процентное кодирование flutter_html не понимает вовсе — переводим в base64.
  final bytes = percentDecode(payload);
  if (bytes == null || bytes.isEmpty) return null;
  return '${meta.replaceFirst(RegExp(r'[;\s]+$'), '')};base64,${base64.encode(bytes)}';
}

/// Base64 в том виде, в каком его поймёт декодер flutter_html.
///
/// Возвращает null, если данные битые, и подставляет забытый padding, если его не хватает:
/// так картинка доедет до экрана вместо того, чтобы пропасть.
String? _decodeBase64(String payload) {
  try {
    base64.decode(payload);
    return payload;
  } catch (_) {
    final pad = (4 - payload.length % 4) % 4;
    if (pad == 0) return null;
    final padded = payload + '=' * pad;
    try {
      base64.decode(padded);
      return padded;
    } catch (_) {
      return null;
    }
  }
}

/// Процентное декодирование в байты: `Uri.decodeComponent` тут не годится — он собирает
/// строку в UTF-8 и портит бинарные данные вроде PNG.
List<int>? percentDecode(String s) {
  final out = <int>[];
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '%') {
      if (i + 2 >= s.length) return null;
      final b = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (b == null) return null;
      out.add(b);
      i += 3;
      continue;
    }
    out.addAll(utf8.encode(ch));
    i++;
  }
  return out;
}
