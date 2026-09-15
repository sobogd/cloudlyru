import 'package:cloudly_flutter/sync/data/selection_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Выбор папок: отметка вбирает поддерево, снятие отметки внутри выбранной папки раскрывает
/// предка. Ошибка здесь означает либо потерянный выбор, либо папку, которую невозможно снять.
void main() {
  /// Заглушка файловой системы: у каждой папки ровно те подпапки, что перечислены.
  List<String> childDirs(String path) => switch (path) {
    '/s/DCIM' => const ['/s/DCIM/Camera', '/s/DCIM/Screenshots'],
    '/s/DCIM/Camera' => const ['/s/DCIM/Camera/raw'],
    '/s/Download' => const ['/s/Download/Telegram'],
    _ => const [],
  };

  group('SelectionRules', () {
    test('отмеченная папка вбирает своё поддерево', () {
      final chosen = SelectionRules.choose({'/s/DCIM/Camera'}, '/s/DCIM');

      // подпапка уходит из набора: она и так покрыта, а два ответа на один вопрос — это баг
      expect(chosen, {'/s/DCIM'});
      expect(SelectionRules.isCovered(chosen, '/s/DCIM/Camera/raw'), isTrue);
      expect(SelectionRules.hasInside(chosen, '/s/DCIM'), isFalse);
    });

    test('частично отмеченная папка не считается покрытой', () {
      final chosen = {'/s/DCIM/Camera'};

      expect(SelectionRules.isCovered(chosen, '/s/DCIM'), isFalse);
      expect(SelectionRules.hasInside(chosen, '/s/DCIM'), isTrue);
      expect(SelectionRules.isCovered(chosen, '/s/DCIM/Camera'), isTrue);
    });

    test('снятие галочки внутри отмеченной папки раскрывает предка', () {
      final chosen = SelectionRules.unchoose(
        {'/s/DCIM'},
        '/s/DCIM/Camera',
        childDirs,
      );

      // «DCIM» раскрылся, камера выпала, скриншоты остались выбранными
      expect(chosen, {'/s/DCIM/Screenshots'});
      expect(SelectionRules.isCovered(chosen, '/s/DCIM/Camera'), isFalse);
      expect(SelectionRules.isCovered(chosen, '/s/DCIM/Screenshots'), isTrue);
    });

    test('снятие глубокой папки сохраняет соседей', () {
      final chosen = SelectionRules.unchoose(
        {'/s/DCIM'},
        '/s/DCIM/Camera/raw',
        childDirs,
      );

      expect(chosen, {'/s/DCIM/Screenshots'});
    });

    test('снятие отметки с самой папки просто убирает её', () {
      final chosen = SelectionRules.unchoose(
        {'/s/DCIM/Camera'},
        '/s/DCIM/Camera',
        childDirs,
      );

      expect(chosen, isEmpty);
    });

    test('нечитаемая папка не зацикливает снятие отметки', () {
      // подпапки неизвестны — раскрывать нечем, но и зацикливаться нельзя
      final chosen = SelectionRules.unchoose(
        {'/s/DCIM'},
        '/s/DCIM/Camera',
        (_) => const [],
      );

      expect(chosen, isEmpty);
    });

    test('папки для обхода не содержат вложенных в другие выбранные', () {
      final roots = SelectionRules.scanRoots({
        '/s/DCIM/Camera',
        '/s/DCIM',
        '/s/Download',
      });

      expect(roots, ['/s/DCIM', '/s/Download']);
    });

    // ── Дополнено сверх Kotlin-набора ────────────────────────────────────────
    // Проверено мутациями: в Kotlin-наборе прикрыта только половина правила —
    // «отметка вбирает подпапки», а вторая половина («…и убирает предков») нет.

    test('отметка вложенной папки убирает отмеченного предка', () {
      // в наборе всегда «антицепочка»: предок и потомок вместе отвечали бы на один
      // и тот же вопрос дважды, и галочка показывала бы два состояния сразу
      final chosen = SelectionRules.choose({'/s/DCIM'}, '/s/DCIM/Camera');

      expect(chosen, {'/s/DCIM/Camera'});
      expect(SelectionRules.hasInside(chosen, '/s/DCIM'), isTrue);
      expect(SelectionRules.isCovered(chosen, '/s/DCIM'), isFalse);
    });

    test('папки для обхода всегда отсортированы', () {
      // порядок обхода показывается в прогрессе и определяет порядок выгрузки:
      // он не должен зависеть от того, в каком порядке папки отметили
      final roots = SelectionRules.scanRoots({
        '/s/Download',
        '/s/DCIM/Camera',
        '/s/DCIM',
      });

      expect(roots, ['/s/DCIM', '/s/Download']);
    });
  });
}
