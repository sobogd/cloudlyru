import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../util/download.dart';
import '../util/format.dart';
import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран «Поданные»: журнал того, что уже отправлено в AEAT.
///
/// У налоговой нет ручки, которая рассказала бы приложению о факте подачи, поэтому журнал
/// ведётся вручную. Смысл простой: не подать один и тот же квартал дважды и держать под рукой
/// номер justificante, который спрашивают при проверках и при подаче следующих форм.
///
/// Заполнять поля можно и не руками: PDF, выданный кабинетом AEAT после подачи, распознаётся
/// на сервере — номер justificante, даты и суммы подставляются в форму.
class FiledDeclarationsScreen extends ConsumerStatefulWidget {
  const FiledDeclarationsScreen({super.key});

  @override
  ConsumerState<FiledDeclarationsScreen> createState() => _FiledDeclarationsScreenState();
}

/// Состояние журнала: список записей, загрузка и текст последней ошибки.
class _FiledDeclarationsScreenState extends ConsumerState<FiledDeclarationsScreen> {
  /// Записи журнала (сервер отдаёт их без сортировки — сортируем на экране).
  List<FiledDeclarationView> _rows = const [];

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает журнал поданных деклараций.
  ///
  /// Побочные эффекты: обновляет [_rows] или [_error].
  Future<void> _load() async {
    try {
      final rows = await ref.read(facturaApiProvider).listFiledDeclarations();
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

  /// Открывает форму записи и перечитывает журнал после сохранения.
  Future<void> _openForm(FiledDeclarationView? existing) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => FiledDeclarationFormScreen(existing),
    ));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Свежие периоды сверху: журнал читают от последнего квартала назад.
    final rows = [..._rows]..sort((a, b) => b.year != a.year ? b.year - a.year : b.quarter - a.quarter);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Поданные'),
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
        label: const Text('Подача'),
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
                        Center(child: Text(_error ?? 'Поданных деклараций пока нет')),
                        const SizedBox(height: 8),
                        const Center(
                          child: Text(
                            'После подачи добавьте запись — или загрузите PDF из кабинета AEAT',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          child: ListTile(
                            onTap: () => unawaited(_openForm(row)),
                            leading: row.hasDocument
                                ? const Icon(Icons.attach_file, size: 20)
                                : const Icon(Icons.check_circle_outline, size: 20),
                            title: Text('Modelo ${row.model} · ${row.quarterLabel} ${row.year}',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              [
                                if (row.submittedAt != null) 'подано ${fullDate(row.submittedAt!)}',
                                if ((row.justificante ?? '').isNotEmpty) '№ ${row.justificante}',
                              ].join(' · '),
                            ),
                            trailing: row.resultPaid == null
                                ? null
                                : Text('${row.resultPaid!.toStringAsFixed(2)} €'),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// Форма записи журнала: номер формы, период, justificante, суммы и поданный PDF.
class FiledDeclarationFormScreen extends ConsumerStatefulWidget {
  const FiledDeclarationFormScreen(this.existing, {super.key});

  /// Правимая запись; `null` — заводим новую.
  final FiledDeclarationView? existing;

  @override
  ConsumerState<FiledDeclarationFormScreen> createState() => _FiledDeclarationFormScreenState();
}

/// Состояние формы поданной декларации.
class _FiledDeclarationFormScreenState extends ConsumerState<FiledDeclarationFormScreen> {
  /// Номер формы.
  String _model = '303';

  /// Год периода.
  int _year = DateTime.now().year;

  /// Квартал периода (1–4).
  int _quarter = 1;

  final _justificante = TextEditingController();
  final _resultPaid = TextEditingController();
  final _compensarNext = TextEditingController();
  final _notes = TextEditingController();

  /// Дата подачи (по умолчанию — сегодня).
  DateTime _submittedAt = DateTime.now();

  /// Ключ приложенного файла в S3.
  String? _fileKey;
  String? _fileMime;
  String? _fileName;

  bool _busy = false;
  String? _error;
  String? _scanNotice;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _model = e.model;
      _year = e.year;
      _quarter = e.quarter;
      _justificante.text = e.justificante ?? '';
      _resultPaid.text = e.resultPaid?.toStringAsFixed(2) ?? '';
      _compensarNext.text = e.compensarNext?.toStringAsFixed(2) ?? '';
      _notes.text = e.notes ?? '';
      _submittedAt = e.submittedAt ?? DateTime.now();
      _fileName = e.fileName;
      // 'keep' — маркер «файл остаётся прежним»: сам ключ сервер в списке не отдаёт.
      _fileKey = e.hasDocument ? 'keep' : null;
    } else {
      // Текущий квартал по календарю — самый частый случай при заведении записи.
      _quarter = ((DateTime.now().month - 1) ~/ 3) + 1;
    }
  }

  @override
  void dispose() {
    for (final c in [_justificante, _resultPaid, _compensarNext, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Выбирает PDF поданной декларации, загружает его и распознаёт поля.
  ///
  /// Побочные эффекты: файл уходит в S3 через API, распознанные значения попадают в форму.
  Future<void> _pickDocument() async {
    setState(() {
      _busy = true;
      _error = null;
      _scanNotice = null;
    });
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'],
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
          _error = 'Подойдёт PDF или фото декларации';
        });
        return;
      }
      final res = await ref.read(facturaApiProvider).uploadFiledDeclarationDoc(
            base64: base64Encode(bytes),
            mimeType: mime,
            fileName: file.name,
            // Распознаём только при заведении новой записи: при замене файла поля уже проверены.
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
          if (p.model.isNotEmpty) _model = p.model;
          if (p.year > 2000) _year = p.year;
          if (p.quarter >= 1 && p.quarter <= 4) _quarter = p.quarter;
          if (p.justificante.isNotEmpty) _justificante.text = p.justificante;
          if (p.resultPaid > 0) _resultPaid.text = p.resultPaid.toStringAsFixed(2);
          if (p.compensarNext > 0) _compensarNext.text = p.compensarNext.toStringAsFixed(2);
          final date = DateTime.tryParse(p.submittedAt);
          if (date != null) _submittedAt = date;
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

  /// Определяет MIME по расширению: сервер принимает изображения и PDF.
  String? _mimeOf(String name) {
    switch (name.toLowerCase().split('.').last) {
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

  /// Открывает приложенный PDF системным просмотрщиком.
  Future<void> _openDocument() async {
    final e = widget.existing;
    if (e == null) return;
    final err = await downloadAndOpen(
      ref.read(appStateProvider).api,
      'filed:${e.id}',
      e.fileName ?? 'declaration',
      url: ref.read(facturaApiProvider).filedDeclarationFileUrl(e.id),
    );
    if (err != null && mounted) setState(() => _error = err);
  }

  /// Сохраняет запись журнала.
  ///
  /// Побочные эффекты: создаёт или правит строку в журнале, затем возвращает `true`.
  Future<void> _save() async {
    final body = <String, dynamic>{
      'model': _model,
      'year': _year,
      'quarter': _quarter,
      'justificante': ?(_justificante.text.trim().isEmpty ? null : _justificante.text.trim()),
      'submittedAt': '${_submittedAt.year.toString().padLeft(4, '0')}-'
          '${_submittedAt.month.toString().padLeft(2, '0')}-'
          '${_submittedAt.day.toString().padLeft(2, '0')}',
      if (double.tryParse(_resultPaid.text.replaceAll(',', '.')) != null)
        'resultPaid': double.parse(_resultPaid.text.replaceAll(',', '.')),
      if (double.tryParse(_compensarNext.text.replaceAll(',', '.')) != null)
        'compensarNext': double.parse(_compensarNext.text.replaceAll(',', '.')),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      if (_fileKey != null && _fileKey != 'keep' && _fileMime != null) 'fileMime': _fileMime,
      if (_fileKey != null && _fileKey != 'keep' && _fileName != null) 'fileName': _fileName,
      if (_fileKey != null && _fileKey != 'keep') 'fileS3Key': _fileKey,
    };

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(facturaApiProvider);
      final existing = widget.existing;
      if (existing == null) {
        await api.createFiledDeclaration(body);
      } else {
        await api.updateFiledDeclaration(existing.id, body);
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

  /// Удаляет запись журнала вместе с файлом.
  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: const Text('Запись журнала и приложенный файл удаляются безвозвратно.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(facturaApiProvider).deleteFiledDeclaration(e.id);
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
        title: Text(existing == null ? 'Новая подача' : 'Поданная декларация'),
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
            icon: const Icon(Icons.upload_file),
            label: Text(_busy ? 'Обработка…' : (_fileName == null ? 'Загрузить PDF из кабинета AEAT' : 'Заменить файл')),
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
          DropdownButtonFormField<String>(
            initialValue: _model,
            decoration: const InputDecoration(labelText: 'Модель'),
            items: const [
              DropdownMenuItem(value: '303', child: Text('303 — НДС')),
              DropdownMenuItem(value: '130', child: Text('130 — аванс IRPF')),
              DropdownMenuItem(value: '349', child: Text('349 — операции в ЕС')),
            ],
            onChanged: (v) => setState(() => _model = v ?? '303'),
          ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _quarter,
                  decoration: const InputDecoration(labelText: 'Квартал'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1T')),
                    DropdownMenuItem(value: 2, child: Text('2T')),
                    DropdownMenuItem(value: 3, child: Text('3T')),
                    DropdownMenuItem(value: 4, child: Text('4T')),
                  ],
                  onChanged: (v) => setState(() => _quarter = v ?? 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _year,
                  decoration: const InputDecoration(labelText: 'Год'),
                  items: [
                    for (var y = DateTime.now().year; y >= DateTime.now().year - 6; y--)
                      DropdownMenuItem(value: y, child: Text('$y')),
                  ],
                  onChanged: (v) => setState(() => _year = v ?? _year),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _submittedAt,
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _submittedAt = picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Дата подачи'),
              child: Text(
                '${_submittedAt.day.toString().padLeft(2, '0')}.'
                '${_submittedAt.month.toString().padLeft(2, '0')}.${_submittedAt.year}',
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _justificante,
            decoration: const InputDecoration(labelText: 'Justificante (номер из кабинета AEAT)'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _resultPaid,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Уплачено, €'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _compensarNext,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'К вычету дальше, €'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Примечание'),
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
