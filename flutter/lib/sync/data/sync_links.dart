import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Связка «папка на устройстве ↔ папка в облаке» — то, что человек выбрал руками.
///
/// Раньше пары складывались сами: клиент брал отмеченные в дереве папки и заводил каждой
/// папку в корне зеркала устройства (`<Имя> - Файлы/<имя>`). Теперь обе стороны выбирает
/// человек, и ни одна облачная папка не заводится автоматически.
///
/// [cloudPath] хранится рядом с идентификатором только для показа: папку могут переименовать
/// или перенести в вебе, и тогда это путь на момент связывания, а не истина. Истина — [cloudId].
class SyncLink {
  /// [localPath] — путь папки на телефоне (он же ключ связки), [cloudId] — id папки в облаке,
  /// [cloudPath] — её путь в облаке для подписи в интерфейсе.
  const SyncLink({
    required this.localPath,
    required this.cloudId,
    required this.cloudPath,
  });

  final String localPath;
  final String cloudId;
  final String cloudPath;

  /// Связка из строки настроек или `null`, если строка битая.
  ///
  /// Строку пишет только этот класс, но настроек касаются и прежние сборки приложения:
  /// непонятная запись не должна ронять чтение всего списка.
  static SyncLink? fromJsonString(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final local = decoded['local'];
      final cloud = decoded['cloud'];
      final path = decoded['path'];
      if (local is! String || cloud is! String || path is! String) return null;
      if (local.isEmpty || cloud.isEmpty) return null;
      return SyncLink(localPath: local, cloudId: cloud, cloudPath: path);
    } catch (_) {
      return null;
    }
  }

  /// Строка для настроек: короткая и без вложенных кавычек в значениях путей.
  String toJsonString() =>
      jsonEncode({'local': localPath, 'cloud': cloudId, 'path': cloudPath});
}

/// Связки раздела «Файлы»: один список, ключ `sync_links_files`.
///
/// Лежат в обычных настройках (не в шифрованном хранилище): путь и id папки — не секрет,
/// и тот же выбор путей уже хранился здесь (см. `Selection`). Обновление приложения их
/// не теряет: настройки живут в данных приложения и переживают установку новой сборки поверх.
/// Пропадают они только вместе с данными приложения — тогда связки создаются заново руками.
///
/// Пользуются: экран «Связки» (показать, добавить, удалить), зеркало (`MirrorEngine`,
/// `MirrorWatcher`), фоновый проход (`background_pass.dart`) и раздел «Файлы» — по связкам
/// он помечает папки, которые синхронизируются.
///
/// Один список на раздел «Файлы», и он же единственный: у «Фото» свой механизм (медиатека,
/// односторонняя заливка), связок там нет.
class SyncLinks {
  /// [_prefs] — обычные настройки приложения: список переживает перезапуск.
  SyncLinks(this._prefs);

  final SharedPreferences _prefs;

  /// Ключ списка. Строка задана явно и меняться не должна: под ней уже лежат связки.
  static const String key = 'sync_links_files';

  /// Разобрать список связок из строки настроек.
  ///
  /// Храним JSON-массив строк: одна строка на связку, поэтому испорченная запись теряет только
  /// себя, а не весь список. Список сортируется по пути на телефоне — так он одинаков
  /// при одном и том же наборе связок, и «ничего не менялось» видно по самой строке в настройках.
  static List<SyncLink> parse(List<String> raw) {
    final out = <SyncLink>[];
    for (final item in raw) {
      final link = SyncLink.fromJsonString(item);
      if (link != null) out.add(link);
    }
    out.sort((a, b) => a.localPath.compareTo(b.localPath));
    return out;
  }

  /// Связки в порядке путей на телефоне.
  ///
  /// Отдаёт новый список: правка результата в настройки не попадает, менять связки можно
  /// только через [put], [remove] и [replaceAll].
  List<SyncLink> all() => parse(_prefs.getStringList(key) ?? const <String>[]);

  /// Папки на телефоне, которые сейчас связаны: это корни обхода зеркала.
  List<String> localPaths() => [for (final l in all()) l.localPath];

  /// Папки в облаке, которые сейчас связаны: по ним раздел «Файлы» отличает синхронизируемую
  /// папку от обычной.
  Set<String> cloudIds() => {for (final l in all()) l.cloudId};

  /// Связка по пути на телефоне или `null`, если такой папки никто не связывал.
  SyncLink? byLocalPath(String path) {
    for (final link in all()) {
      if (link.localPath == path) return link;
    }
    return null;
  }

  /// Добавить связку или заменить прежнюю с тем же путём на телефоне.
  ///
  /// Побочный эффект: запись в SharedPreferences. Отказ записи виден только в журнале —
  /// показать его здесь некому (так же, как у выбора папок в `Selection`): незаписанная связка
  /// выглядит как созданная, а после перезапуска её нет.
  Future<List<SyncLink>> put(SyncLink link) {
    final next = all()
        .where((l) => l.localPath != link.localPath)
        .toList()
      ..add(link);
    return _store(next);
  }

  /// Убрать связку по пути на телефоне. В облаке не удаляется ничего: снимается только
  /// соответствие, папка и файлы в ней остаются как были.
  Future<List<SyncLink>> remove(String localPath) =>
      _store(all().where((l) => l.localPath != localPath).toList());

  /// Записать весь список (перенос старого выбора, разовая уборка).
  Future<List<SyncLink>> replaceAll(List<SyncLink> links) => _store(links);

  /// Записать список в настройки и вернуть его же — интерфейсу новый набор нужен сразу,
  /// не перечитывая настройки.
  Future<List<SyncLink>> _store(List<SyncLink> links) async {
    final sorted = [...links]
      ..sort((a, b) => a.localPath.compareTo(b.localPath));
    final raw = [for (final l in sorted) l.toJsonString()];
    if (!await _prefs.setStringList(key, raw)) {
      debugPrint('cloudly-sync: связки не сохранены: $key');
    }
    return sorted;
  }
}

/// Правила связок: чистые проверки без настроек и сети.
///
/// Связка ломает зеркало двумя способами, и оба надо отсечь до записи:
///   • две связки на одну папку облака — пары «папка облака ↔ путь на телефоне» в базе зеркала
///     ключуются по id облачной папки, и вторая связка затёрла бы первую: файлы одного дерева
///     уехали бы в чужое;
///   • вложенные связки — обход зеркала выбрасывает вложенный корень (он и так покрыт внешним),
///     то есть вторая связка молча ничего бы не синхронизировала, а её папка в облаке
///     осталась бы пустой.
abstract final class SyncLinkRules {
  /// Почему связку нельзя добавить, или `null`, если можно.
  ///
  /// [links] — уже созданные связки, [candidate] — новая.
  static String? conflict(List<SyncLink> links, SyncLink candidate) {
    for (final link in links) {
      if (link.cloudId == candidate.cloudId) {
        return 'папка облака «${candidate.cloudPath}» уже связана '
            'с «${link.localPath}»';
      }
      if (link.localPath == candidate.localPath) {
        return 'папка устройства «${candidate.localPath}» уже связана '
            'с «${link.cloudPath}»';
      }
      if (_inside(candidate.localPath, link.localPath) ||
          _inside(link.localPath, candidate.localPath)) {
        return 'папки «${candidate.localPath}» и «${link.localPath}» вложены '
            'друг в друга: связка была бы не одна, а вторая ничего не делала';
      }
    }
    return null;
  }

  /// Путь лежит внутри другого пути или совпадает с ним.
  ///
  /// Сравнение по разделителю: `/s/DCIM` не покрывает соседнюю `/s/DCIM2`, у которой общее
  /// только начало имени.
  static bool _inside(String path, String root) =>
      path == root || path.startsWith('$root/');
}
