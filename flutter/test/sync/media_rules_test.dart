import 'package:cloudly_flutter/sync/device/media_rules.dart';
import 'package:cloudly_flutter/sync/section.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разделение на «Фото и видео» и «Файлы» идёт по расширению — эти правила и проверяем.
void main() {
  group('MediaRules', () {
    test('фото и видео попадают в раздел «Фото»', () {
      expect(MediaRules.matches(Section.photos, 'IMG_0001.JPG'), isTrue);
      expect(MediaRules.matches(Section.photos, 'clip.mp4'), isTrue);
      expect(MediaRules.matches(Section.photos, 'raw.dng'), isTrue);
      expect(MediaRules.matches(Section.photos, 'IMG_0002.HEIC'), isTrue);
      expect(MediaRules.matches(Section.photos, 'screencast.mkv'), isTrue);
    });

    test('документы попадают в раздел «Файлы»', () {
      expect(MediaRules.matches(Section.files, 'report.pdf'), isTrue);
      expect(MediaRules.matches(Section.files, 'archive.zip'), isTrue);
      expect(MediaRules.matches(Section.files, 'notes.txt'), isTrue);
      expect(MediaRules.matches(Section.files, 'voice.opus'), isTrue);
      expect(MediaRules.matches(Section.files, 'backup.tar.gz'), isTrue);
    });

    test('разделы не пересекаются', () {
      for (final name in [
        'photo.jpg',
        'video.mp4',
        'doc.pdf',
        'noext',
        'file.zip',
      ]) {
        expect(
          MediaRules.matches(Section.files, name) &&
              MediaRules.matches(Section.photos, name),
          isFalse,
          reason: 'файл $name не должен попадать в оба раздела',
        );
      }
    });

    test('файл без расширения — это файл', () {
      expect(MediaRules.isMedia('noext'), isFalse);
      expect(MediaRules.matches(Section.files, 'noext'), isTrue);
    });

    test('скрытое и недописанное не показываем', () {
      expect(MediaRules.isHidden('.nomedia'), isTrue);
      expect(MediaRules.isHidden('.thumbnails'), isTrue);
      expect(MediaRules.isJunk('video.mp4.part'), isTrue);
      expect(MediaRules.isJunk('download.crdownload'), isTrue);
      expect(MediaRules.isJunk('photo.jpg'), isFalse);
    });

    test('служебные каталоги пропускаются', () {
      expect(MediaRules.skipDir('data', 'Android'), isTrue);
      expect(MediaRules.skipDir('obb', 'Android'), isTrue);
      expect(
        MediaRules.skipDir('media', 'Android'),
        isFalse,
        reason: 'медиа приложений показываем',
      );
      expect(MediaRules.skipDir('.thumbnails', 'DCIM'), isTrue);
      expect(MediaRules.skipDir('.trashed', 'Pictures'), isTrue);
      expect(MediaRules.skipDir('Camera', 'DCIM'), isFalse);
      expect(
        MediaRules.skipDir('Android', '0'),
        isFalse,
        reason: 'каталог Android на верхнем уровне не пропускаем',
      );
      // ── Дополнено сверх Kotlin-набора (проверено мутациями) ──
      // проверенные выше .thumbnails и .trashed есть и в списке служебных имён,
      // поэтому правило «скрытое не показываем» ими не проверяется вовсе
      expect(
        MediaRules.skipDir('.hidden', 'DCIM'),
        isTrue,
        reason: 'скрытый каталог пропускаем и без списка служебных имён',
      );
      expect(
        MediaRules.skipDir('data', 'Download'),
        isFalse,
        reason: 'data вне Android — обычная папка пользователя',
      );
    });

    test('размер читается человеком', () {
      expect(MediaRules.formatSize(512), '512 Б');
      expect(MediaRules.formatSize(1024), '1.0 КБ');
      expect(MediaRules.formatSize(1024 * 1024 * 3 ~/ 2), '1.5 МБ');
      expect(MediaRules.formatSize(2 * 1024 * 1024 * 1024), '2.0 ГБ');
      // ── Дополнено сверх Kotlin-набора (проверено мутациями) ──
      // крупные размеры идут без десятых: «15 МБ», а не «15.0 МБ»
      expect(MediaRules.formatSize(15 * 1024 * 1024), '15 МБ');
    });

    /// Чужое приложение просит конкретный тип: показывать ему что-то другое нельзя.
    test('фильтр запроса пропускает только то, что просили', () {
      expect(MediaRules.matchesRequest('image/*', 'image/jpeg'), isTrue);
      expect(
        MediaRules.matchesRequest('image/*', 'video/mp4'),
        isFalse,
        reason: 'просили картинку, а это видео',
      );
      expect(
        MediaRules.matchesRequest('application/pdf', 'application/pdf'),
        isTrue,
      );
      expect(
        MediaRules.matchesRequest('application/pdf', 'image/png'),
        isFalse,
      );
      expect(
        MediaRules.matchesRequest('*/*', 'video/mp4'),
        isTrue,
        reason: 'все типы — показываем всё',
      );
      expect(MediaRules.matchesRequest(null, 'video/mp4'), isTrue);
      expect(
        MediaRules.matchesRequest('image/*', ''),
        isFalse,
        reason: 'тип неизвестен, а просили конкретный',
      );
    });
  });
}
