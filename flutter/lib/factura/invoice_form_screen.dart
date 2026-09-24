import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/widgets.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Форма фактуры: создание черновика и правка существующего.
///
/// Номер здесь не выдаётся: он появляется только при отправке в AEAT, чтобы серия отправленных
/// фактур не имела пропусков (испанское требование). Поэтому форма создаёт и правит именно
/// черновик, а отправка — отдельное действие в карточке.
///
/// Суммы форма считает сама — ровно для показа: сервер пересчитывает их по тем же правилам
/// при сохранении (и именно его расчёт попадает в PDF и в запись AEAT).
class InvoiceFormScreen extends ConsumerStatefulWidget {
  const InvoiceFormScreen(this.invoiceId, {super.key});

  /// Идентификатор правимого черновика; `null` — создаём новый.
  final String? invoiceId;

  @override
  ConsumerState<InvoiceFormScreen> createState() => _InvoiceFormScreenState();
}

/// Одна строка фактуры в форме: описание и сумма.
class _LineDraft {
  _LineDraft({String description = '', double? amount})
      : description = TextEditingController(text: description),
        amount = TextEditingController(text: amount == null ? '' : amount.toStringAsFixed(2));

  /// Описание услуги (в PDF это строка «1. описание»).
  final TextEditingController description;

  /// Сумма строки без НДС.
  final TextEditingController amount;

  /// Освобождает контроллеры: форма создаёт их на каждую строку и удаляет вместе с ней.
  void dispose() {
    description.dispose();
    amount.dispose();
  }
}

/// Состояние формы: справочники, выбранные значения и занятость сохранения.
class _InvoiceFormScreenState extends ConsumerState<InvoiceFormScreen> {
  /// Контрагенты из справочника — для выбора получателя фактуры.
  List<ContactView> _contacts = const [];

  /// Банковские счета компании — выбор счёта для печати «DATOS DE PAGO».
  List<BankAccountView> _accounts = const [];

  /// Строки фактуры; минимум одна — пустая фактура смысла не имеет.
  final List<_LineDraft> _lines = [_LineDraft()];

  /// Выбранный контрагент (`null` — ещё не выбран).
  String? _contactId;

  /// Снимок разового контрагента — им правят черновик, у которого контрагента нет в справочнике.
  Map<String, dynamic>? _inlineContact;

  /// Ставка НДС: 21 для испанского бизнеса, 0 для клиентов вне Испании.
  int _vatRate = 21;

  /// Ставка IRPF: `null` — «как решит сервер по профилю компании».
  int? _irpfRate = 7;

  /// Галочка «введённая сумма — то, что заплатил клиент»: тогда база, НДС и IRPF
  /// считаются от неё обратно, а не наоборот.
  bool _clientPays = false;

  /// Валюта фактуры.
  String _currency = 'EUR';

  /// Дата выставления (по умолчанию — сегодня).
  DateTime _issueDate = DateTime.now();

  /// Примечание, которое печатается в PDF.
  final TextEditingController _notes = TextEditingController();

  /// Выбранный банковский счёт.
  String? _bankAccountId;

  /// Идёт загрузка справочников или сохранение.
  bool _busy = true;

  /// Текст последней ошибки (загрузки или сохранения).
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  /// Загружает справочники и, если правим черновик, его содержимое.
  ///
  /// Побочные эффекты: заполняет поля формы; при сбое оставляет текст в [_error].
  Future<void> _bootstrap() async {
    final api = ref.read(facturaApiProvider);
    try {
      final contacts = await api.listContacts();
      final accounts = await api.listBankAccounts();
      final company = await api.getCompany();

      InvoiceDetail? existing;
      final id = widget.invoiceId;
      if (id != null) existing = await api.getInvoice(id);

      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _accounts = accounts;
        _currency = company.baseCurrency ?? 'EUR';
        _bankAccountId = accounts.where((a) => a.isDefault).map((a) => a.id).firstOrNull;

        if (existing != null) {
          _contactId = existing.contactId;
          if (existing.contactId == null) _inlineContact = existing.contactSnapshot;
          _vatRate = existing.vatRate.toInt();
          _irpfRate = existing.irpfRate.toInt();
          _currency = existing.currency;
          _issueDate = existing.issueDate ?? DateTime.now();
          _notes.text = existing.notes ?? '';
          _bankAccountId = existing.bankAccountId ?? _bankAccountId;
          for (final l in _lines) {
            l.dispose();
          }
          _lines
            ..clear()
            ..addAll(existing.lines.isEmpty
                ? [_LineDraft(description: existing.description ?? '')]
                : [
                    for (final l in existing.lines)
                      _LineDraft(description: l.description, amount: l.total),
                  ]);
        }
        _busy = false;
      });
      // Ставка IRPF по профилю компании: 7% в первые три года деятельности, потом 15%.
      // Точное значение всё равно пересчитает сервер — здесь это подсказка человеку.
      if (existing == null) {
        final byProfile = _irpfFromProfile(company);
        if (mounted) setState(() => _irpfRate = byProfile);
      }
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  /// Ставка IRPF по профилю компании — та же логика, что на сервере, но только для подсказки.
  int _irpfFromProfile(CompanyProfile c) {
    final manual = c.defaultIrpfRate;
    if (manual != null) return manual.toInt();
    switch (c.activityType ?? 'profesional') {
      case 'empresarial':
        return 0;
      case 'modulos_empresarial':
        return 1;
      case 'modulos_agricola':
        return 2;
      case 'alquiler':
        return 15;
      default:
        return 7;
    }
  }

  /// Эффективная ставка IRPF: удержание бывает только на испанском НДС.
  int get _effectiveIrpf => _vatRate == 21 ? (_irpfRate ?? 0) : 0;

  /// Режим «введена сумма, которую заплатил клиент».
  ///
  /// Галочка имеет смысл только для Испании и ровно одной строки: сервер умеет
  /// разложить итог лишь по одной позиции, с несколькими он её проигнорирует,
  /// поэтому здесь режим тоже молча выключается.
  bool get _clientPaysActive => _clientPays && _vatRate == 21 && _lines.length == 1;

  /// Сумма, введённая в строках. Обычно это база без НДС, а в режиме
  /// [_clientPaysActive] — итог, который переводит клиент.
  double get _entered => _lines.fold<double>(0, (acc, l) => acc + (double.tryParse(l.amount.text.replaceAll(',', '.')) ?? 0));

  /// База без НДС. В режиме «клиент заплатил» — обратный пересчёт из итога
  /// по той же формуле, что и на сервере: net = paid / (1 + НДС − IRPF).
  double get _net {
    if (!_clientPaysActive) return _entered;
    final denom = 1 + _vatRate / 100 - _effectiveIrpf / 100;
    return denom <= 0 ? _entered : _entered / denom;
  }

  /// Итог с НДС.
  double get _total => _net + _net * _vatRate / 100;

  /// Сколько клиент переводит. В режиме «клиент заплатил» это ровно введённая
  /// сумма — как и на сервере, без дрейфа округления.
  double get _toPay =>
      _clientPaysActive ? _entered : _total - _net * _effectiveIrpf / 100;

  /// Сохраняет черновик на сервере и закрывает форму.
  ///
  /// Побочные эффекты: создаёт или правит фактуру, синхронизирует с сервером её PDF и
  /// возвращает `true` вызывающему экрану — чтобы список перечитался.
  Future<void> _save() async {
    final filled = _lines
        .where((l) => l.description.text.trim().isNotEmpty && (double.tryParse(l.amount.text.replaceAll(',', '.')) ?? 0) > 0)
        .toList();
    if (filled.isEmpty) {
      setState(() => _error = 'Нужна хотя бы одна строка с описанием и суммой');
      return;
    }
    if (_contactId == null && _inlineContact == null) {
      setState(() => _error = 'Выберите контрагента');
      return;
    }
    if (_currency != 'EUR' && _vatRate != 0) {
      // Сервер принимает неевровую фактуру только без НДС: иначе сумму в EUR пришлось бы
      // считать по курсу, которого у нас нет.
      setState(() => _error = 'Для валюты, отличной от EUR, ставка НДС должна быть 0');
      return;
    }

    final payload = InvoicedraftPayload(
      contactId: _contactId,
      contact: _contactId == null ? _inlineContact : null,
      lineItems: [
        for (final l in filled)
          (
            description: l.description.text.trim(),
            amount: double.parse(l.amount.text.replaceAll(',', '.')),
          ),
      ],
      vatRate: _vatRate,
      irpfRate: _vatRate == 21 ? _irpfRate : 0,
      amountIsClientPays: _clientPaysActive,
      currency: _currency,
      issueDate: '${_issueDate.year.toString().padLeft(4, '0')}-'
          '${_issueDate.month.toString().padLeft(2, '0')}-'
          '${_issueDate.day.toString().padLeft(2, '0')}',
      description: filled.first.description.text.trim(),
      notes: _notes.text.trim(),
      bankAccountId: _bankAccountId,
    );

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(facturaApiProvider);
      final id = widget.invoiceId;
      if (id == null) {
        await api.createDraft(payload);
      } else {
        await api.updateDraft(id, payload);
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.invoiceId == null ? 'Новая фактура' : 'Правка черновика'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => unawaited(_save()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: _busy && _contacts.isEmpty && _error == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + navBarInset(context)),
              children: [
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                _recipientBlock(),
                const SizedBox(height: 20),
                Text('Строки', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                for (var i = 0; i < _lines.length; i++) _lineRow(i),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _lines.add(_LineDraft());
                    // Галочка «сумма от клиента» работает только с одной строкой.
                    _clientPays = false;
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить строку'),
                ),
                const SizedBox(height: 20),
                _taxBlock(),
                const SizedBox(height: 20),
                _paymentBlock(),
                const SizedBox(height: 20),
                _totalsPreview(),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_save()),
                  child: Text(_busy ? 'Сохранение…' : 'Сохранить черновик'),
                ),
              ],
            ),
    );
  }

  /// Блок выбора контрагента.
  ///
  /// Если черновик выставлен на разового клиента (его нет в справочнике), показываем его имя
  /// из снимка: такой контрагент сохраняется вместе с фактурой, и терять его при правке нельзя.
  Widget _recipientBlock() {
    final inlineName = _inlineContact == null ? null : '${_inlineContact!['name'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Контрагент', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (inlineName != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(inlineName),
            subtitle: const Text('разовый контрагент (не в справочнике)'),
            trailing: TextButton(
              onPressed: () => setState(() => _inlineContact = null),
              child: const Text('Заменить'),
            ),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: _contactId,
            decoration: const InputDecoration(labelText: 'Клиент'),
            items: [
              for (final c in _contacts)
                DropdownMenuItem(
                  value: c.id,
                  child: Text(c.taxId == null ? c.name : '${c.name} · ${c.taxId}'),
                ),
            ],
            onChanged: (v) => setState(() {
              _contactId = v;
              final c = _contacts.where((e) => e.id == v).firstOrNull;
              // Валюта и ставка НДС следуют за клиентом: у клиента вне Испании НДС не начисляется.
              if (c?.currency != null && c!.currency!.isNotEmpty) _currency = c.currency!;
              final es = (c?.countryCode ?? 'ES').toUpperCase() == 'ES';
              _vatRate = es ? 21 : 0;
              if (!es) _currency = c?.currency?.isNotEmpty == true ? c!.currency! : 'USD';
            }),
          ),
      ],
    );
  }

  /// Строка формы: описание, сумма и кнопка удаления.
  Widget _lineRow(int index) {
    final line = _lines[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: line.description,
              decoration: const InputDecoration(labelText: 'Описание'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: line.amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                // В режиме «сумма от клиента» в поле лежит итог, а не база — подписываем именно его.
                labelText: _clientPaysActive ? 'Клиент заплатит' : 'Сумма',
              ),
              // Пересчитываем итог на каждый символ: иначе человек не видит, что получится.
              onChanged: (_) => setState(() {}),
            ),
          ),
          IconButton(
            onPressed: _lines.length == 1
                ? null
                : () => setState(() {
                      _lines.removeAt(index).dispose();
                    }),
            icon: const Icon(Icons.close),
            tooltip: 'Убрать строку',
          ),
        ],
      ),
    );
  }

  /// Блок налогов: НДС, IRPF, валюта и дата выставления.
  Widget _taxBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Налоги и дата', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _vatRate == 21,
          onChanged: (v) => setState(() {
            _vatRate = v ? 21 : 0;
            if (!v) {
              _irpfRate = 0;
              _clientPays = false;
            }
          }),
          title: const Text('Клиент в Испании (НДС 21%)'),
          subtitle: const Text('Вне Испании — 0%, удержание IRPF не применяется'),
        ),
        if (_vatRate == 21)
          DropdownButtonFormField<int>(
            initialValue: _irpfRate,
            decoration: const InputDecoration(labelText: 'Удержание IRPF, %'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('0%')),
              DropdownMenuItem(value: 7, child: Text('7% (первые три года)')),
              DropdownMenuItem(value: 15, child: Text('15%')),
            ],
            onChanged: (v) => setState(() => _irpfRate = v),
          ),
        // Режим «сумма от клиента» имеет смысл только для Испании и одной строки:
        // с несколькими позициями сервер не знает, как разложить введённый итог по строкам.
        if (_vatRate == 21 && _lines.length == 1)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _clientPays,
            onChanged: (v) => setState(() => _clientPays = v),
            title: const Text('Знаю сумму, которую заплатит клиент'),
            subtitle: const Text(
              'Сумма в строке — итог от клиента; база, НДС и IRPF считаются от неё',
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _currency,
                decoration: const InputDecoration(labelText: 'Валюта'),
                items: const [
                  DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                  DropdownMenuItem(value: 'USD', child: Text('USD')),
                  DropdownMenuItem(value: 'GBP', child: Text('GBP')),
                  DropdownMenuItem(value: 'CHF', child: Text('CHF')),
                ],
                onChanged: (v) => setState(() => _currency = v ?? 'EUR'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _issueDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _issueDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Дата выставления'),
                  child: Text(
                    '${_issueDate.day.toString().padLeft(2, '0')}.'
                    '${_issueDate.month.toString().padLeft(2, '0')}.${_issueDate.year}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Блок оплаты: счёт для печати в PDF и примечание.
  Widget _paymentBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Оплата и примечание', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_accounts.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _bankAccountId,
            decoration: const InputDecoration(labelText: 'Банковский счёт'),
            items: [
              for (final a in _accounts)
                DropdownMenuItem(
                  value: a.id,
                  child: Text(a.iban == null ? a.label : '${a.label} · ${a.iban}'),
                ),
            ],
            onChanged: (v) => setState(() => _bankAccountId = v),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _notes,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Примечание (печатается в PDF)'),
        ),
      ],
    );
  }

  /// Предпросмотр сумм: база, НДС, удержание и то, что переведёт клиент.
  Widget _totalsPreview() {
    final irpf = _vatRate == 21 ? (_irpfRate ?? 0) : 0;
    Widget row(String label, double value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                '${value.toStringAsFixed(2)} $_currency',
                style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400),
              ),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // В режиме «сумма от клиента» порядок обратный: введённый итог фиксирован,
            // а база и налоги — производные от него.
            if (_clientPaysActive) row('Итог от клиента', _entered),
            row('База', _net),
            row('НДС ($_vatRate%)', _net * _vatRate / 100),
            if (irpf > 0) row('Удержание IRPF ($irpf%)', -_net * irpf / 100),
            const Divider(height: 16),
            row('К оплате', _toPay, bold: true),
          ],
        ),
      ),
    );
  }
}
