import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/widgets.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран «Счета»: банковские счета компании, которые печатаются в фактурах.
///
/// Счёт выбирается в форме фактуры и попадает в PDF блоком «DATOS DE PAGO». Один счёт можно
/// пометить основным — его форма подставляет новым фактурам.
class BankAccountsScreen extends ConsumerStatefulWidget {
  const BankAccountsScreen({super.key});

  @override
  ConsumerState<BankAccountsScreen> createState() => _BankAccountsScreenState();
}

/// Состояние списка счетов.
class _BankAccountsScreenState extends ConsumerState<BankAccountsScreen> {
  List<BankAccountView> _rows = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает список счетов.
  ///
  /// Побочные эффекты: обновляет [_rows] или [_error].
  Future<void> _load() async {
    try {
      final rows = await ref.read(facturaApiProvider).listBankAccounts();
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

  /// Открывает форму счёта и перечитывает список после сохранения.
  Future<void> _open(BankAccountView? existing) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => BankAccountFormScreen(existing),
    ));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Основной счёт сверху: остальные — редко используемые.
    final rows = [..._rows]..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Счета'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_open(null)),
        icon: const Icon(Icons.add),
        label: const Text('Счёт'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: rows.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 100),
                        Center(child: Text(_error ?? 'Счетов пока нет')),
                        const SizedBox(height: 8),
                        const Center(
                          child: Text(
                            'Счёт печатается в фактуре блоком «DATOS DE PAGO»',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(12, 12, 12, 88 + navBarInset(context)),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final a = rows[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          child: ListTile(
                            onTap: () => unawaited(_open(a)),
                            leading: Icon(a.isDefault ? Icons.star : Icons.account_balance_outlined, size: 20),
                            title: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              [
                                if ((a.iban ?? '').isNotEmpty) a.iban!,
                                if ((a.bankName ?? '').isNotEmpty) a.bankName!,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: a.currency == null ? null : Text(a.currency!),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// Форма банковского счёта: создание и правка.
class BankAccountFormScreen extends ConsumerStatefulWidget {
  const BankAccountFormScreen(this.existing, {super.key});

  /// Правимый счёт; `null` — создаём новый.
  final BankAccountView? existing;

  @override
  ConsumerState<BankAccountFormScreen> createState() => _BankAccountFormScreenState();
}

/// Состояние формы счёта.
class _BankAccountFormScreenState extends ConsumerState<BankAccountFormScreen> {
  final _label = TextEditingController();
  final _bankName = TextEditingController();
  final _iban = TextEditingController();
  final _swift = TextEditingController();

  /// Валюта счёта.
  String _currency = 'EUR';

  /// Сделать счёт основным.
  bool _isDefault = false;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    if (a != null) {
      _label.text = a.label;
      _bankName.text = a.bankName ?? '';
      _iban.text = a.iban ?? '';
      _swift.text = a.swift ?? '';
      _currency = a.currency ?? 'EUR';
      _isDefault = a.isDefault;
    }
  }

  @override
  void dispose() {
    for (final c in [_label, _bankName, _iban, _swift]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Сохраняет счёт.
  ///
  /// Побочные эффекты: создаёт или правит счёт на сервере, возвращает `true`.
  Future<void> _save() async {
    if (_label.text.trim().isEmpty) {
      setState(() => _error = 'Укажите название счёта');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'label': _label.text.trim(),
        'bankName': _bankName.text.trim(),
        // IBAN сервер нормализует сам (убирает пробелы и приводит к верхнему регистру).
        'iban': _iban.text.trim(),
        'swift': _swift.text.trim(),
        'currency': _currency,
        'isDefault': _isDefault,
      };
      final api = ref.read(facturaApiProvider);
      final existing = widget.existing;
      if (existing == null) {
        await api.createBankAccount(body);
      } else {
        await api.updateBankAccount(existing.id, body);
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

  /// Удаляет счёт.
  ///
  /// Уже выставленные фактуры не страдают: в них счёт зафиксирован снимком эмитента.
  Future<void> _delete() async {
    final a = widget.existing;
    if (a == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить счёт?'),
        content: const Text('В уже выставленных фактурах реквизиты останутся как были.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(facturaApiProvider).deleteBankAccount(a.id);
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
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Новый счёт' : 'Счёт'),
        actions: [
          if (existing != null)
            IconButton(
              onPressed: _busy ? null : () => unawaited(_delete()),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Удалить',
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + navBarInset(context)),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _label,
            decoration: const InputDecoration(labelText: 'Название (как вы его узнаёте)'),
          ),
          TextField(controller: _bankName, decoration: const InputDecoration(labelText: 'Банк')),
          TextField(controller: _iban, decoration: const InputDecoration(labelText: 'IBAN')),
          TextField(
            controller: _swift,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'SWIFT / BIC'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: const InputDecoration(labelText: 'Валюта'),
            items: const [
              DropdownMenuItem(value: 'EUR', child: Text('EUR')),
              DropdownMenuItem(value: 'USD', child: Text('USD')),
              DropdownMenuItem(value: 'GBP', child: Text('GBP')),
            ],
            onChanged: (v) => setState(() => _currency = v ?? 'EUR'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
            title: const Text('Основной счёт'),
            subtitle: const Text('Подставляется новым фактурам'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_save()),
            child: Text(_busy ? 'Сохранение…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }
}
