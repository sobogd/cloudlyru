/// Правила выбора папок. Чистые функции без файловой системы: всё, что зависит от диска,
/// приходит аргументом `childDirsOf`, поэтому правила проверяются тестами.
///
/// В наборе всегда «антицепочка» — если папка выбрана, её подпапок в наборе нет: они и так
/// покрыты выбором. На этом правиле держится и дерево выбора, и обход при показе списка.
abstract final class SelectionRules {
  /// Папка покрыта выбором: выбрана сама или лежит внутри выбранной.
  static bool isCovered(Set<String> paths, String path) =>
      paths.any((p) => p == path || path.startsWith('$p/'));

  /// Внутри папки есть выбранные: галочка в состоянии «частично».
  static bool hasInside(Set<String> paths, String path) =>
      paths.any((p) => p.startsWith('$path/'));

  /// Отметить папку: она вбирает всё поддерево, поэтому её подпапки и её предки из набора
  /// уходят — иначе дерево отвечало бы «выбрано» на разные вопросы сразу.
  static Set<String> choose(Set<String> paths, String path) => {
    ...paths.where(
      (p) => p != path && !p.startsWith('$path/') && !path.startsWith('$p/'),
    ),
    path,
  };

  /// Снять выбор. Если папка была покрыта выбранным предком, предка «раскрываем»: убираем его
  /// и отмечаем его прямые подпапки. Иначе снять галочку внутри выбранного дерева было бы нечем.
  static Set<String> unchoose(
    Set<String> paths,
    String path,
    List<String> Function(String) childDirsOf,
  ) {
    var current = paths;
    // Защита от цикла, если файловая система вернёт себя же в качестве подпапки.
    for (var guard = 0; guard < maxUncover; guard++) {
      // самый глубокий выбранный предок: раскрывать надо его, а не весь путь целиком
      String? cover;
      for (final p in current) {
        if (p == path || !path.startsWith('$p/')) continue;
        if (cover == null || p.length > cover.length) cover = p;
      }
      if (cover == null) break;
      final children = childDirsOf(cover);
      current = {...current.where((p) => p != cover), ...children};
      // каталог не читается — раскрыть его нечем, дальше подниматься смысла нет
      if (children.isEmpty) break;
    }
    return current.where((p) => p != path).toSet();
  }

  /// Папки для обхода: без тех, что лежат внутри других выбранных.
  static List<String> scanRoots(Set<String> paths) {
    final out = paths
        .where(
          (p) => !paths.any((other) => other != p && p.startsWith('$other/')),
        )
        .toList();
    out.sort();
    return out;
  }

  static const int maxUncover = 64;
}
