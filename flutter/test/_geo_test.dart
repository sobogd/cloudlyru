import 'package:cloudly_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloudly_flutter/features/mail/mail_screen.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF/9UeIAAAAAElFTkSuQmCC';

Future<void> geo(WidgetTester t, String name, String html) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: Scaffold(
      backgroundColor: C.canvas,
      body: ListView(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), children: [
        MailBodyHtml(html),
      ]),
    ),
  ));
  await t.pump();
  final exc = t.takeException();
  final htmlSize = t.getSize(find.byType(MailBodyHtml));
  final rich = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final rt = e.widget as RichText;
    final txt = rt.text.toPlainText();
    if (txt.trim().isEmpty) continue;
    final size = (e.renderObject as dynamic).size as Size;
    final rect = t.getRect(find.byWidget(rt));
    final color = rt.text.style?.color;
    rich.add('"${txt.length > 24 ? '${txt.substring(0, 24)}…' : txt}" size=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} rect=${rect.top.toStringAsFixed(0)},${rect.left.toStringAsFixed(0)} color=$color');
  }
  // ignore: avoid_print
  print('--- $name: exc=$exc htmlSize=${htmlSize.width.toStringAsFixed(0)}x${htmlSize.height.toStringAsFixed(0)}');
  for (final r in rich) {
    // ignore: avoid_print
    print('      $r');
  }
}

void main() {
  testWidgets('geometry', (t) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.reset);

    await geo(t, 'простой p', '<p>Привет, это письмо</p>');
    await geo(t, 'таблица 600px', '<table width="600" style="background-color:#ffffff"><tr><td style="font-size:14px">Текст письма табличной вёрстки</td></tr></table>');
    await geo(t, 'таблица + @media + картинка', '<style>@media (max-width:600px){.c{width:100%}}</style>'
        '<table role="presentation" width="600" style="background-color:#ffffff"><tr><td style="font-family:Arial;font-size:14px;color:#333333">'
        'Скидка недели <img src="data:image/png;base64,$_png" width="140" alt="баннер"> Смотреть</td></tr></table>');
    await geo(t, 'как в рассылке: див с белым фоном', '<div style="background-color:#ffffff;padding:20px"><table width="600"><tr><td>Текст рассылки</td></tr></table></div>');
  });
}
