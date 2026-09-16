import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/format.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран настроек фактур: реквизиты компании-эмитента и сертификат для AEAT.
///
/// Реквизиты попадают в PDF новых фактур и в записи AEAT, поэтому правка влияет только на
/// будущее: у уже выставленных фактур реквизиты зафиксированы снимком (`emitterSnapshot`),
/// и задним числом PDF не меняется — это требование испанского учёта, а не удобство.
///
/// Сертификат — отдельный блок с отдельным действием: без него отправка в AEAT не работает,
/// а сам файл .p12 остаётся на сервере зашифрованным, наружу отдаются только метаданные.
class FacturaSettingsScreen extends ConsumerStatefulWidget {
  const FacturaSettingsScreen({super.key});

  @override
  ConsumerState<FacturaSettingsScreen> createState() => _FacturaSettingsScreenState();
}

/// Состояние настроек: профиль компании, поля формы и занятость операций.
class _FacturaSettingsScreenState extends ConsumerState<FacturaSettingsScreen> {
  /// Загруженный профиль; `null` — ещё грузится.
  CompanyProfile? _company;

  final _name = TextEditingController();
  final _legalName = TextEditingController();
  final _taxId = TextEditingController();
  final _vatId = TextEditingController();
  final _addressLine1 = TextEditingController();
  final _addressLine2 = TextEditingController();
  final _city = TextEditingController();
  final _postalCode = TextEditingController();
  final _region = TextEditingController();
  final _country = TextEditingController();
  final _bankName = TextEditingController();
  final _iban = TextEditingController();
  final _swift = TextEditingController();
  final _irpfRate = TextEditingController();
  final _numberOffset = TextEditingController();

  /// Тип деятельности: от него зависит ставка IRPF и необходимость формы 130.
  String _activityType = 'profesional';

  /// Дата начала деятельности (для льготных 7% первые три года).
  DateTime? _activityStartDate;

  /// Валюта по умолчанию.
  String _baseCurrency = 'EUR';

  bool _busy = true;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _legalName,
      _taxId,
      _vatId,
      _addressLine1,
      _addressLine2,
      _city,
      _postalCode,
      _region,
      _country,
      _bankName,
      _iban,
      _swift,
      _irpfRate,
      _numberOffset,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Читает профиль компании и заполняет форму.
  ///
  /// Побочные эффекты: заполняет контроллеры и [_company].
  Future<void> _load() async {
    try {
      final c = await ref.read(facturaApiProvider).getCompany();
      if (!mounted) return;
      setState(() {
        _company = c;
        _name.text = c.name;
        _legalName.text = c.legalName ?? '';
        _taxId.text = c.taxId ?? '';
        _vatId.text = c.vatId ?? '';
        _addressLine1.text = c.addressLine1 ?? '';
        _addressLine2.text = c.addressLine2 ?? '';
        _city.text = c.city ?? '';
        _postalCode.text = c.postalCode ?? '';
        _region.text = c.region ?? '';
        _country.text = c.country ?? 'ES';
        _bankName.text = c.bankName ?? '';
        _iban.text = c.iban ?? '';
        _swift.text = c.swift ?? '';
        _irpfRate.text = c.defaultIrpfRate?.toStringAsFixed(2) ?? '';
        _numberOffset.text = c.invoiceNumberOffset == 0 ? '' : '${c.invoiceNumberOffset}';
        _activityType = c.activityType ?? 'profesional';
        _activityStartDate = c.activityStartDate;
        _baseCurrency = c.baseCurrency ?? 'EUR';
        _busy = false;
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Сохраняет реквизиты компании.
  ///
  /// Побочные эффекты: правит профиль на сервере, показывает подтверждение.
  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Название компании не может быть пустым');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'legalName': _legalName.text.trim(),
        'taxId': _taxId.text.trim(),
        'vatId': _vatId.text.trim(),
        'addressLine1': _addressLine1.text.trim(),
        'addressLine2': _addressLine2.text.trim(),
        'city': _city.text.trim(),
        'postalCode': _postalCode.text.trim(),
        'region': _region.text.trim(),
        'country': _country.text.trim().toUpperCase(),
        'bankName': _bankName.text.trim(),
        'iban': _iban.text.trim(),
        'swift': _swift.text.trim(),
        'activityType': _activityType,
        'baseCurrency': _baseCurrency,
        if (_irpfRate.text.trim().isNotEmpty)
          'defaultIrpfRate': double.tryParse(_irpfRate.text.replaceAll(',', '.')) ?? 0,
        if (_numberOffset.text.trim().isNotEmpty)
          'invoiceNumberOffset': int.tryParse(_numberOffset.text.trim()) ?? 0,
        if (_activityStartDate != null)
          'activityStartDate': '${_activityStartDate!.year.toString().padLeft(4, '0')}-'
              '${_activityStartDate!.month.toString().padLeft(2, '0')}-'
              '${_activityStartDate!.day.toString().padLeft(2, '0')}',
      };
      final updated = await ref.read(facturaApiProvider).updateCompany(body);
      if (!mounted) return;
      setState(() {
        _company = updated;
        _busy = false;
        _notice = 'Сохранено. Новые фактуры выйдут с этими реквизитами.';
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Загружает сертификат .p12 с паролем.
  ///
  /// Пароль спрашиваем диалогом и нигде не сохраняем: сервер использует его один раз, чтобы
  /// разобрать файл, и хранит только зашифрованный сертификат.
  Future<void> _uploadCert() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['p12', 'pfx'],
    );
    if (files.isEmpty) return;
    final file = files.first;
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Пароль сертификата'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Пароль от .p12'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Загрузить')),
        ],
      ),
    );
    final password = controller.text;
    controller.dispose();
    if (ok != true || password.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final updated = await ref.read(facturaApiProvider).uploadCert(
            p12Base64: base64Encode(bytes),
            password: password,
          );
      if (!mounted) return;
      setState(() {
        _company = updated;
        _busy = false;
        _notice = 'Сертификат загружен: ${updated.certNif ?? ''}';
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Сервер отвечает понятной причиной (не тот пароль, NIF не совпадает с компанией),
        // поэтому текст показываем как есть — он и есть инструкция, что исправить.
        _error = e.message;
      });
    }
  }

  /// Удаляет сертификат.
  Future<void> _deleteCert() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сертификат?'),
        content: const Text('Отправка фактур в AEAT перестанет работать, пока не загрузите новый.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(facturaApiProvider).deleteCert();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      setState(() => _notice = 'Сертификат удалён');
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
    if (_busy && _company == null && _error == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки фактур'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => unawaited(_save()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
          ],
          if (_notice != null) ...[
            Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
          ],
          _certBlock(context),
          const SizedBox(height: 24),
          Text('Реквизиты эмитента', style: Theme.of(context).textTheme.titleSmall),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Название (внутреннее)')),
          TextField(controller: _legalName, decoration: const InputDecoration(labelText: 'Юридическое имя (в PDF)')),
          Row(
            children: [
              Expanded(child: TextField(controller: _taxId, decoration: const InputDecoration(labelText: 'NIF / CIF'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _vatId, decoration: const InputDecoration(labelText: 'VAT (если другой)'))),
            ],
          ),
          TextField(controller: _addressLine1, decoration: const InputDecoration(labelText: 'Адрес')),
          TextField(controller: _addressLine2, decoration: const InputDecoration(labelText: 'Адрес, строка 2')),
          Row(
            children: [
              Expanded(child: TextField(controller: _postalCode, decoration: const InputDecoration(labelText: 'Индекс'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _city, decoration: const InputDecoration(labelText: 'Город'))),
            ],
          ),
          Row(
            children: [
              Expanded(child: TextField(controller: _region, decoration: const InputDecoration(labelText: 'Регион'))),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _country,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Страна'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Банк по умолчанию', style: Theme.of(context).textTheme.titleSmall),
          TextField(controller: _bankName, decoration: const InputDecoration(labelText: 'Банк')),
          TextField(controller: _iban, decoration: const InputDecoration(labelText: 'IBAN')),
          TextField(controller: _swift, decoration: const InputDecoration(labelText: 'SWIFT / BIC')),
          const SizedBox(height: 20),
          Text('Налоговый профиль', style: Theme.of(context).textTheme.titleSmall),
          DropdownButtonFormField<String>(
            initialValue: _activityType,
            decoration: const InputDecoration(labelText: 'Тип деятельности'),
            items: const [
              DropdownMenuItem(value: 'profesional', child: Text('Профессиональная (7% IRPF первые 3 года)')),
              DropdownMenuItem(value: 'empresarial', child: Text('Предпринимательская (0%)')),
              DropdownMenuItem(value: 'modulos_empresarial', child: Text('Модули, предпринимательская (1%)')),
              DropdownMenuItem(value: 'modulos_agricola', child: Text('Модули, сельхоз (2%)')),
              DropdownMenuItem(value: 'alquiler', child: Text('Аренда (15%)')),
            ],
            onChanged: (v) => setState(() => _activityType = v ?? 'profesional'),
          ),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _activityStartDate ?? DateTime(2024),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _activityStartDate = picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Начало деятельности'),
              child: Text(
                _activityStartDate == null
                    ? 'не указано'
                    : '${_activityStartDate!.day.toString().padLeft(2, '0')}.'
                        '${_activityStartDate!.month.toString().padLeft(2, '0')}.${_activityStartDate!.year}',
              ),
            ),
          ),
          TextField(
            controller: _irpfRate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Своя ставка IRPF, %',
              helperText: 'Пусто — считается по типу деятельности и годам',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _baseCurrency,
                  decoration: const InputDecoration(labelText: 'Валюта по умолчанию'),
                  items: const [
                    DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                    DropdownMenuItem(value: 'USD', child: Text('USD')),
                    DropdownMenuItem(value: 'GBP', child: Text('GBP')),
                  ],
                  onChanged: (v) => setState(() => _baseCurrency = v ?? 'EUR'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _numberOffset,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Сдвиг нумерации',
                    helperText: 'Если до этого выставляли вручную',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_save()),
            child: Text(_busy ? 'Сохранение…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }

  /// Блок сертификата: статус, загрузка и удаление.
  Widget _certBlock(BuildContext context) {
    final c = _company;
    final has = c?.hasCert == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(has ? Icons.verified_user : Icons.gpp_maybe,
                    color: has ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    has ? 'Сертификат AEAT загружен' : 'Сертификата AEAT нет',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (has) ...[
              Text('NIF: ${c!.certNif}'),
              if (c.certExpiry != null) Text('Действует до: ${fullDate(c.certExpiry!)}'),
              Text(
                'Файл хранится на сервере зашифрованным; пароль не сохраняется.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else
              const Text('Без сертификата отправка фактур в AEAT работать не будет.'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_uploadCert()),
                  icon: const Icon(Icons.upload),
                  label: Text(has ? 'Заменить .p12' : 'Загрузить .p12'),
                ),
                if (has)
                  TextButton.icon(
                    onPressed: _busy ? null : () => unawaited(_deleteCert()),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
