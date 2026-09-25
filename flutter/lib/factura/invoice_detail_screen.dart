import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../util/download.dart';
import '../util/format.dart';
import '../util/widgets.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'invoice_form_screen.dart';
import 'factura_providers.dart';

/// Карточка фактуры: реквизиты, строки, итоги, цепочка VeriFactu и действия.
///
/// Экран намеренно не кэширует фактуру между открытиями: отправка в AEAT и ручное разрешение
/// зависшей записи меняют и номер, и статус, и PDF, поэтому после каждого действия карточка
/// перечитывается целиком.
class InvoiceDetailScreen extends ConsumerStatefulWidget {
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  /// Идентификатор фактуры, которую показывает экран.
  final String invoiceId;

  @override
  ConsumerState<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

/// Состояние карточки: сама фактура, её лента событий, занятость и последний текст ошибки.
class _InvoiceDetailScreenState extends ConsumerState<InvoiceDetailScreen> {
  /// Загруженная фактура; `null` — ещё грузится или не нашлась.
  InvoiceDetail? _invoice;

  /// Лента событий (свежие внизу — как их пишет сервер).
  List<InvoiceEventView> _events = const [];

  /// Текст последней неудачи: показывается под заголовком.
  String? _error;

  /// Идёт действие, меняющее данные (отправка в AEAT, удаление, дублирование). Пока оно
  /// в полёте, кнопки выключены: повторная отправка в налоговую — это не то, что стоит
  /// делать дважды по одному нажатию.
  bool _busy = false;

  /// Изменялась ли фактура за время открытия экрана. По этому признаку список обновляется
  /// после возвращения.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает фактуру и её события.
  ///
  /// Побочные эффекты: обновляет [_invoice]/[_events] или [_error].
  Future<void> _load() async {
    final api = ref.read(facturaApiProvider);
    try {
      final inv = await api.getInvoice(widget.invoiceId);
      final events = await api.getEvents(widget.invoiceId);
      if (!mounted) return;
      setState(() {
        _invoice = inv;
        _events = events;
        _error = null;
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// Скачивает PDF фактуры и открывает его системным просмотрщиком.
  ///
  /// PDF отдаёт сервер: ручка отвечает редиректом на временную ссылку S3, поэтому качаем
  /// её вместе с Cookie сессии — этим и занимается общий помощник [downloadAndOpen].
  Future<void> _openPdf() async {
    final inv = _invoice;
    if (inv == null) return;
    final name = '${inv.number ?? 'invoice'}.pdf';
    final err = await downloadAndOpen(
      ref.read(appStateProvider).api,
      'factura:${inv.id}',
      name,
      url: ref.read(facturaApiProvider).pdfUrl(inv.id),
    );
    if (err != null && mounted) {
      setState(() => _error = err);
    }
  }

  /// Отправляет фактуру в AEAT и показывает исход человеку.
  ///
  /// Спрашивает подтверждение: номер выдаётся здесь и навсегда, отменить это можно только
  /// через кабинет налоговой. Успех обновляет карточку (появляются номер, QR и статус),
  /// отказ показывает ответ AEAT целиком — его пересылают в поддержку, если запись не проходит.
  Future<void> _submit() async {
    final inv = _invoice;
    if (inv == null || _busy) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отправить в AEAT?'),
        content: Text(
          'Фактура на ${inv.totalAmount.toStringAsFixed(2)} ${inv.currency} '
          'уйдёт в налоговую и получит номер из серии. Изменить её после этого будет нельзя.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отправить')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final res = await ref.read(facturaApiProvider).submit(inv.id);
      if (!mounted) return;
      _changed = true;
      setState(() {});
      await _load();
      if (!mounted) return;
      if (res.ok) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Запись принята'),
            content: Text(
              'Номер: ${res.invoice?.number ?? inv.number ?? '—'}\n'
              '${res.csv == null ? '' : 'CSV: ${res.csv}'}',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
            ],
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(res.kind == 'pending' ? 'Ответ не получен' : 'AEAT отказал'),
            content: SingleChildScrollView(
              child: Text(
                '${res.message ?? 'Налоговая не приняла запись'}\n\n'
                '${res.rawResponse ?? ''}',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
            ],
          ),
        );
      }
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Разрешает зависшую запись: человек проверил кабинет AEAT и выбрал исход.
  Future<void> _resolvePending({required bool accepted}) async {
    final inv = _invoice;
    if (inv == null || _busy) return;

    // CSV из кабинета нужен только при подтверждении, и он необязателен: без него запись
    // всё равно помечается принятой, просто подтверждение останется без номера.
    final controller = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(accepted ? 'Запись есть в AEAT?' : 'AEAT не получил запись?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              accepted
                  ? 'Проверьте кабинет налоговой. Если запись там есть — вставьте CSV '
                      'из кабинета, чтобы он сохранился в истории фактуры.'
                  : 'Запись будет удалена из цепочки, номер освободится, а фактура снова '
                      'станет черновиком — её можно будет отправить заново.',
            ),
            if (accepted) ...[
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: 'CSV (необязательно)'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(accepted ? 'Подтвердить' : 'Освободить номер'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (go != true) return;

    setState(() => _busy = true);
    try {
      final api = ref.read(facturaApiProvider);
      if (accepted) {
        await api.confirmPending(inv.id);
      } else {
        await api.cancelPending(inv.id);
      }
      _changed = true;
      await _load();
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Создаёт копию фактуры черновиком (дата — сегодня, номер ещё не выдан).
  Future<void> _duplicate() async {
    final inv = _invoice;
    if (inv == null || _busy) return;
    setState(() => _busy = true);
    try {
      final copy = await ref.read(facturaApiProvider).duplicateInvoice(inv.id);
      _changed = true;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => InvoiceDetailScreen(invoiceId: copy.id),
      ));
      await _load();
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Открывает форму правки черновика.
  Future<void> _edit() async {
    final inv = _invoice;
    if (inv == null) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => InvoiceFormScreen(inv.id),
    ));
    if (saved == true) {
      _changed = true;
      await _load();
    }
  }

  /// Удаляет фактуру вместе с PDF.
  Future<void> _delete() async {
    final inv = _invoice;
    if (inv == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фактуру?'),
        content: const Text('Фактура и её PDF удаляются безвозвратно.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(facturaApiProvider).deleteInvoice(inv.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Аннулирует отправленную фактуру в AEAT (RegistroAnulacion).
  ///
  /// Спрашивает подтверждение: номер и ALTA-запись в реестре сохранятся (этого требует
  /// налоговая — цепь должна остаться целой), но операция выпадет из налоговой базы.
  /// Успех обновляет карточку, отказ показывает ответ AEAT целиком.
  Future<void> _annul() async {
    final inv = _invoice;
    if (inv == null || _busy) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Аннулировать фактуру?'),
        content: Text(
          'Фактура ${inv.number ?? '—'} на ${inv.totalAmount.toStringAsFixed(2)} ${inv.currency} '
          'будет аннулирована в AEAT. Номер и запись в реестре сохранятся, но в налоговую '
          'базу операция не попадёт.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Аннулировать')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final res = await ref.read(facturaApiProvider).annul(inv.id);
      if (!mounted) return;
      _changed = true;
      await _load();
      if (!mounted) return;
      if (res.ok) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Фактура аннулирована'),
            content: Text(
              '${inv.number ?? '—'} аннулирована. Не включайте её в Modelo 303.\n'
              '${res.csv == null ? '' : 'CSV: ${res.csv}'}',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
            ],
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Не удалось аннулировать'),
            content: SingleChildScrollView(
              child: Text(
                '${res.message ?? 'Налоговая не приняла аннулирование'}\n\n'
                '${res.rawResponse ?? ''}',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
            ],
          ),
        );
      }
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = _invoice;
    // Возвращая признак изменения, список обновится сразу — ждать повторного входа не нужно.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(inv?.number ?? 'Фактура'),
          actions: [
            if (inv != null)
              PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (v) {
                  switch (v) {
                    case 'pdf':
                      unawaited(_openPdf());
                    case 'edit':
                      unawaited(_edit());
                    case 'duplicate':
                      unawaited(_duplicate());
                    case 'delete':
                      unawaited(_delete());
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'pdf', child: Text('Открыть PDF')),
                  if (inv.isDraft) const PopupMenuItem(value: 'edit', child: Text('Изменить')),
                  const PopupMenuItem(value: 'duplicate', child: Text('Сделать копию')),
                  if (inv.isDraft) const PopupMenuItem(value: 'delete', child: Text('Удалить')),
                ],
              ),
          ],
        ),
        body: inv == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
              )
            : ListView(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + navBarInset(context)),
                children: [
                  if (_error != null) ...[
                    _Banner(text: _error!, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 12),
                  ],
                  if (inv.isAnnulled) ...[
                    _Banner(
                      text: 'Фактура аннулирована'
                          '${inv.annulledAt == null ? '' : ' ${fullDate(inv.annulledAt!)}'}.'
                          ' В налоговую базу не включается.',
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (inv.verifactuPending != null)
                    _PendingBanner(
                      pending: inv.verifactuPending!,
                      busy: _busy,
                      onAccepted: () => unawaited(_resolvePending(accepted: true)),
                      onRejected: () => unawaited(_resolvePending(accepted: false)),
                    ),
                  _Header(inv: inv),
                  const SizedBox(height: 16),
                  _Section(title: 'Контрагент', child: _ContactBlock(inv: inv)),
                  const SizedBox(height: 12),
                  _Section(title: 'Строки', child: _LinesBlock(inv: inv)),
                  const SizedBox(height: 12),
                  _Section(title: 'Итоги', child: _TotalsBlock(inv: inv)),
                  if ((inv.notes ?? '').isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _Section(title: 'Примечания', child: Text(inv.notes!)),
                  ],
                  if (inv.verifactuQrUrl != null || inv.verifactuChainTail != null) ...[
                    const SizedBox(height: 12),
                    _Section(
                      title: 'VeriFactu',
                      child: _VerifactuBlock(inv: inv),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (inv.isDraft)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => unawaited(_submit()),
                      icon: const Icon(Icons.send),
                      label: Text(_busy ? 'Отправка…' : 'Отправить в AEAT'),
                    ),
                  if (!inv.isDraft && !inv.isAnnulled) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => unawaited(_annul()),
                      icon: const Icon(Icons.undo),
                      label: Text(_busy ? 'Аннулирование…' : 'Аннулировать в AEAT'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_openPdf()),
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Открыть PDF'),
                  ),
                  const SizedBox(height: 24),
                  _Section(title: 'История', child: _EventsBlock(events: _events)),
                ],
              ),
      ),
    );
  }
}

/// Плашка о зависшей отправке: без неё фактура просто «не отправилась», и непонятно, что делать.
class _PendingBanner extends StatelessWidget {
  const _PendingBanner({
    required this.pending,
    required this.busy,
    required this.onAccepted,
    required this.onRejected,
  });

  final VerifactuPendingView pending;
  final bool busy;
  final VoidCallback onAccepted;
  final VoidCallback onRejected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Отправка записи #${pending.sequenceNumber} не подтверждена',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Сервер не получил ответ налоговой и не знает, записана ли фактура. '
              'Проверьте кабинет AEAT и выберите исход.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : onAccepted,
                  child: const Text('Запись есть в AEAT'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : onRejected,
                  child: const Text('AEAT не получил'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка-предупреждение (ошибка последнего действия).
class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text),
      );
}

/// Заголовок карточки: статус, контрагент, дата и сумма к оплате.
class _Header extends StatelessWidget {
  const _Header({required this.inv});

  final InvoiceDetail inv;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          inv.isAnnulled
              ? 'Аннулирована'
              : (inv.isDraft ? 'Черновик' : 'Отправлена'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: inv.isAnnulled
                ? theme.colorScheme.tertiary
                : (inv.isDraft ? theme.colorScheme.error : theme.colorScheme.primary),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${inv.toPayAmount.toStringAsFixed(2)} ${inv.currency}',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          inv.issueDate == null ? '' : fullDate(inv.issueDate!),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Блок «Контрагент»: имя, NIF и адрес из снимка фактуры.
class _ContactBlock extends StatelessWidget {
  const _ContactBlock({required this.inv});

  final InvoiceDetail inv;

  @override
  Widget build(BuildContext context) {
    final snap = inv.contactSnapshot;
    final address = [
      snap['addressLine1'],
      snap['postalCode'],
      snap['city'],
      snap['countryCode'] ?? snap['country'],
    ].where((e) => e != null && '$e'.isNotEmpty).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(inv.displayContactName, style: const TextStyle(fontWeight: FontWeight.w600)),
        if ((inv.displayContactTaxId ?? '').isNotEmpty) Text('NIF: ${inv.displayContactTaxId}'),
        if (address.isNotEmpty) Text(address),
      ],
    );
  }
}

/// Блок «Строки»: описание и сумма каждой позиции.
class _LinesBlock extends StatelessWidget {
  const _LinesBlock({required this.inv});

  final InvoiceDetail inv;

  @override
  Widget build(BuildContext context) {
    if (inv.lines.isEmpty) {
      return Text(inv.description ?? '—');
    }
    return Column(
      children: [
        for (final line in inv.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text(line.description)),
                Text('${line.total.toStringAsFixed(2)} ${inv.currency}'),
              ],
            ),
          ),
      ],
    );
  }
}

/// Блок «Итоги»: база, НДС, удержание и то, что клиент переводит.
class _TotalsBlock extends StatelessWidget {
  const _TotalsBlock({required this.inv});

  final InvoiceDetail inv;

  @override
  Widget build(BuildContext context) {
    Widget row(String label, double value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                '${value.toStringAsFixed(2)} ${inv.currency}',
                style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400),
              ),
            ],
          ),
        );
    return Column(
      children: [
        row('База (${inv.vatRate.toStringAsFixed(0)}% НДС)', inv.netAmount),
        row('НДС', inv.vatAmount),
        if (inv.irpfRate > 0) row('Удержание IRPF (${inv.irpfRate.toStringAsFixed(0)}%)', -inv.irpfAmount),
        const Divider(height: 16),
        row('Итого', inv.totalAmount),
        row('К оплате', inv.toPayAmount, bold: true),
        if (inv.paid) const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Оплачена', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

/// Блок VeriFactu: хвост хеша записи и ссылка на проверку в AEAT.
///
/// Хеш показываем последними символами: он длинный, а сверить фактуру с кабинетом налоговой
/// можно и по ним — это то же значение, что напечатано на PDF.
class _VerifactuBlock extends StatelessWidget {
  const _VerifactuBlock({required this.inv});

  final InvoiceDetail inv;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inv.verifactuChainTail != null) Text('Хеш записи: …${inv.verifactuChainTail}'),
        if (inv.verifactuQrUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(inv.verifactuQrUrl!),
          ),
        Text(
          'Ссылку можно открыть в браузере: она ведёт на проверку фактуры в AEAT.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Блок «История»: лента событий фактуры, свежие внизу.
class _EventsBlock extends StatelessWidget {
  const _EventsBlock({required this.events});

  final List<InvoiceEventView> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const Text('Событий пока нет');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in events)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.summary),
                Text(
                  '${e.createdAt == null ? '' : fullDate(e.createdAt!)} · ${e.type}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Раздел карточки с заголовком: одинаковое оформление у всех блоков.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          child,
        ],
      );
}
