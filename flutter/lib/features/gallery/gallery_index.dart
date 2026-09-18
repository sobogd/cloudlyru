import '../../api/models.dart';
import 'gallery_rows.dart';

/// Место одного месяца в полной сетке галереи.
///
/// Блоки идут в порядке ленты — от свежих месяцев к старым, хвост кадров без даты последним, —
/// и каждый помнит, где он начинается: `firstRow` переводит строку в месяц, `firstItem` —
/// кадр в свой месяц. Обе величины нужны на каждом шаге (вёрстка, чтение кадров, поиск места
/// чтения при пересборке), поэтому и лежат рядом, а не считаются заново.
class GalleryBlock {
  const GalleryBlock({
    required this.month,
    required this.count,
    required this.firstItem,
    required this.firstRow,
    required this.top,
    required this.rows,
  });

  /// Ключ месяца «ГГГГ-ММ»; пустая строка — блок кадров без даты съёмки.
  final String month;

  /// Сколько кадров в блоке.
  final int count;

  /// Номер первого кадра блока во всей ленте.
  final int firstItem;

  /// Номер строки заголовка блока: за ним идут только ряды кадров.
  final int firstRow;

  /// Смещение начала блока от начала списка.
  final double top;

  /// Сколько строк занимает блок вместе с заголовком.
  final int rows;
}

/// Что стоит в одной строке сетки: заголовок месяца, ряд кадров или строка состояния.
///
/// Кадров здесь нет намеренно: индекс — это геометрия и адреса. Какие именно кадры лягут
/// в клетки ряда, знает тот, у кого они есть (см. `GalleryPages`), а строке достаточно
/// сказать, откуда их брать ([firstItem]) и сколько их ([cells]).
class GalleryRowSpec {
  const GalleryRowSpec._({
    required this.month,
    required this.firstItem,
    required this.monthOffset,
    required this.cells,
    required this.rowInBlock,
    required this.top,
    required this.height,
    required this.header,
    required this.note,
  });

  /// Заголовок месяца.
  factory GalleryRowSpec.header({
    required String month,
    required int rowInBlock,
    required double top,
    required double height,
  }) =>
      GalleryRowSpec._(
        month: month,
        firstItem: -1,
        monthOffset: 0,
        cells: 0,
        rowInBlock: rowInBlock,
        top: top,
        height: height,
        header: true,
        note: false,
      );

  /// Ряд кадров месяца [month]: [cells] клеток, начиная с кадра номер [firstItem] ленты.
  factory GalleryRowSpec.items({
    required String month,
    required int firstItem,
    required int monthOffset,
    required int cells,
    required int rowInBlock,
    required double top,
    required double height,
  }) =>
      GalleryRowSpec._(
        month: month,
        firstItem: firstItem,
        monthOffset: monthOffset,
        cells: cells,
        rowInBlock: rowInBlock,
        top: top,
        height: height,
        header: false,
        note: false,
      );

  /// Строка состояния в конце списка (см. `GalleryController.footerNote`).
  factory GalleryRowSpec.note({required double top, required double height}) => GalleryRowSpec._(
        month: '',
        firstItem: -1,
        monthOffset: 0,
        cells: 0,
        rowInBlock: 0,
        top: top,
        height: height,
        header: false,
        note: true,
      );

  /// Месяц строки: «ГГГГ-ММ», пустая строка — кадры без даты; у строки состояния пусто.
  final String month;

  /// Номер первого кадра ряда во всей ленте; у заголовка и строки состояния `-1`.
  final int firstItem;

  /// Номер первого кадра ряда ВНУТРИ месяца — по нему кадры читаются из индекса.
  ///
  /// Два номера у ряда не для симметрии: по номеру в ленте кадр берёт просмотрщик (он листает
  /// всю ленту), а чтение из базы идёт окном внутри месяца (см. `GalleryStore.monthItems`).
  final int monthOffset;

  /// Сколько клеток в ряду; у заголовка и строки состояния `0`.
  final int cells;

  /// Номер строки внутри месяца: 0 — заголовок, дальше ряды кадров.
  ///
  /// Им место чтения и запоминается: номер строки в списке сдвигается от каждой загрузки
  /// сверху, а «месяц и место внутри него» — нет (см. `GalleryIndex.topOfPlace`).
  final int rowInBlock;

  /// Смещение начала строки от начала списка.
  final double top;

  /// Высота строки.
  final double height;

  /// Заголовок ли это месяца.
  final bool header;

  /// Строка состояния ли это.
  final bool note;
}

/// Полная сетка галереи: все кадры индекса, разложенные по строкам.
///
/// ## Зачем полная, а не окно вокруг якоря
///
/// Прежняя сетка была окном кадров: список не знал ни начала, ни конца и достраивался
/// страницами в обе стороны от якоря. Из этого следовало всё остальное — переход к другому
/// году сбрасывал окно и ждал страницу, подпись месяца считалась по видимому кадру, а позиция
/// прокрутки сама по себе ничего не значила.
///
/// Здесь геометрия известна целиком и до кадров: разбивка по месяцам (`GalleryStore.months`)
/// говорит, сколько кадров в каждом месяце, а заголовок и ряд из четырёх клеток дают строки
/// известной высоты. Значит, список строится сразу на всю историю, а вёрстка
/// (`SliverVariedExtentList`) получает точную длину, не построив ни одной строки заранее.
///
/// ## Почему это не «нарисовать семьдесят тысяч плиток»
///
/// Объектов по числу кадров здесь нет: блок — это месяц, а не кадр, и на семьдесят тысяч
/// кадров их сотни. Строки не хранятся списком: номер строки переводится в смещение и обратно
/// арифметикой по блокам, а кадры читаются только для построенных строк (`GalleryPages`).
///
/// ## Чего здесь нет
///
/// Кадров и высоты клетки: [rowStep] приходит готовым (сторона клетки считается от ширины
/// экрана, см. `GalleryGrid.cellSide`), а сами кадры отдаёт тот, у кого они есть.
class GalleryIndex {
  /// Собрать индекс по разбивке на месяцы при ширине сетки [width].
  ///
  /// [hasNote] — есть ли в конце списка строка состояния: её высота входит в общую, и без
  /// неё позиция прокрутки в конце списка не совпала бы с содержимым.
  factory GalleryIndex({
    required List<MediaMonthBucket> months,
    required double width,
    required bool hasNote,
  }) {
    final rowStep = GalleryGrid.rowStep(width);
    return GalleryIndex._(
      hasNote: hasNote,
      rowStep: rowStep,
      layout: _layout(months, rowStep, hasNote),
    );
  }

  GalleryIndex._({required this.hasNote, required this.rowStep, required _Layout layout}) : _l = layout;

  /// Шаг ряда кадров: сторона клетки плюс зазор. Высоты строк берутся отсюда.
  final double rowStep;

  /// Есть ли в конце списка строка состояния.
  final bool hasNote;

  /// Раскладка, посчитанная один раз: блоки, число строк, высота списка, число кадров.
  final _Layout _l;

  /// Сколько строк в списке — по этому числу вёрстка спрашивает строки.
  int get rowCount => _l.rowCount;

  /// Сколько всего кадров в индексе.
  int get itemCount => _l.itemCount;

  /// Полная высота списка со всеми строками.
  double get height => _l.height;

  /// Кадров нет вовсе: показывать нечего (разбивка пуста или индекс ещё не наполнен).
  bool get isEmpty => _l.itemCount == 0;

  /// Что стоит в строке [row].
  ///
  /// Строку за границами списка отдаёт крайней: вёрстка спрашивает только существующие
  /// (их число она знает из [rowCount]), а рисовать пустоту вместо строки при ошибке в счёте
  /// хуже, чем показать соседнюю.
  GalleryRowSpec specAt(int row) {
    if (_l.rowCount == 0) return GalleryRowSpec.note(top: 0, height: GalleryGrid.noteHeight);
    final r = row.clamp(0, _l.rowCount - 1);
    if (hasNote && r == _l.rowCount - 1) {
      return GalleryRowSpec.note(top: _l.height - GalleryGrid.noteHeight, height: GalleryGrid.noteHeight);
    }
    final b = _blockAtRow(r);
    if (b == null) return GalleryRowSpec.note(top: 0, height: GalleryGrid.noteHeight);
    final k = r - b.firstRow;
    if (k == 0) {
      return GalleryRowSpec.header(
        month: b.month,
        rowInBlock: 0,
        top: b.top,
        height: GalleryGrid.headerHeight,
      );
    }
    // Ряды кадров идут по четыре: первый кадр ряда — четвёртый по счёту от начала месяца.
    final first = (k - 1) * GalleryGrid.columns;
    final left = b.count - first;
    return GalleryRowSpec.items(
      month: b.month,
      firstItem: b.firstItem + first,
      monthOffset: first,
      cells: left < GalleryGrid.columns ? left : GalleryGrid.columns,
      rowInBlock: k,
      top: b.top + GalleryGrid.headerHeight + (k - 1) * rowStep,
      height: rowStep,
    );
  }

  /// Высота строки [row] — ею вёрстка считает полную высоту списка и позицию строки.
  ///
  /// Памятка последнего вызова — не микрооптимизация ради: `SliverVariedExtentList` зовёт это
  /// на каждом шаге линейного обхода (позиция прокрутки переводится в строку счётом от начала
  /// списка), и без памятки обход восемнадцати тысяч строк стоил бы бинарного поиска на каждой
  /// строке — это миллисекунды в каждом кадре прокрутки. Последовательный вызов, который
  /// в обходе и бывает, обслуживается одним шагом.
  double heightOfRow(int row) {
    if (row < 0 || row >= _l.rowCount) return 0;
    if (hasNote && row == _l.rowCount - 1) return GalleryGrid.noteHeight;
    return _place(row).inBlock == 0 ? GalleryGrid.headerHeight : rowStep;
  }

  /// Строка, накрывающая смещение [offset] от начала списка.
  ///
  /// `-1` — строк нет вовсе. Смещение за концом списка даёт последнюю строку: так делает
  /// и прокрутка, доведённая до края.
  int rowAtOffset(double offset) {
    if (_l.rowCount == 0) return -1;
    if (offset <= 0) return 0;
    final content = _l.height - (hasNote ? GalleryGrid.noteHeight : 0);
    if (offset >= content) return _l.rowCount - 1;
    final b = _l.blocks[_blockIndexAtTop(offset)];
    final dy = offset - b.top;
    if (dy < GalleryGrid.headerHeight) return b.firstRow;
    final k = 1 + ((dy - GalleryGrid.headerHeight) / rowStep).floor();
    return b.firstRow + k.clamp(1, b.rows - 1);
  }

  /// Смещение начала строки места чтения: месяц [month] и номер строки [rowInBlock] в нём.
  ///
  /// Место задаётся именно так, а не номером строки в списке: номер сдвигается от каждой
  /// загрузки сверху (и от каждой смены раскладки меняет высоту), а «месяц и место внутри
  /// него» переживает и то и другое. Месяца может уже не быть — его кадры удалили; тогда
  /// берётся ближайший старый.
  double topOfPlace(String month, int rowInBlock) {
    final i = _blockIndexOfMonth(month) ?? _blockIndexAtOrOlder(month) ?? _l.blocks.length - 1;
    if (i < 0) return 0;
    final b = _l.blocks[i];
    if (rowInBlock <= 0) return b.top;
    return b.top + GalleryGrid.headerHeight + (rowInBlock.clamp(0, b.rows - 1) - 1) * rowStep;
  }

  /// Где лежит кадр номер [item]: месяц и его номер внутри месяца; `null` — кадра нет.
  ///
  /// Так кадр находится по номеру, известному вёрстке (строка × четыре клетки): без этого
  /// чтение из индекса шло бы перебором всех блоков на каждую клетку.
  ({String month, int offset})? locateItem(int item) {
    if (item < 0 || item >= _l.itemCount) return null;
    var lo = 0;
    var hi = _l.blocks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_l.blocks[mid].firstItem <= item) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final b = _l.blocks[lo];
    return (month: b.month, offset: item - b.firstItem);
  }

  /// Номер блока, накрывающего строку [row]; `null` — строки нет.
  GalleryBlock? _blockAtRow(int row) {
    if (row < 0 || row >= _l.rowCount) return null;
    return _l.blocks[_blockIndexAtRow(row)];
  }

  /// Номер блока строки [row]; зовётся только для строк, которые блоки и занимают.
  int _blockIndexAtRow(int row) {
    var lo = 0;
    var hi = _l.blocks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_l.blocks[mid].firstRow <= row) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Номер блока, накрывающего смещение [offset]: последний, который начинается не позже.
  int _blockIndexAtTop(double offset) {
    var lo = 0;
    var hi = _l.blocks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_l.blocks[mid].top <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Номер блока месяца [month]; `null` — такого месяца в индексе нет.
  int? _blockIndexOfMonth(String month) {
    final dated = month.isEmpty ? _l.blocks.length : _datedCount;
    for (var i = 0; i < dated; i++) {
      final cmp = _l.blocks[i].month.compareTo(month);
      if (cmp == 0) return i;
      if (cmp < 0) return null; // месяцы по убыванию: дальше только старее запрошенного
    }
    return null;
  }

  /// Номер ближайшего блока не новее [month].
  ///
  /// Перебор, а не бинарный поиск: блоков сотни, а зовётся это по отпусканию ползунка и при
  /// восстановлении места чтения — то есть не в кадре прокрутки (в отличие от перевода
  /// «смещение ↔ строка», где поиск идёт на каждом шаге).
  ///
  /// Старше всей ленты — самый старый её месяц: места чтения вне списка не бывает. Если
  /// датированных месяцев нет вовсе, остаётся последний блок — кадры без даты.
  int? _blockIndexAtOrOlder(String month) {
    final dated = _datedCount;
    for (var i = 0; i < dated; i++) {
      if (_l.blocks[i].month.compareTo(month) <= 0) return i;
    }
    if (dated > 0) return dated - 1;
    return _l.blocks.isEmpty ? null : _l.blocks.length - 1;
  }

  /// Сколько блоков занимают датированные месяцы (кадры без даты — последний блок).
  int get _datedCount =>
      _l.blocks.isNotEmpty && _l.blocks.last.month.isEmpty ? _l.blocks.length - 1 : _l.blocks.length;

  /// Место строки [row] в блоках — с памяткой о прошлом вызове (см. [heightOfRow]).
  ({int block, int inBlock}) _place(int row) {
    if (row == _memoRow) return (block: _memoBlock, inBlock: _memoInBlock);
    if (_memoRow >= 0 && row == _memoRow + 1) {
      // Последовательный обход — обычный случай: шаг от прошлого места, без поиска.
      var block = _memoBlock;
      var inBlock = _memoInBlock + 1;
      while (block < _l.blocks.length && inBlock >= _l.blocks[block].rows) {
        inBlock -= _l.blocks[block].rows;
        block++;
      }
      return _memo(row: row, block: block, inBlock: inBlock);
    }
    final block = _blockIndexAtRow(row);
    return _memo(row: row, block: block, inBlock: row - _l.blocks[block].firstRow);
  }

  /// Запомнить место строки в блоках и отдать его.
  ({int block, int inBlock}) _memo({required int row, required int block, required int inBlock}) {
    _memoRow = row;
    _memoBlock = block;
    _memoInBlock = inBlock;
    return (block: block, inBlock: inBlock);
  }

  /// Номер строки последнего обращения к [heightOfRow] и её место в блоках.
  int _memoRow = -1;
  int _memoBlock = 0;
  int _memoInBlock = 0;

  /// Разложить месяцы по строкам сетки.
  ///
  /// Пустые месяцы пропускаются: в ленте они не занимают места. Хвост кадров без даты идёт
  /// последним блоком: в ленте такие кадры идут после всех датированных.
  static _Layout _layout(List<MediaMonthBucket> months, double rowStep, bool hasNote) {
    final dated = months.where((m) => (m.month ?? '').isNotEmpty && m.count > 0).toList()
      ..sort((a, b) => b.month!.compareTo(a.month!));
    var undated = 0;
    for (final m in months) {
      if ((m.month ?? '').isEmpty) undated = m.count;
    }
    final blocks = <GalleryBlock>[];
    var firstItem = 0;
    var firstRow = 0;
    var top = 0.0;
    void add(String month, int count) {
      if (count <= 0) return;
      final rows = 1 + (count + GalleryGrid.columns - 1) ~/ GalleryGrid.columns;
      blocks.add(GalleryBlock(
        month: month,
        count: count,
        firstItem: firstItem,
        firstRow: firstRow,
        top: top,
        rows: rows,
      ));
      firstItem += count;
      firstRow += rows;
      top += GalleryGrid.headerHeight + (rows - 1) * rowStep;
    }

    for (final m in dated) {
      add(m.month!, m.count);
    }
    add('', undated);
    return (
      blocks: blocks,
      rowCount: firstRow + (hasNote ? 1 : 0),
      height: top + (hasNote ? GalleryGrid.noteHeight : 0),
      itemCount: firstItem,
    );
  }
}

/// Раскладка индекса: блоки и итоги по ним.
typedef _Layout = ({
  List<GalleryBlock> blocks,
  int rowCount,
  double height,
  int itemCount,
});
