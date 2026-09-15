import 'package:cloudly_flutter/sync/mirror/failure_streak.dart';
import 'package:cloudly_flutter/sync/net/sync_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Счётчик сбоев подряд: им проход останавливается, когда сеть легла. Ошибка здесь стоит
/// либо мёртвого прохода (молотит впустую весь бюджет), либо брошенной работы на полпути.
void main() {
  group('FailureStreak', () {
    test('одиночные сбои не останавливают проход', () {
      final streak = FailureStreak(limit: 5);
      expect(streak.failure(Exception('обрыв')), isFalse);
      streak.success();
      expect(streak.failure(Exception('обрыв')), isFalse);
      expect(streak.broken, isFalse);
    });

    test('пять сбоев подряд останавливают проход и объясняют причину', () {
      final streak = FailureStreak(limit: 5);
      for (var i = 0; i < 4; i++) {
        expect(streak.failure(Exception('нет соединения $i')), isFalse);
      }
      expect(streak.failure(Exception('нет соединения')), isTrue);
      expect(streak.broken, isTrue);
      // причина — самая первая: она ближе всего к тому, что сломалось
      expect(streak.reason, contains('нет соединения 0'));
    });

    test('успех после серии сбоев обнуляет счётчик', () {
      final streak = FailureStreak(limit: 3);
      streak.failure(Exception('a'));
      streak.failure(Exception('b'));
      streak.success();
      expect(streak.broken, isFalse);
      expect(streak.failure(Exception('c')), isFalse);
    });

    test('отозванный токен останавливает сразу и говорит, что делать', () {
      // с отозванным токеном повторять бессмысленно, сколько бы файлов ни осталось
      final streak = FailureStreak(limit: 5);
      final broken = streak.failure(
        const SyncApiException(401, '', 'unauthorized'),
      );
      expect(broken, isTrue);
      expect(streak.reason, 'токен отозван — войдите заново');
    });

    test('запрет доступа тоже останавливает сразу', () {
      final streak = FailureStreak(limit: 5);
      expect(
        streak.failure(const SyncApiException(403, '', 'forbidden')),
        isTrue,
      );
      expect(streak.broken, isTrue);
    });

    test('пока не сломано — причины нет', () {
      final streak = FailureStreak(limit: 5);
      streak.failure(Exception('обрыв'));
      expect(streak.reason, isNull);
    });
  });
}
