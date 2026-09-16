import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Сторона квадрата миниатюры, которую кэширует приложение, в пикселях.
///
/// Обязана совпадать с серверным `GRID_SIZE` (`src/media/media.service.ts`): сетка отдаётся
/// одного размера, и клиент не может попросить другой. Число входит в путь кэша
/// (`thumbs/256/…`), поэтому после смены размера на сервере старый каталог перестаёт
/// находиться и миниатюры скачиваются заново — прежние 100×100 не подмешиваются к новым.
///
/// 256 — под сетку в четыре кадра в ряд: клетка на экране 360 dp это 88 dp, то есть 264
/// физических пикселя на DPR 3. При 100 px картинка растягивалась бы в 3.5 раза.
const int kThumbSize = 256;

/// Итог обхода хранилища: сколько файлов и сколько байт они занимают на диске.
///
/// Считается обходом (см. [ThumbStore.stats]), а не ведётся счётчиком в памяти: счётчик
/// расходится с диском после любой неудачной записи или очистки системой, а обход — это
/// единственная правда. Вызывается редко (экран настроек, отчёт о прогреве).
class ThumbStats {
  /// Сколько файлов миниатюр лежит в хранилище.
  final int files;

  /// Сколько они занимают по мнению файловой системы (округление до блока уже внутри).
  final int bytes;

  const ThumbStats(this.files, this.bytes);

  /// Пустое хранилище — состояние до первого прогрева.
  static const ThumbStats empty = ThumbStats(0, 0);
}

/// Хранилище миниатюр галереи: `.../thumbs/<размер>/<xx>/<sha256>.avif`.
///
/// ## Почему данные приложения, а не кэш-каталог
///
/// В кэш-каталоге (`getTemporaryDirectory`) Android вправе вычистить файлы в любой момент —
/// при нехватке места, по кнопке «Очистить кэш», автоочисткой давно не используемых
/// приложений. Для миниатюр это означало бы, что офлайновая галерея отваливается ровно тогда,
/// когда она и нужна: место кончилось или сети нет. В данных приложения (`files/`) файлы
/// живут до «Очистить данные» или удаления приложения, поэтому своя кнопка очистки и показ
/// размера — не украшение, а обязательная часть (см. `ThumbCache.clear`).
///
/// ## Почему имя файла — sha256, а не id записи
///
/// Содержимое адресуется хэшем: один и тот же файл, залитый дважды (или лежащий в двух
/// папках), — это один объект в облаке и одна миниатюра на диске. Ключ по `entryId` дал бы
/// две копии одной картинки. Побочно решается и инвалидация: миниатюра по sha256 неизменяема,
/// поэтому её не нужно перепроверять и обновлять по времени.
///
/// ## Почему размер в пути, а не в имени файла
///
/// Смена [kThumbSize] меняет каталог целиком: старые миниатюры не находятся (имя ищется
/// в новом каталоге) и удаляются одной операцией ([dropOtherSizes]). Иначе пришлось бы
/// держать в имени `sha-100.avif` и вычищать по маске.
class ThumbStore {
  ThumbStore._(this._root);

  /// Каталог миниатюр текущего размера. Всё, что делает класс, — внутри него.
  final Directory _root;

  /// Что уже лежит на диске — по этому набору [find] отвечает без обращения к файловой системе.
  ///
  /// Проверка нужна в `build` каждой плитки, а плиток на экране несколько десятков: синхронный
  /// `stat` на каждую — это десятки обращений к диску на кадр, и они заметны при быстрой
  /// прокрутке. Набор заполняется при записи и при первом попадании в существующий файл, то
  /// есть цена — один `stat` на миниатюру за всё время работы.
  ///
  /// Оговорка: если файл исчезнет в обход приложения, набор будет считать его существующим.
  /// Данные приложения Android не чистит, а битый или пропавший файл отрисуется заглушкой
  /// (`errorBuilder` у `Image.file`), так что расхождение безопасно.
  final Set<String> _present = {};

  /// Открыть хранилище, создав каталог при первом запуске.
  ///
  /// [size] — сторона квадрата (по умолчанию [kThumbSize]); [directory] — базовый каталог
  /// вместо каталога данных приложения (нужен проверкам на временном каталоге).
  ///
  /// Побочные эффекты: создаёт `thumbs/<размер>`, а также сносит каталоги миниатюр других
  /// размеров ([dropOtherSizes]) — держать их незачем, они больше не находятся, но занимают
  /// место (на библиотеке в 50 тысяч кадров это сотни мегабайт).
  static Future<ThumbStore> open({int size = kThumbSize, String? directory}) async {
    final base = directory ?? (await getApplicationSupportDirectory()).path;
    final thumbs = Directory(p.join(base, 'thumbs'));
    final root = Directory(p.join(thumbs.path, '$size'));
    await root.create(recursive: true);
    final store = ThumbStore._(root);
    await store.dropOtherSizes();
    return store;
  }

  /// Файл миниатюры для этого содержимого. Путь детерминирован — файла может и не быть.
  File fileFor(String sha) => File(p.join(_root.path, sha.substring(0, 2), '$sha.avif'));

  /// Готовый файл миниатюры или `null`, если её ещё нет.
  ///
  /// Синхронный и без обращения к диску за пределами одного `stat`: вызывается из `build`
  /// виджета плитки, где асинхронность означала бы лишний кадр с серой заглушкой на каждом
  /// кадре списка.
  File? find(String sha) {
    if (sha.length < 2) return null;
    if (_present.contains(sha)) return fileFor(sha);
    final f = fileFor(sha);
    if (f.existsSync()) {
      _present.add(sha);
      return f;
    }
    return null;
  }

  /// Записать миниатюру.
  ///
  /// Пишем во временный файл и переименовываем: `rename` в пределах одного каталога атомарен,
  /// поэтому оборванная загрузка (сеть пропала, приложение убили) не оставит обрезанный файл,
  /// который потом считался бы готовой миниатюрой. Имя `.part` тоже годится как признак
  /// «недокачано» — по нему [stats] такие файлы не считает.
  Future<void> put(String sha, List<int> bytes) async {
    final f = fileFor(sha);
    await f.parent.create(recursive: true);
    final part = File('${f.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(f.path);
    _present.add(sha);
  }

  /// Удалить миниатюру (например, когда содержимое пропало из облака).
  Future<void> remove(String sha) async {
    _present.remove(sha);
    final f = fileFor(sha);
    if (await f.exists()) await f.delete();
  }

  /// Сколько миниатюр лежит и сколько места они занимают.
  ///
  /// Обход дерева в отдельном изоляте не нужен: 50 тысяч `stat` — это десятые доли секунды,
  /// а вызывается метод с экрана настроек, не в кадре.
  Future<ThumbStats> stats() async {
    if (!await _root.exists()) return ThumbStats.empty;
    var files = 0;
    var bytes = 0;
    await for (final entity in _root.list(recursive: true, followLinks: false)) {
      if (entity is! File || entity.path.endsWith('.part')) continue;
      files++;
      bytes += await entity.length();
    }
    return ThumbStats(files, bytes);
  }

  /// Стереть все миниатюры. Каталог остаётся: он нужен следующей загрузке.
  Future<void> clear() async {
    _present.clear();
    if (await _root.exists()) await _root.delete(recursive: true);
    await _root.create(recursive: true);
  }

  /// Снести каталоги миниатюр других размеров.
  ///
  /// Ошибки глотаются: если чужой каталог занят или недоступен, это не повод не открыть
  /// хранилище — миниатюры текущего размера важнее уборки.
  Future<void> dropOtherSizes() async {
    final base = _root.parent;
    if (!await base.exists()) return;
    await for (final entity in base.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path) == p.basename(_root.path)) continue;
      // Только каталоги-числа: рядом могут лежать чужие файлы, их не трогаем.
      if (int.tryParse(p.basename(entity.path)) == null) continue;
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // Каталог занят или недоступен — уборка не повод не открыть хранилище.
      }
    }
  }
}
