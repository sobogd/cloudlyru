import 'package:cloudly_flutter/sync/queue/upload_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// Решения выгрузки: ошибка здесь стоит либо не уехавшего файла, либо затёртой чужой версии
/// в облаке. Оба случая дорогие, поэтому правила проверяются без устройства.
void main() {
  final sha = 'a' * 64;
  final other = 'b' * 64;

  group('UploadPlan', () {
    test('на сервере ничего нет — создаём', () {
      expect(UploadPlan.decide(sha, null), UploadAction.create);
    });

    test('то же содержимое — пропускаем', () {
      // содержимое уже в облаке: байты не передаются вовсе
      expect(UploadPlan.decide(sha, sha), UploadAction.skip);
    });

    test('другое содержимое — заменяем', () {
      expect(UploadPlan.decide(sha, other), UploadAction.replace);
    });

    test('свободное имя остаётся собой', () {
      expect(UploadPlan.freeName('отчёт.pdf', const {}), 'отчёт.pdf');
    });

    test('суффикс добавляется перед расширением', () {
      expect(
        UploadPlan.freeName('IMG_0001.jpg', const {'IMG_0001.jpg'}),
        'IMG_0001 (2).jpg',
      );
      expect(
        UploadPlan.freeName('IMG_0001.jpg', const {
          'IMG_0001.jpg',
          'IMG_0001 (2).jpg',
        }),
        'IMG_0001 (3).jpg',
      );
    });

    test('файл без расширения тоже получает суффикс', () {
      expect(UploadPlan.freeName('backup', const {'backup'}), 'backup (2)');
    });
  });
}
