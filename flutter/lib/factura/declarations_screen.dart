import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/widgets.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран «Декларации»: что подавать за квартал и с какими числами.
///
/// Это помощник, а не канал подачи: движок считает цифры по фактурам и расходам квартала и
/// говорит, какие формы нужны (303 — НДС, 130 — авансовый IRPF для autónomo в прямой оценке,
/// 349 — операции внутри ЕС) и что в них вписать. Значения человек переносит в форму AEAT
/// руками, поэтому у каждой касильи есть копирование по нажатию.
///
/// Квартал выбирается стрелками: по умолчанию открывается текущий, но заглянуть в прошлый
/// (например, чтобы подать забытое) — обычное дело, поэтому переключение бесплатное.
class DeclarationsScreen extends ConsumerStatefulWidget {
  const DeclarationsScreen({super.key});

  @override
  ConsumerState<DeclarationsScreen> createState() => _DeclarationsScreenState();
}

/// Состояние экрана: выбранный квартал, полученный расчёт и текст последней неудачи.
class _DeclarationsScreenState extends ConsumerState<DeclarationsScreen> {
  /// Год выбранного периода.
  late int _year;

  /// Квартал выбранного периода (1–4).
  late int _quarter;

  /// Расчёт сервера; `null` — ещё грузится.
  DeclarationQuarter? _data;

  /// Текст последней неудачи.
  String? _error;

  /// Идёт загрузка.
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Текущий квартал по календарю: смотреть по умолчанию хочется именно его.
    final now = DateTime.now();
    _year = now.year;
    _quarter = ((now.month - 1) ~/ 3) + 1;
    unawaited(_load());
  }

  /// Читает расчёт за выбранный квартал.
  ///
  /// Побочные эффекты: обновляет [_data] или [_error] и перерисовывает экран.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(facturaApiProvider)
          .getDeclarations(year: _year, quarter: _quarter);
      if (!mounted) return;
      setState(() {
        _data = data;
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

  /// Сдвигает период на один квартал в прошлое или в будущее.
  void _shift(int delta) {
    var q = _quarter + delta;
    var y = _year;
    if (q < 1) {
      q = 4;
      y -= 1;
    } else if (q > 4) {
      q = 1;
      y += 1;
    }
    setState(() {
      _quarter = q;
      _year = y;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Декларации'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: Column(
        children: [
          _periodBar(context),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : data == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error ?? 'Нет данных', textAlign: TextAlign.center),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + navBarInset(context)),
                          children: [
                            _summaryCard(context, data),
                            const SizedBox(height: 12),
                            if (data.issues.isNotEmpty) ...[
                              _issuesBlock(context, data.issues),
                              const SizedBox(height: 12),
                            ],
                            for (final model in data.models) ...[
                              _modelCard(context, model),
                              const SizedBox(height: 12),
                            ],
                            Text(
                              'Это расчёт-подсказка: цифры переносятся в форму AEAT вручную. '
                              'После подачи отметьте её в «Поданных», чтобы не подать дважды.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// Полоса выбора периода: стрелки и подпись квартала.
  Widget _periodBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _shift(-1),
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Предыдущий квартал',
          ),
          Expanded(
            child: Center(
              child: Text(
                'Q$_quarter $_year',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            onPressed: () => _shift(1),
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Следующий квартал',
          ),
        ],
      ),
    );
  }

  /// Сводка по периоду: сколько фактур и расходов попало, срок подачи, профиль деятельности.
  Widget _summaryCard(BuildContext context, DeclarationQuarter d) {
    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            line('Фактур в квартале', '${d.invoices}'),
            line('Расходов в квартале', '${d.expenses}'),
            if (d.deadline != null) line('Срок подачи', _ruDate(d.deadline!)),
            line(
              'Деятельность',
              d.estimacionDirecta ? '${d.activityType} · прямая оценка' : d.activityType,
            ),
          ],
        ),
      ),
    );
  }

  /// Замечания движка: то, что стоит проверить до подачи.
  Widget _issuesBlock(BuildContext context, List<DeclarationIssue> issues) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final issue in issues)
          Card(
            color: issue.isError ? theme.colorScheme.errorContainer : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    issue.messageEs,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  if (issue.messageEn.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(issue.messageEn, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Карточка одной формы: нужна ли она, её итоги, касильи и операции (для 349).
  Widget _modelCard(BuildContext context, DeclarationModel m) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Modelo ${m.model}', style: theme.textTheme.titleMedium),
                ),
                Chip(
                  label: Text(m.required ? 'нужна' : 'не нужна'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(m.reason, style: theme.textTheme.bodySmall),
            if (m.required && m.deadline != null) ...[
              const SizedBox(height: 4),
              Text('Срок: ${_ruDate(m.deadline!)}', style: theme.textTheme.bodySmall),
            ],
            if (m.amounts.isNotEmpty) ...[
              const Divider(height: 20),
              for (final a in m.amounts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(a.label)),
                      SelectableText(
                        _money(a.value),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ],
            if (m.operations.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Операции', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final op in m.operations)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(op.name),
                            Text(
                              '${op.country} · ${op.taxId} · clave ${op.clave}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Text(_money(op.base)),
                    ],
                  ),
                ),
            ],
            if (m.boxes.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Клетки формы', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final box in m.boxes)
                InkWell(
                  // Копирование по нажатию: числа переносят в форму AEAT руками, и набирать
                  // их с телефона заново — верный способ ошибиться в цифре.
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: box.value.toStringAsFixed(2)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Клетка ${box.code}: ${box.value.toStringAsFixed(2)} скопирована'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 34,
                          child: Text(
                            box.code,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: box.value == 0 ? theme.disabledColor : null,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                box.labelEs,
                                style: TextStyle(color: box.value == 0 ? theme.disabledColor : null),
                              ),
                              if (box.labelEn.isNotEmpty && box.labelEn != box.labelEs)
                                Text(box.labelEn, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Text(
                          _money(box.value),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: box.value == 0 ? theme.disabledColor : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Денежная строка: два знака после запятой и знак евро — так же, как в форме AEAT.
  String _money(double v) => '${v.toStringAsFixed(2)} €';

  /// Дата из ISO-строки в привычном виде `ДД.ММ.ГГГГ`; непонятную строку возвращает как есть.
  String _ruDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.${d.year}';
  }
}
