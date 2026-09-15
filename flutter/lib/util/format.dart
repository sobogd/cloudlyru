/// Форматирование размеров, длительностей и дат — порт вспомогательных функций
/// из `web/src/App.tsx`, `media.tsx` и `mail.tsx`.
library;

String fmt(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

String fmtSize(num bytes) {
  final b = bytes.toInt();
  if (b < 1024) return '$b Б';
  if (b < 1024 * 1024) return '${(b / 1024).round()} КБ';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';
}

String fmtDuration(int sec) {
  final total = sec < 0 ? 0 : sec.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String pad(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '$m:${pad(s)}';
}

const _months = [
  'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь',
  'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь',
];

/// `2024-03` → «Март 2024».
String monthLabel(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;
  final m = int.tryParse(parts[1]);
  return '${(m != null && m >= 1 && m <= 12) ? _months[m - 1] : key} ${parts[0]}';
}

/// Дата письма в списке: сегодня — время, в этом году — число и месяц, иначе с годом.
String listDate(DateTime d, DateTime now) {
  final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
  if (sameDay) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  final dd = d.day.toString().padLeft(2, '0');
  if (d.year == now.year) {
    return '$dd ${_months[d.month - 1].substring(0, 3).toLowerCase()}';
  }
  final mm = d.month.toString().padLeft(2, '0');
  final yy = (d.year % 100).toString().padLeft(2, '0');
  return '$dd.$mm.$yy';
}

/// Полная дата письма: ДД.ММ.ГГ ЧЧ:ММ.
String fullDate(DateTime d) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(d.day)}.${p(d.month)}.${p(d.year % 100)} ${p(d.hour)}:${p(d.minute)}';
}

/// Дата снимка «как в файле» (wall-clock), без пересчёта в пояс устройства.
String fmtMediaDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})').firstMatch(iso);
  if (m == null) return iso;
  final y = m.group(1)!;
  final mo = m.group(2)!;
  final d = m.group(3)!;
  final h = m.group(4)!;
  final mi = m.group(5)!;
  return '$d.$mo.${y.substring(2)} $h:$mi';
}

/// EXIF-даты без часового пояса показываем «как в файле».
String? fmtExifDate(Object? iso) {
  if (iso is! String || iso.isEmpty) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})').firstMatch(iso);
  if (m == null) return null;
  final y = m.group(1)!;
  final mo = m.group(2)!;
  final d = m.group(3)!;
  final h = m.group(4)!;
  final mi = m.group(5)!;
  final s = m.group(6)!;
  return '$d.$mo.$y $h:$mi:$s';
}

/// ISO-дата в местном времени (ffprobe отдаёт время с таймзоной).
String? fmtLocal(Object? iso) {
  if (iso is! String || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Человекочитаемая длительность для метаданных (1:23 / 1:02:03).
String fmtDurationLong(int? sec) {
  if (sec == null) return '—';
  return fmtDuration(sec);
}

/// Число тега без хвостовых нулей: 1.8 → «1.8», 100 → «100», 24.0 → «24».
String trimNum(num v, int digits) {
  return (double.parse(v.toStringAsFixed(digits))).toString();
}
