/// Разделы приложения. У каждого свой набор выбранных папок на телефоне:
/// «Файлы» показывает документы, «Фото» — фото и видео.
enum Section {
  files('FILES', 'Файлы'),
  photos('PHOTOS', 'Фото');

  const Section(this.storageKey, this.label);

  /// Как раздел записан в базе и настройках: значения менять нельзя — там уже лежат данные.
  final String storageKey;
  final String label;

  /// Раздел по значению из базы: неизвестное значение — не повод падать.
  static Section? byStorageKey(String? key) {
    for (final s in Section.values) {
      if (s.storageKey == key) return s;
    }
    return null;
  }
}
