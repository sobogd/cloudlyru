import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/download.dart';
import '../providers.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Форма расхода: создание и правка, с приложением документа и распознаванием.
///
/// Главный сценарий — «сфотографировал счёт, проверил поля, сохранил»: документ сначала
/// уезжает на сервер (он же хранится в S3 и остаётся приложенным к расходу), сервер прогоняет
/// его через Gemini и возвращает заполненные поля. Распознавание — подсказка, а не истина:
/// человек правит то, что модель прочитала неверно, и только потом сохраняет.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen(this.existing, {super.key});

  /// Правимый расход; `null` — создаём новый.
  final ExpenseView? existing;

  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

/// Состояние формы: все поля расхода, приложенный документ и занятость операций.
class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  final _supplierName = TextEditingController();
  final _supplierTaxId = TextEditingController();
  final _supplierCountry = TextEditingController();
  final _category = TextEditingController();
  final _description = TextEditingController();
  final _notes = TextEditingController();
  final _netAmount = TextEditingController();

  /// Дата документа (по умолчанию — сегодня).
  DateTime _issueDate = DateTime.now();

  /// Валюта документа.
  String _currency = 'EUR';

  /// Ставка НДС: 0, 4, 10 или 21.
  double _vatRate = 21;

  /// Удержание IRPF, обычно 0.
  double _irpfRate = 0;

  /// Доля НДС к вычету, % (у топлива бывает 50).
  double _deductibleVatPct = 100;

  /// Учитывать в базе IRPF.
  bool _deductibleForIrpf = true;

  /// Покупка внутри ЕС: НДС начисляет получатель.
  bool _reverseCharge = false;

  /// `service` | `goods` — влияет на clave в форме 349.
  String _nature = 'service';

  /// `invoice` — обычный счёт, `recurring_no_invoice` — взнос без счёта (RETA).
  String _kind = 'invoice';

  /// Ключ документа в S3 (приложенный скан или PDF).
  String? _fileKey;
  String? _fileMime;
  String? _fileName;

  /// Идёт сохранение или загрузка документа.
  bool _busy = false;

  /// Текст последней ошибки.
  String? _error;

  /// Текст о том, что документ распознан и поля заполнены, — чтобы человек понял, откуда данные.
  String? _scanNotice;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _supplierName.text = e.supplierName;
      _supplierTaxId.text = e.supplierTaxId ?? '';
      _supplierCountry.text = e.supplierCountryCode ?? '';
      _category.text = e.category ?? '';
      _description.text = e.description ?? '';
      _notes.text = e.notes ?? '';
      _netAmount.text = e.netAmount.toStringAsFixed(2);
      _issueDate = e.issueDate ?? DateTime.now();
      _currency = e.currency;
      _vatRate = e.vatRate;
      _irpfRate = e.irpfRate;
      _deductibleVatPct = e.deductibleVatPct;
      _deductibleForIrpf = e.deductibleForIrpf;
      _reverseCharge = e.reverseCharge;
      _nature = e.nature ?? 'service';
      _kind = e.kind ?? 'invoice';
      _fileName = e.fileName;
      // Ключ документа нужен, чтобы правка не отвязала уже загруженный скан.
      _fileKey = e.hasDocument ? 'keep' : null;
      _fileMime = null;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _supplierName,
      _supplierTaxId,
      _supplierCountry,
      _category,
      _description,
      _notes,
      _netAmount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Итог с НДС по введённой базе — только для показа, сервер считает сам.
  double get _total => (double.tryParse(_netAmount.text.replaceAll(',', '.')) ?? 0) * (1 + _vatRate / 100);

  /// Выбирает документ и загружает его на сервер с распознаванием.
  ///
  /// Побочные эффекты: кладёт файл в S3 (через API), заполняет поля распознанными значениями
  /// и запоминает ключ документа для сохранения.
  Future<void> _pickDocument() async {
    setState(() {
      _busy = true;
      _error = null;
      _scanNotice = null;
    });
    try {
      // Содержимое читаем сами (readAsBytes), а не берём путь: на Android файл может прийти
      // из чужого провайдера, и путь к нему приложению недоступен.
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'pdf'],
      );
      if (files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final file = files.first;
      final bytes = await file.readAsBytes();
      final mime = _mimeOf(file.name);
      if (mime == null) {
        setState(() {
          _busy = false;
          _error = 'Подойдёт фото (jpg, png, webp, heic) или PDF';
        });
        return;
      }

      final res = await ref.read(facturaApiProvider).uploadExpenseDoc(
            base64: base64Encode(bytes),
            mimeType: mime,
            fileName: file.name,
            // Распознаём только первый документ нового расхода: при замене файла
            // переспрашивать модель незачем — поля человек уже проверил.
            parse: widget.existing == null,
          );
      if (!mounted) return;
      setState(() {
        _fileKey = res.key;
        _fileMime = res.mime;
        _fileName = res.fileName ?? file.name;
        _busy = false;
        final p = res.parsed;
        if (p != null) {
          _applyParsed(p);
          _scanNotice = 'Поля заполнены по документу — проверьте их перед сохранением';
        }
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Переносит распознанные поля в форму, не затирая то, что человек уже ввёл.
  ///
  /// Пустые значения модели не подставляем: пустая строка от Gemini означает «не разобрал»,
  /// и подменять ею осмысленный ввод нельзя.
  void _applyParsed(ParsedExpenseDraft p) {
    if (p.supplierName.isNotEmpty && _supplierName.text.isEmpty) _supplierName.text = p.supplierName;
    if (p.supplierTaxId.isNotEmpty && _supplierTaxId.text.isEmpty) _supplierTaxId.text = p.supplierTaxId;
    if (p.supplierCountryCode.isNotEmpty && _supplierCountry.text.isEmpty) {
      _supplierCountry.text = p.supplierCountryCode;
    }
    if (p.description.isNotEmpty && _description.text.isEmpty) _description.text = p.description;
    if (p.netAmount > 0 && _netAmount.text.isEmpty) _netAmount.text = p.netAmount.toStringAsFixed(2);
    if (p.currency.isNotEmpty) _currency = p.currency;
    if (p.vatRate > 0) _vatRate = p.vatRate;
    if (p.irpfRate > 0) _irpfRate = p.irpfRate;
    if (p.reverseCharge) _reverseCharge = true;
    _nature = p.nature;
    _kind = p.kind;
    final date = DateTime.tryParse(p.issueDate);
    if (date != null) _issueDate = date;
  }

  /// Определяет MIME по расширению: сервер принимает только изображения и PDF.
  String? _mimeOf(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'pdf':
        return 'application/pdf';
      default:
        return null;
    }
  }

  /// Открывает приложенный документ системным просмотрщиком.
  ///
  /// Побочные эффекты: скачивает файл с сервера (закрытая ручка) и открывает его.
  Future<void> _openDocument() async {
    final e = widget.existing;
    if (e == null) return;
    final err = await downloadAndOpen(
      ref.read(appStateProvider).api,
      'expense:${e.id}',
      e.fileName ?? 'expense',
      url: ref.read(facturaApiProvider).expenseFileUrl(e.id),
    );
    if (err != null && mounted) setState(() => _error = err);
  }

  /// Сохраняет расход на сервере.
  ///
  /// Побочные эффекты: создаёт или правит строку расхода (вместе с приложенным документом),
  /// затем возвращает `true` — чтобы список перечитался.
  Future<void> _save() async {
    if (_supplierName.text.trim().isEmpty) {
      setState(() => _error = 'Укажите поставщика');
      return;
    }
    final net = double.tryParse(_netAmount.text.replaceAll(',', '.'));
    if (net == null || net <= 0) {
      setState(() => _error = 'Укажите сумму без НДС');
      return;
    }

    final body = <String, dynamic>{
      'supplierName': _supplierName.text.trim(),
      if (_supplierTaxId.text.trim().isNotEmpty) 'supplierTaxId': _supplierTaxId.text.trim(),
      if (_supplierCountry.text.trim().isNotEmpty)
        'supplierCountryCode': _supplierCountry.text.trim().toUpperCase(),
      'nature': _nature,
      'kind': _kind,
      'issueDate': '${_issueDate.year.toString().padLeft(4, '0')}-'
          '${_issueDate.month.toString().padLeft(2, '0')}-'
          '${_issueDate.day.toString().padLeft(2, '0')}',
      if (_category.text.trim().isNotEmpty) 'category': _category.text.trim(),
      if (_description.text.trim().isNotEmpty) 'description': _description.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      'currency': _currency,
      'netAmount': net,
      'vatRate': _vatRate,
      'irpfRate': _irpfRate,
      'deductibleVatPct': _deductibleVatPct,
      'deductibleForIrpf': _deductibleForIrpf,
      'reverseCharge': _reverseCharge,
      // 'keep' — маркер «документ остаётся прежним»: сам ключ сервер не отдаёт в списке.
      if (_fileKey != null && _fileKey != 'keep') 'fileS3Key': _fileKey,
      if (_fileKey != null && _fileKey != 'keep' && _fileMime != null) 'fileMime': _fileMime,
      if (_fileKey != null && _fileKey != 'keep' && _fileName != null) 'fileName': _fileName,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(facturaApiProvider);
      final existing = widget.existing;
      if (existing == null) {
        await api.createExpense(body);
      } else {
        await api.updateExpense(existing.id, body);
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

  /// Удаляет расход вместе с документом.
  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить расход?'),
        content: const Text('Расход и его документ удаляются безвозвратно.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(facturaApiProvider).deleteExpense(e.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FacturaApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Новый расход' : 'Расход'),
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_pickDocument()),
            icon: const Icon(Icons.document_scanner_outlined),
            label: Text(_busy ? 'Обработка…' : (_fileName == null ? 'Снять счёт или выбрать файл' : 'Заменить документ')),
          ),
          if (_fileName != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.attach_file, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(_fileName!, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (existing != null)
                  TextButton(onPressed: () => unawaited(_openDocument()), child: const Text('Открыть')),
              ],
            ),
          ],
          if (_scanNotice != null) ...[
            const SizedBox(height: 6),
            Text(_scanNotice!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 20),
          Text('Поставщик', style: Theme.of(context).textTheme.titleSmall),
          TextField(
            controller: _supplierName,
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _supplierTaxId,
                  decoration: const InputDecoration(labelText: 'NIF / VAT'),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _supplierCountry,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Страна'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Суммы', style: Theme.of(context).textTheme.titleSmall),
          TextField(
            controller: _netAmount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Сумма без НДС'),
            onChanged: (_) => setState(() {}),
          ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<double>(
                  initialValue: _vatRate,
                  decoration: const InputDecoration(labelText: 'НДС, %'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('0%')),
                    DropdownMenuItem(value: 4, child: Text('4%')),
                    DropdownMenuItem(value: 10, child: Text('10%')),
                    DropdownMenuItem(value: 21, child: Text('21%')),
                  ],
                  onChanged: (v) => setState(() => _vatRate = v ?? 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<double>(
                  initialValue: _irpfRate,
                  decoration: const InputDecoration(labelText: 'IRPF, %'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('0%')),
                    DropdownMenuItem(value: 7, child: Text('7%')),
                    DropdownMenuItem(value: 15, child: Text('15%')),
                  ],
                  onChanged: (v) => setState(() => _irpfRate = v ?? 0),
                ),
              ),
            ],
          ),
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
                    decoration: const InputDecoration(labelText: 'Дата документа'),
                    child: Text(
                      '${_issueDate.day.toString().padLeft(2, '0')}.'
                      '${_issueDate.month.toString().padLeft(2, '0')}.${_issueDate.year}',
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_vatRate > 0)
            DropdownButtonFormField<double>(
              initialValue: _deductibleVatPct,
              decoration: const InputDecoration(labelText: 'НДС к вычету, %'),
              items: const [
                DropdownMenuItem(value: 100, child: Text('100%')),
                DropdownMenuItem(value: 50, child: Text('50%')),
                DropdownMenuItem(value: 0, child: Text('0% (не вычитается)')),
              ],
              onChanged: (v) => setState(() => _deductibleVatPct = v ?? 100),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _reverseCharge,
            onChanged: (v) => setState(() => _reverseCharge = v),
            title: const Text('Покупка внутри ЕС (reverse charge)'),
            subtitle: const Text('НДС начисляет получатель; попадает в форму 349'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _deductibleForIrpf,
            onChanged: (v) => setState(() => _deductibleForIrpf = v),
            title: const Text('Учитывать в базе IRPF'),
          ),
          const SizedBox(height: 20),
          Text('Классификация', style: Theme.of(context).textTheme.titleSmall),
          DropdownButtonFormField<String>(
            initialValue: _nature,
            decoration: const InputDecoration(labelText: 'Что куплено'),
            items: const [
              DropdownMenuItem(value: 'service', child: Text('Услуга')),
              DropdownMenuItem(value: 'goods', child: Text('Товар')),
            ],
            onChanged: (v) => setState(() => _nature = v ?? 'service'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Вид документа'),
            items: const [
              DropdownMenuItem(value: 'invoice', child: Text('Обычный счёт')),
              DropdownMenuItem(value: 'recurring_no_invoice', child: Text('Взнос без счёта (RETA)')),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'invoice'),
          ),
          TextField(
            controller: _category,
            decoration: const InputDecoration(labelText: 'Категория'),
          ),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Описание'),
          ),
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Примечание'),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(child: Text('Итого с НДС')),
                  Text(
                    '${_total.toStringAsFixed(2)} $_currency',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
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
