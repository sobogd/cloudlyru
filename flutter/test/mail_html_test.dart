import 'dart:convert';

import 'package:cloudly_flutter/features/mail/mail_screen.dart';
import 'package:cloudly_flutter/util/mail_html.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF/9UeIAAAAAElFTkSuQmCC';

/// Письмо целиком так, как его отдаёт сервер: шапка, тело, разметка рассыльщика.
Future<Object?> _render(WidgetTester tester, String html) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: MailBodyHtml(html))),
  ));
  await tester.pump();
  return tester.takeException();
}

void main() {
  group('stripAtRules', () {
    test('вырезает медиазапрос вместе с телом', () {
      const css = '@media only screen and (max-width:600px){.col{width:100%!important}}';
      expect(stripAtRules(css).trim(), isEmpty);
    });

    test('сохраняет обычные правила рядом с медиазапросом', () {
      const css = '.head{color:#000}@media (max-width:600px){.col{width:100%}}.body{padding:8px}';
      final out = stripAtRules(css);
      expect(out, contains('.head{color:#000}'));
      expect(out, contains('.body{padding:8px}'));
      expect(out, isNot(contains('max-width')));
    });

    test('вырезает keyframes и вложенные блоки целиком', () {
      const css = '@keyframes spin{from{opacity:0}to{opacity:1}}p{color:#111}';
      final out = stripAtRules(css);
      expect(out, contains('p{color:#111}'));
      expect(out, isNot(contains('opacity')));
    });

    test('не трогает @ в ссылках и строках', () {
      const css = '.a{background:url(https://user@host/x.png);content:"@"}';
      expect(stripAtRules(css), css);
    });

    test('директива без блока режется по точке с запятой', () {
      const css = '@import url("https://x.example/a.css");p{color:#000}';
      expect(stripAtRules(css), contains('p{color:#000}'));
      expect(stripAtRules(css), isNot(contains('@import')));
    });
  });

  group('таблицы', () {
    test('ячейки встают блоками, таблиц в разметке не остаётся', () {
      final out = prepareMailHtml('<table><tr><td>первая</td><td>вторая</td></tr><tr><td>третья</td></tr></table>');
      expect(out, isNot(contains('<table')));
      expect(out, isNot(contains('<td')));
      final i1 = out.indexOf('первая');
      final i2 = out.indexOf('вторая');
      final i3 = out.indexOf('третья');
      expect(i1, lessThan(i2));
      expect(i2, lessThan(i3));
    });

    test('вложенные таблицы разворачиваются целиком', () {
      final out = prepareMailHtml('<table><tr><td><table><tr><td>внутри</td></tr></table>снаружи</td></tr></table>');
      expect(out, isNot(contains('<table')));
      expect(out, contains('внутри'));
      expect(out, contains('снаружи'));
    });

    test('мусор прямо в <tr> не теряется', () {
      final out = prepareMailHtml('<table><tr><img src="https://x.example/a.png" alt="баннер"></tr>'
          '<tr><td>текст</td></tr></table>');
      expect(out, contains('x.example/a.png'));
      expect(out, contains('текст'));
    });

    test('фон и выравнивание ячейки переносятся на блок', () {
      final out = prepareMailHtml('<table><tr><td bgcolor="#f2f9ff" align="center" height="20">текст</td></tr></table>');
      expect(out, contains('background-color:#f2f9ff'));
      expect(out, contains('text-align:center'));
      expect(out, contains('height:20px'));
    });
  });

  group('normalizeDataImage', () {
    test('убирает переносы внутри base64', () {
      final src = 'data:image/png;base64,${_png.substring(0, 20)}\n${_png.substring(20)}';
      expect(normalizeDataImage(src), 'data:image/png;base64,$_png');
    });

    test('переводит процентное кодирование в base64', () {
      // %47%49%46%38%39%61 — это GIF89a
      expect(normalizeDataImage('data:image/gif,%47%49%46%38%39%61'),
          'data:image/gif;base64,${base64.encode(utf8.encode('GIF89a'))}');
    });

    test('битый base64 не чинится — ссылку показывать нечем', () {
      expect(normalizeDataImage('data:image/png;base64,!!!не-base64!!!'), isNull);
      expect(normalizeDataImage('data:image/png'), isNull);
      expect(normalizeDataImage('data:image/png;base64,'), isNull);
    });

    test('дописывает забытый padding', () {
      // base64 одного байта 0x47 — это Rw==, без padding остаётся Rw
      expect(normalizeDataImage('data:image/gif;base64,Rw'), 'data:image/gif;base64,Rw==');
    });

    test('исправный base64 остаётся как есть', () {
      expect(normalizeDataImage('data:image/png;base64,$_png'), 'data:image/png;base64,$_png');
    });
  });

  group('тело письма доходит до экрана', () {
    testWidgets('простой текст', (tester) async {
      expect(await _render(tester, '<p>Привет, это письмо</p>'), isNull);
      expect(find.textContaining('Привет, это письмо'), findsOneWidget);
    });

    testWidgets('@media в стилях (падало: LateInitializationError)', (tester) async {
      const html = '<style>@media only screen and (max-width:600px){.col{width:100%}}</style>'
          '<div class="col">Письмо с медиазапросом</div>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Письмо с медиазапросом'), findsOneWidget);
    });

    testWidgets('@media первым блоком из нескольких', (tester) async {
      const html = '<style>@media (max-width:1px){p{color:red}}</style>'
          '<style>p{color:#333}</style><p>Два блока стилей</p>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Два блока стилей'), findsOneWidget);
    });

    testWidgets('@keyframes в стилях (падало тем же исключением)', (tester) async {
      const html = '<style>@keyframes spin{from{opacity:0}to{opacity:1}}</style><p>Анимация</p>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Анимация'), findsOneWidget);
    });

    testWidgets('base64 с переносами внутри (падало: FormatException)', (tester) async {
      final src = 'data:image/png;base64,${_png.substring(0, 20)}\n${_png.substring(20)}';
      expect(await _render(tester, '<img src="$src" alt="картинка"><p>Письмо с картинкой</p>'), isNull);
      expect(find.textContaining('Письмо с картинкой'), findsOneWidget);
    });

    testWidgets('data-URI без base64 (падало: RangeError)', (tester) async {
      expect(await _render(tester, '<img src="data:image/gif,%47%49%46"><p>Вёрстка на data-URI</p>'), isNull);
      expect(find.textContaining('Вёрстка на data-URI'), findsOneWidget);
    });

    testWidgets('битая картинка не топит письмо', (tester) async {
      const html = '<img src="data:image/png;base64,!!!" alt="битая"><p>Текст рядом с битой картинкой</p>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Текст рядом с битой картинкой'), findsOneWidget);
    });

    testWidgets('текстовая версия письма (сервер отдаёт её в <pre>) видна целиком', (tester) async {
      // Сервер кладёт текст письма в <pre> (textToHtml) — эту разметку и рисует вьювер.
      final long = List.generate(400, (i) => 'строка номер $i').join('\n');
      final html = '<pre style="white-space:pre-wrap;word-wrap:break-word;font:inherit;margin:0">$long</pre>';
      expect(await _render(tester, html), isNull);
      // Хвост письма за пределами превью в 2000 символов тоже должен быть на экране.
      expect(find.textContaining('строка номер 399'), findsOneWidget);
    });

    testWidgets('текст в таблице видно (раньше таблицы схлопывали тело в полоску)', (tester) async {
      const html = '<table role="presentation" width="600"><tr><td>Письмо табличной вёрстки</td></tr></table>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Письмо табличной вёрстки'), findsOneWidget);
    });

    testWidgets('картинка в ячейке таблицы не ломает разметку', (tester) async {
      final html = '<table><tr><td><img src="data:image/png;base64,$_png" width="140" alt="баннер">'
          '<p>Подпись под баннером</p></td></tr></table>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Подпись под баннером'), findsOneWidget);
    });

    testWidgets('письмо табличной вёрстки разворачивается на всю высоту, а не в полоску', (tester) async {
      // На таком письме flutter_html_table схлопывал тело до ~50 точек и сыпал исключениями
      // разметки — письмо выглядело белой полоской.
      final rows = List.generate(12, (i) => '<tr><td style="padding:8px">Строка письма номер $i</td></tr>').join();
      final html = '<table width="600" style="background-color:#f2f9ff"><tr><td>'
          '<table>$rows</table></td></tr></table>';
      expect(await _render(tester, html), isNull);
      expect(tester.getSize(find.byType(MailBodyHtml)).height, greaterThan(400));
      expect(find.textContaining('Строка письма номер 11'), findsOneWidget);
    });

    testWidgets('рассылка целиком: таблицы, медиазапрос, картинка по cid, условные комментарии', (tester) async {
      final html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
          '<style>.ExternalClass{width:100%}@media only screen and (max-width:600px){.stack{display:block!important}}</style>'
          '</head><body style="margin:0;padding:0;background-color:#f4f4f4">'
          '<!--[if mso]><table><tr><td>outlook</td></tr></table><![endif]-->'
          '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="border-collapse:collapse">'
          '<tr><td style="font-family:Arial,sans-serif;font-size:10.0pt;color:#333333">'
          '<span style="font-size:18px">Скидка недели</span>'
          '<img src="data:image/png;base64,$_png" width="140" alt="баннер">'
          '<a href="https://x.example" target="_blank" rel="noopener">Смотреть</a>'
          '</td></tr></table></body></html>';
      expect(await _render(tester, html), isNull);
      expect(find.textContaining('Скидка недели'), findsOneWidget);
    });
  });
}
