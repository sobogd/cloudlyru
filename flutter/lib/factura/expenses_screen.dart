import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/format.dart';
import 'expense_form_screen.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран «Расходы»: полученные счета, которые уменьшают базу IRPF и дают вычет НДС.
///
/// Номеров и VeriFactu у расходов нет — это документы поставщика, их только агрегируют для
/// квартальных деклараций. Поэтому список простой: по месяцам, с итогом и пометкой о том,
/// что к расходу приложен скан.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

/// Состояние списка расходов.
class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  /// Расходы в порядке от сервера (свежие сверху).
  List<ExpenseView> _rows = const [];

  /// Идёт первая загрузка.
  bool _loading = true;

  /// Текст последней неудачи.
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает список расходов.
  ///
  /// Побочные эффекты: обновляет [_rows] или [_error] и перерисовывает экран.
  Future<void> _load() async {
    try {
      final rows = await ref.read(facturaApiProvider).listExpenses();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
        _loading = false;
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// Открывает форму расхода и перечитывает список после сохранения.
  ///
  /// [existing] — `null` для нового расхода; иначе форма правит переданный.
  Future<void> _openForm(ExpenseView? existing) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => ExpenseFormScreen(existing),
    ));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Расходы'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_openForm(null)),
        icon: const Icon(Icons.add),
        label: const Text('Расход'),
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  /// Тело экрана: спиннер, ошибка, пустой список или список по месяцам.
  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          Center(child: Text(_error!, textAlign: TextAlign.center)),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _load, child: const Text('Повторить'))),
        ],
      );
    }
    if (_rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Расходов пока нет')),
          SizedBox(height: 8),
          Center(
            child: Text(
              'Сфотографируйте счёт — поля заполнятся сами',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      );
    }

    // Группировка по месяцам: расходы сводят по периодам, и так видны суммы за месяц.
    final groups = <String, List<ExpenseView>>{};
    for (final row in _rows) {
      final d = row.issueDate ?? DateTime.now();
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(row);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final key = keys[index];
        final items = groups[key]!;
        final sum = items.fold<double>(0, (acc, r) => acc + r.totalAmount);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Row(
                children: [
                  Expanded(child: Text(monthLabel(key), style: Theme.of(context).textTheme.titleSmall)),
                  Text('${items.length} · ${sum.toStringAsFixed(2)} €',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            for (final row in items)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  onTap: () => unawaited(_openForm(row)),
                  leading: Icon(
                    row.hasDocument ? Icons.attach_file : Icons.receipt_outlined,
                    size: 20,
                  ),
                  title: Text(row.supplierName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${row.issueDate == null ? '' : fullDate(row.issueDate!)}'
                    '${row.description == null || row.description!.isEmpty ? '' : ' · ${row.description}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${row.totalAmount.toStringAsFixed(2)} ${row.currency}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (row.reverseCharge)
                        Text('reverse charge', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
