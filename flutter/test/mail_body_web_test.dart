import 'package:cloudly_flutter/features/mail/mail_body_web.dart';
import 'package:flutter_test/flutter_test.dart';

/// Рамка вокруг письма: заголовок документа и наш скрипт высоты. Сам WebView в юнит-тесте
/// не поднять (это платформенный канал), а вот сборку документа проверить нужно — на ней
/// держатся и ширина письма на телефоне, и запрет исполнять чужое.
void main() {
  group('mailBodyDocument', () {
    test('в полный документ рамка встаёт в head, письмо не трогается', () {
      const mail = '<html><head><title>t</title></head><body><table><tr><td>ячейка</td></tr></table></body></html>';
      final out = mailBodyDocument(mail);

      expect(out, contains('<meta name="viewport"'));
      expect(out, contains('Content-Security-Policy'));
      expect(out, contains('img { max-width: 100% !important; height: auto !important; }'));
      expect(out, contains('<table><tr><td>ячейка</td></tr></table>'));
      // Рамка — внутри head, а не перед ним: до <head> движок часть тегов проигнорирует.
      expect(out.indexOf('<meta name="viewport"'), greaterThan(out.indexOf('<head>')));
      expect(out.indexOf('<meta name="viewport"'), lessThan(out.indexOf('</head>')));
      // Скрипт — в конце тела: к этому моменту document.body уже есть.
      expect(out.indexOf('<script nonce='), greaterThan(out.indexOf('</table>')));
      expect(out.indexOf('<script nonce='), lessThan(out.indexOf('</body>')));
    });

    test('head с атрибутами и заглавные теги тоже понимает', () {
      const mail = '<HTML><HEAD profile="x"><BODY>текст</BODY></HTML>';
      final out = mailBodyDocument(mail);

      expect(out, contains('<HEAD profile="x"><meta http-equiv="Content-Security-Policy"'));
      // Замена регистронезависимая, поэтому закрывающий тег в ответе уже строчный.
      expect(out.indexOf('<script nonce='), lessThan(out.toLowerCase().indexOf('</body>')));
    });

    test('кусок тела заворачивается в документ целиком', () {
      final out = mailBodyDocument('<div>привет</div>');

      expect(out, startsWith('<html><head>'));
      expect(out, contains('<body><div>привет</div>'));
      expect(out, contains('</body></html>'));
    });

    test('nonce скрипта совпадает с nonce в CSP и меняется от письма к письму', () {
      final first = mailBodyDocument('<p>a</p>');
      final second = mailBodyDocument('<p>a</p>');

      String nonceOf(String doc) => RegExp(r"script-src 'nonce-([0-9a-f]+)'").firstMatch(doc)!.group(1)!;
      expect(first, contains('<script nonce="${nonceOf(first)}">'));
      expect(nonceOf(first), isNot(nonceOf(second)));
    });

    test('чужие скрипты не получают наш nonce', () {
      // Чистка на сервере вырезает <script>, но если что-то просочится — CSP его не пустит:
      // исполняется только скрипт с nonce, а он один и наш.
      final out = mailBodyDocument('<body><script>alert(1)</script></body>');
      final nonce = RegExp(r"script-src 'nonce-([0-9a-f]+)'").firstMatch(out)!.group(1)!;

      expect(out, contains('<script>alert(1)</script>'));
      expect(RegExp('nonce="$nonce"').allMatches(out).length, 1);
    });
  });
}
