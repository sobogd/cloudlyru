import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'factura_api.dart';
import 'factura_models.dart';
import 'factura_providers.dart';

/// Экран «Контрагенты»: справочник клиентов, которым выставляются фактуры.
///
/// Контрагент — не просто имя: страна определяет, начисляется ли НДС и удерживается ли IRPF,
/// а NIF уходит в PDF и в запись AEAT. Поэтому карточка хранит и адрес, и налоговый признак,
/// и валюту по умолчанию, а новый контрагент чаще всего заводят не руками, а вставкой
/// реквизитов из письма или счёта — текст разбирает сервер.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

/// Состояние справочника: список, загрузка и текст последней ошибки.
class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  List<ContactView> _rows = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Читает справочник контрагентов.
  ///
  /// Побочные эффекты: обновляет [_rows] или [_error].
  Future<void> _load() async {
    try {
      final rows = await ref.read(facturaApiProvider).listContacts();
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

  /// Открывает карточку контрагента и перечитывает список после сохранения.
  Future<void> _open(ContactView? existing) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => ContactFormScreen(existing),
    ));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = [..._rows]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Контрагенты'),
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
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Контрагент'),
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
                        Center(child: Text(_error ?? 'Контрагентов пока нет')),
                        const SizedBox(height: 8),
                        const Center(
                          child: Text(
                            'Можно вставить реквизиты из письма — поля заполнятся сами',
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
                        final c = rows[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          child: ListTile(
                            onTap: () => unawaited(_open(c)),
                            title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              [
                                if ((c.taxId ?? '').isNotEmpty) c.taxId!,
                                if ((c.countryCode ?? '').isNotEmpty) c.countryCode!,
                                if (c.isEu) 'ЕС',
                              ].join(' · '),
                            ),
                            trailing: c.currency == null ? null : Text(c.currency!),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// Карточка контрагента: создание и правка.
class ContactFormScreen extends ConsumerStatefulWidget {
  const ContactFormScreen(this.existing, {super.key});

  /// Правимый контрагент; `null` — создаём нового.
  final ContactView? existing;

  @override
  ConsumerState<ContactFormScreen> createState() => _ContactFormScreenState();
}

/// Состояние карточки контрагента.
class _ContactFormScreenState extends ConsumerState<ContactFormScreen> {
  final _name = TextEditingController();
  final _taxId = TextEditingController();
  final _country = TextEditingController(text: 'ES');
  final _email = TextEditingController();
  final _addressLine1 = TextEditingController();
  final _addressLine2 = TextEditingController();
  final _postalCode = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _notes = TextEditingController();
  final _pasteText = TextEditingController();

  /// Валюта фактур этому клиенту (`null` — валюта компании).
  String? _currency;

  /// `service` | `goods` — влияет на clave в форме 349.
  String _nature = 'service';

  /// Клиент на Канарах / Сеуте / Мелилье.
  bool _esNoIva = false;

  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    if (c != null) {
      _name.text = c.name;
      _taxId.text = c.taxId ?? '';
      _country.text = c.countryCode ?? 'ES';
      _email.text = c.email ?? '';
      _addressLine1.text = c.addressLine1 ?? '';
      _addressLine2.text = c.addressLine2 ?? '';
      _postalCode.text = c.postalCode ?? '';
      _city.text = c.city ?? '';
      _region.text = c.region ?? '';
      _notes.text = c.notes ?? '';
      _currency = c.currency;
      _nature = c.nature ?? 'service';
      _esNoIva = c.esNoIva;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _taxId,
      _country,
      _email,
      _addressLine1,
      _addressLine2,
      _postalCode,
      _city,
      _region,
      _notes,
      _pasteText,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Разбирает вставленный текст в поля карточки.
  ///
  /// Побочные эффекты: заполняет пустые поля распознанными значениями (уже введённое не трогаем).
  Future<void> _parsePasted() async {
    final text = _pasteText.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final p = await ref.read(facturaApiProvider).parseContactText(text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (p.name.isNotEmpty && _name.text.isEmpty) _name.text = p.name;
        if (p.taxId.isNotEmpty && _taxId.text.isEmpty) _taxId.text = p.taxId;
        if (p.countryCode.isNotEmpty) _country.text = p.countryCode;
        if (p.email.isNotEmpty && _email.text.isEmpty) _email.text = p.email;
        if (p.addressLine1.isNotEmpty && _addressLine1.text.isEmpty) _addressLine1.text = p.addressLine1;
        if (p.city.isNotEmpty && _city.text.isEmpty) _city.text = p.city;
        if (p.postalCode.isNotEmpty && _postalCode.text.isEmpty) _postalCode.text = p.postalCode;
        if (p.region.isNotEmpty && _region.text.isEmpty) _region.text = p.region;
        _notice = 'Поля заполнены по тексту — проверьте их перед сохранением';
      });
    } on FacturaApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Сохраняет контрагента.
  ///
  /// Побочные эффекты: создаёт или правит карточку на сервере, возвращает `true`.
  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Укажите имя контрагента');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'taxId': _taxId.text.trim(),
        'countryCode': _country.text.trim().toUpperCase(),
        'email': _email.text.trim(),
        'addressLine1': _addressLine1.text.trim(),
        'addressLine2': _addressLine2.text.trim(),
        'postalCode': _postalCode.text.trim(),
        'city': _city.text.trim(),
        'region': _region.text.trim(),
        'notes': _notes.text.trim(),
        'nature': _nature,
        'esNoIva': _esNoIva,
        if (_currency != null) 'currency': _currency,
      };
      final api = ref.read(facturaApiProvider);
      final existing = widget.existing;
      if (existing == null) {
        await api.createContact(body);
      } else {
        await api.updateContact(existing.id, body);
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

  /// Архивирует контрагента.
  ///
  /// Удаление мягкое: строка остаётся в базе, потому что на неё ссылаются уже выставленные
  /// фактуры, — сервер только помечает её архивной и убирает из списков.
  Future<void> _archive() async {
    final c = widget.existing;
    if (c == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Убрать контрагента?'),
        content: const Text('Он исчезнет из списков, но останется в уже выставленных фактурах.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Убрать')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(facturaApiProvider).deleteContact(c.id);
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
        title: Text(existing == null ? 'Новый контрагент' : 'Контрагент'),
        actions: [
          if (existing != null)
            IconButton(
              onPressed: _busy ? null : () => unawaited(_archive()),
              icon: const Icon(Icons.person_remove_outlined),
              tooltip: 'Убрать из списков',
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
          if (existing == null) ...[
            Text('Вставить реквизиты', style: Theme.of(context).textTheme.titleSmall),
            TextField(
              controller: _pasteText,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Скопируйте блок реквизитов из письма или счёта',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => unawaited(_parsePasted()),
              icon: const Icon(Icons.auto_fix_high),
              label: Text(_busy ? 'Разбор…' : 'Разобрать в поля'),
            ),
            const Divider(height: 32),
          ],
          Text('Реквизиты', style: Theme.of(context).textTheme.titleSmall),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Имя / название')),
          Row(
            children: [
              Expanded(child: TextField(controller: _taxId, decoration: const InputDecoration(labelText: 'NIF / VAT'))),
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
          TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')),
          TextField(controller: _addressLine1, decoration: const InputDecoration(labelText: 'Адрес')),
          TextField(controller: _addressLine2, decoration: const InputDecoration(labelText: 'Адрес, строка 2')),
          Row(
            children: [
              Expanded(child: TextField(controller: _postalCode, decoration: const InputDecoration(labelText: 'Индекс'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _city, decoration: const InputDecoration(labelText: 'Город'))),
            ],
          ),
          TextField(controller: _region, decoration: const InputDecoration(labelText: 'Регион')),
          const SizedBox(height: 16),
          Text('Налоги', style: Theme.of(context).textTheme.titleSmall),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: const InputDecoration(
              labelText: 'Валюта фактур',
              helperText: 'Пусто — валюта компании',
            ),
            items: const [
              DropdownMenuItem(value: null, child: Text('как у компании')),
              DropdownMenuItem(value: 'EUR', child: Text('EUR')),
              DropdownMenuItem(value: 'USD', child: Text('USD')),
              DropdownMenuItem(value: 'GBP', child: Text('GBP')),
              DropdownMenuItem(value: 'CHF', child: Text('CHF')),
            ],
            onChanged: (v) => setState(() => _currency = v),
          ),
          DropdownButtonFormField<String>(
            initialValue: _nature,
            decoration: const InputDecoration(labelText: 'Что поставляем'),
            items: const [
              DropdownMenuItem(value: 'service', child: Text('Услуги')),
              DropdownMenuItem(value: 'goods', child: Text('Товары')),
            ],
            onChanged: (v) => setState(() => _nature = v ?? 'service'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _esNoIva,
            onChanged: (v) => setState(() => _esNoIva = v),
            title: const Text('Канары / Сеута / Мелилья'),
            subtitle: const Text('Испания вне зоны НДС'),
          ),
          TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Примечание')),
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
