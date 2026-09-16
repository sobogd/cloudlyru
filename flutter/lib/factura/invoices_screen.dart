import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/format.dart';
import 'declarations_screen.dart';
import 'expenses_screen.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';
import 'invoice_detail_screen.dart';
import 'invoice_form_screen.dart';

/// Экран «Фактуры»: список по месяцам, свежие сверху.
///
/// Кэша нет намеренно — как и в «Файлах»: фактуру можно выставить с другого устройства или
/// из веб-дашборда, а сервер о чужих изменениях не рассказывает. Поэтому список перечитывается
/// при входе на экран, при возвращении из карточки и жестом «потянуть вниз».
class InvoicesScreen extends ConsumerStatefulWidget {
  const InvoicesScreen({super.key});

  @override
  ConsumerState<InvoicesScreen> createState() => _InvoicesScreenState();
}

/// Состояние списка фактур: загруженные строки, общее число и текст последней неудачи.
class _InvoicesScreenState extends ConsumerState<InvoicesScreen> {
  /// Строки фактур в том порядке, в котором их отдал сервер (свежие сверху).
  List<InvoiceSummary> _rows = const [];

  /// Сколько фактур есть всего у компании — по нему видно, что список обрезан лимитом.
  int _total = 0;

  /// Идёт первая загрузка: показываем спиннер вместо «фактур нет». Без этого пустой список
  /// на секунду выглядел бы как отсутствие фактур.
  bool _loading = true;

  /// Текст последней неудачи; список при этом не сбрасывается.
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает список фактур с сервера.
  ///
  /// Побочные эффекты: заполняет [_rows]/[_total] или [_error] и перерисовывает экран.
  Future<void> _load() async {
    final api = ref.read(facturaApiProvider);
    try {
      final res = await api.listInvoices();
      if (!mounted) return;
      setState(() {
        _rows = res.rows;
        _total = res.total;
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

  /// Открывает карточку фактуры и перечитывает список после возвращения: в карточке фактуру
  /// можно отправить в AEAT (номер и статус меняются) или удалить.
  Future<void> _open(InvoiceSummary row) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => InvoiceDetailScreen(invoiceId: row.id),
    ));
    await _load();
  }

  /// Открывает меню разделов фактур.
  ///
  /// Раздел — не одна вкладка, а несколько экранов (фактуры, расходы, декларации, справочники).
  /// Нижняя панель приложения этого не показывает, поэтому вход в остальные экраны живёт здесь:
  /// список остаётся главным экраном раздела, а не меню из иконок.
  Future<void> _openSectionMenu() async {
    final target = await showModalBottomSheet<Widget>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.receipt_long),
              title: Text('Фактуры'),
              subtitle: Text('Текущий экран'),
              enabled: false,
            ),
            ListTile(
              leading: const Icon(Icons.receipt_outlined),
              title: const Text('Расходы'),
              subtitle: const Text('Полученные счета: скан, распознавание, вычет НДС'),
              onTap: () => Navigator.pop(ctx, const ExpensesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.calculate_outlined),
              title: const Text('Декларации'),
              subtitle: const Text('Расчёт 303 / 130 / 349 за квартал'),
              onTap: () => Navigator.pop(ctx, const DeclarationsScreen()),
            ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target));
    // После возвращения список перечитываем: декларации считаются по фактурам, и за время
    // просмотра фактуру могли отправить или поправить в другом месте.
    await _load();
  }

  /// Открывает форму новой фактуры и перечитывает список, если черновик создан.
  Future<void> _create() async {
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => const InvoiceFormScreen(null),
    ));
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Фактуры'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
          IconButton(
            onPressed: _openSectionMenu,
            icon: const Icon(Icons.grid_view),
            tooltip: 'Разделы фактур',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_create()),
        icon: const Icon(Icons.add),
        label: const Text('Фактура'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(context),
      ),
    );
  }

  /// Тело экрана: спиннер первой загрузки, ошибка, пустой список или список по месяцам.
  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final error = _error;
    if (error != null && _rows.isEmpty) {
      // Ошибку показываем в прокручиваемом списке: иначе жест «потянуть вниз» не сработал бы
      // на непрокручиваемом виджете, и обновить список после сбоя было бы нечем.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(error, textAlign: TextAlign.center),
            ),
          ),
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
          Center(child: Text('Фактур пока нет')),
          SizedBox(height: 8),
          Center(
            child: Text(
              'Первая фактура появится здесь сразу после создания',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      );
    }

    // Группировка по месяцам: так список читается как тетрадь — по датам выставления.
    // Ключ группы берём из даты, подпись — из общего форматтера приложения.
    final groups = <String, List<InvoiceSummary>>{};
    for (final row in _rows) {
      final d = row.issueDate ?? DateTime.now();
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(row);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      itemCount: keys.length + (_total > _rows.length ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == keys.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                'Показаны последние ${_rows.length} из $_total',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          );
        }
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
                  Expanded(
                    child: Text(
                      monthLabel(key),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${items.length} · ${sum.toStringAsFixed(2)} €',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            for (final row in items) _InvoiceRow(row: row, onTap: () => unawaited(_open(row))),
          ],
        );
      },
    );
  }
}

/// Строка списка: номер или пометка «черновик», контрагент, дата и сумма.
class _InvoiceRow extends StatelessWidget {
  const _InvoiceRow({required this.row, required this.onTap});

  /// Фактура, которую показывает строка.
  final InvoiceSummary row;

  /// Открытие карточки; вызывается по нажатию.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Черновик подписываем словом, а не пустотой: номер ему выдадут только при отправке в AEAT.
    final title = row.number ?? 'Черновик';
    final date = row.issueDate == null ? '' : fullDate(row.issueDate!);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${row.contactName ?? '—'}${date.isEmpty ? '' : ' · $date'}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${row.totalAmount.toStringAsFixed(2)} ${row.currency}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (row.status != 'SENT')
              Text('черновик', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
