import 'package:flutter/material.dart';

/// Панель системного статуса MacBook в разделе настроек «Mac».
///
/// Показывает хост, uptime, CPU, RAM, IP, публичный IP, батарею и диски.
/// Данные берутся из внешнего снимка `/mac/status`, переданного через [status].
class MacStatusPanel extends StatelessWidget {
  const MacStatusPanel({super.key, required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final cpu = _map(s['cpu']);
    final mem = _map(s['mem']);
    final net = _map(s['net']);
    final batt = _map(s['battery']);
    final disks = (s['disk'] is List) ? (s['disk'] as List) : const [];

    /// Строка «ключ — значение» в стиле настроек.
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
              Expanded(child: Text(v)),
            ],
          ),
        );

    /// Строка одного диска: точка монтирования и занято/всего.
    Widget diskRow(Map<String, dynamic> d) => Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('${_str(d['mount']) ?? '?'}: ${d['used_gb']} / ${d['size_gb']} GB (${_str(d['pct']) ?? '?'})',
              style: Theme.of(context).textTheme.bodySmall),
        );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_str(s['host']) ?? 'Mac',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          kv('Uptime', _str(s['uptime']) ?? '—'),
          kv('CPU busy', _fmtPct(cpu['busy'])),
          kv('Load', '${_fmtN(cpu['load1'])}  ${_fmtN(cpu['load5'])}  ${_fmtN(cpu['load15'])}'),
          kv('RAM', '${_fmtN(mem['used_gb'])} / ${_fmtN(mem['total_gb'])} GB (${_fmtPct(mem['used_pct'])})'),
          kv('IP', '${_str(net['ip']) ?? '—'} (${_str(net['iface']) ?? '—'})'),
          if (s['public_ip'] != null) kv('Public IP', '${s['public_ip']}'),
          if (batt['present'] == true)
            kv('Battery', '${_fmtPct(batt['percent'])} · ${_str(batt['state']) ?? ''} ${_str(batt['source']) ?? ''}'),
          const SizedBox(height: 8),
          for (final d in disks) diskRow(_map(d)),
        ],
      ),
    );
  }
}

/// Достаёт вложенный объект; не-объект даёт пустую карту.
Map<String, dynamic> _map(dynamic v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

/// Строковое поле: не-строка даёт `null`.
String? _str(dynamic v) => v is String ? v : null;

/// Число с одним знаком после запятой; `null` → «—».
String _fmtN(dynamic v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return n == null ? '—' : n.toStringAsFixed(1);
}

/// Процент: добавляет «%», если значение есть.
String _fmtPct(dynamic v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return n == null ? '—' : '${n.toStringAsFixed(0)}%';
}
