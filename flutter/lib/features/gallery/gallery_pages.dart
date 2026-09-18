import 'package:flutter/foundation.dart';

import '../../api/models.dart';
import 'data/gallery_store.dart';

/// Кадры галереи, прочитанные из локального индекса пачками.
///
/// ## Зачем пачки
///
/// Сетка построена на всю историю (см. `GalleryIndex`), но построена она геометрией: строки
/// знают свои номера кадров, а самих кадров в памяти нет. Читаются только те пачки, которые
/// попросили построенные строки, — то есть вокруг видимого места. Раньше это делало «окно
/// кадров» вокруг якоря; здесь окна нет, потому что и не нужно: строка сама знает свой адрес.
///
/// ## Почему пачка — это месяц
///
/// Номер кадра внутри месяца — единственный адрес, который у сетки есть без чтения данных
/// (строка × четыре клетки, см. `GalleryIndex.specAt`). Поэтому и выборка идёт по месяцу
/// ([GalleryStore.monthItems]), а не курсором «следующие за предыдущим»: прыжок на любой год
/// читает ровно то, что нужно, и ничего не грузит по пути. Размер пачки кратен колонкам сетки,
/// поэтому ряд из четырёх клеток никогда не рвётся между двумя пачками.
///
/// ## Что с памятью
///
/// Держатся только последние [maxPages] пачек: пролистывание всей библиотеки не оставляет
/// в памяти ничего лишнего. Непрочитанная клетка — это `null`, а не ошибка: вёрстка ставит на
/// её место заглушку, и появление кадра ничего не сдвигает.
class GalleryPages {
  GalleryPages({
    required this.store,
    required this.tzOffsetMin,
    required this.onLoaded,
    required this.onError,
  });

  /// Сколько кадров читаем одной пачкой.
  ///
  /// Двести — это пятьдесят рядов сетки, то есть несколько экранов: пачка накрывает видимое
  /// место с запасом на инерцию, и на обычную остановку хватает одного чтения.
  static const int pageSize = 200;

  /// Сколько пачек держим в памяти. Двадцать четыре — около пяти тысяч кадров: больше, чем
  /// показывает окно вокруг видимого места, и ради этого и держится: пачка, выброшенная
  /// слишком рано, читалась бы заново на каждом движении пальца туда-обратно.
  static const int maxPages = 24;

  /// Локальный индекс — источник кадров.
  final GalleryStore store;

  /// Пояс, в котором посчитаны ключи месяцев: с ним же читаются границы месяца.
  final int tzOffsetMin;

  /// Кадры приехали — владельцу есть что перерисовать.
  final VoidCallback onLoaded;

  /// Пачка не прочиталась (сбой базы): владелец показывает причину и даёт повторить.
  final ValueChanged<Object> onError;

  /// Прочитанные пачки: ключ — месяц и номер пачки, порядок ключей — по давности обращения.
  final Map<String, List<MediaItem>> _pages = {};

  /// Пачки, которые читаются прямо сейчас: повторная просьба только дублировала бы запрос.
  final Set<String> _loading = {};

  /// Чтение пачек приостановлено: список едет (см. `GalleryController`).
  ///
  /// Пока прокрутка идёт, в сетке не должно быть ни одного запроса — ни к базе, ни к серверу:
  /// рывок на границе прочитанного как раз оттуда. Незапрошенная клетка стоит заглушкой того же
  /// размера, поэтому «серые блоки, пока едет» ничего не сдвигают, а по остановке строки
  /// спрашивают кадры заново (см. `GalleryController.onScrollingChanged`). Уже прочитанное
  /// отдаётся как обычно: пачка в памяти — это не запрос.
  bool paused = false;

  /// Кадр по номеру [offset] внутри месяца [month]; `null` — пачка ещё не прочитана.
  ///
  /// Заодно просит пачку. Отдельного расчёта видимости не нужно именно потому, что зовут это
  /// построенные строки: спросили — значит, клетка сейчас на экране.
  MediaItem? itemAt(String month, int offset) {
    if (offset < 0) return null;
    final key = _key(month, offset ~/ pageSize);
    final page = _pages.remove(key);
    if (page == null) {
      if (!paused) _request(month, offset ~/ pageSize);
      return null;
    }
    _pages[key] = page; // обращение делает пачку свежей (см. maxPages)
    final i = offset % pageSize;
    return i < page.length ? page[i] : null;
  }

  /// Кадр по номеру [offset] внутри месяца [month] без чтения: `null` — пачки в памяти нет.
  ///
  /// Нужен опросу состояний превью: он смотрит, что видно, но ничего не грузит (см.
  /// `GalleryController.pollStatuses`).
  MediaItem? loadedAt(String month, int offset) {
    if (offset < 0) return null;
    final page = _pages[_key(month, offset ~/ pageSize)];
    if (page == null) return null;
    final i = offset % pageSize;
    return i < page.length ? page[i] : null;
  }

  /// Заменить кадр в прочитанной пачке — новое состояние превью (ответ `/media/status`).
  ///
  /// Возвращает `true`, если замена нашла своё место: пачка могла уже вытесниться, и тогда
  /// менять нечего — следующее чтение принесёт свежее состояние из индекса.
  bool replace(String month, int offset, MediaItem item) {
    final page = _pages[_key(month, offset ~/ pageSize)];
    if (page == null) return false;
    final i = offset % pageSize;
    if (i >= page.length) return false;
    page[i] = item;
    return true;
  }

  /// Сбросить пачки месяца [month]: кадр из него удалён, и номера внутри месяца сдвинулись.
  ///
  /// Сдвиг — на весь остаток месяца, поэтому перечитывать приходится все его пачки, а не одну.
  void dropMonth(String month) {
    final prefix = '$month|';
    _pages.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Перечитать неполные пачки — в них могут доехать кадры.
  ///
  /// Пачка, прочитанная целиком ([pageSize] кадров), дальше не меняется: кадры месяца приходят
  /// от ленты по порядку, от свежих к старым, поэтому дописываются только в конец месяца.
  /// А последняя, неполная пачка месяца растёт с каждым прочитанным кадром, и если оставить её
  /// как есть, низ месяца остался бы заглушками до вытеснения пачки. Пустая пачка — тот же
  /// случай: месяц ещё не прочитан вовсе.
  ///
  /// Прежняя пачка при этом продолжает показываться, пока читается новая: перечитывание идёт
  /// на каждом шаге наполнения индекса (`GalleryController` слушает ход прохода), и гасить
  /// клетки на каждом таком шаге было бы миганием.
  void refreshUnfinished() {
    for (final key in _pages.keys.toList()) {
      final page = _pages[key]!;
      if (page.length >= pageSize || _loading.contains(key)) continue;
      final split = key.lastIndexOf('|');
      _loading.add(key);
      _read(key, key.substring(0, split), int.tryParse(key.substring(split + 1)) ?? 0);
    }
  }

  /// Попросить пачку `page` месяца [month]: прочитанные и читаемые пропускаются.
  void _request(String month, int page) {
    final key = _key(month, page);
    if (_pages.containsKey(key) || _loading.contains(key)) return;
    _loading.add(key);
    _read(key, month, page);
  }

  /// Прочитать пачку `page` месяца [month] и положить её в память под ключом [key].
  ///
  /// Ключ передаётся снаружи, а не собирается здесь: перечитывание уже прочитанной пачки
  /// ([refreshUnfinished]) идёт по её ключу, и собирать его заново значило бы держать разбор
  /// ключа в двух местах.
  void _read(String key, String month, int page) {
    store
        .monthItems(month, tzOffsetMin: tzOffsetMin, offset: page * pageSize, limit: pageSize)
        .then((items) {
      _loading.remove(key);
      // Пустая пачка тоже запоминается: месяца может не быть в индексе вовсе (кадры ещё
      // не прочитаны), и без памяти о пустом ответе каждая перерисовка просила бы снова.
      _pages.remove(key);
      _pages[key] = items;
      while (_pages.length > maxPages) {
        _pages.remove(_pages.keys.first);
      }
      onLoaded();
    }).catchError((Object e) {
      _loading.remove(key);
      onError(e);
    });
  }

  /// Ключ пачки: месяц и её номер. Месяц в ключе — потому что номера кадров считаются внутри
  /// месяца, и «пачка 1» у разных месяцев — разные кадры.
  String _key(String month, int page) => '$month|$page';
}
