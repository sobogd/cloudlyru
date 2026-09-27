import 'dart:convert' show jsonEncode;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_types.dart';

class AgentProvidersScreen extends ConsumerStatefulWidget {
  const AgentProvidersScreen({super.key});

  @override
  ConsumerState<AgentProvidersScreen> createState() =>
      _AgentProvidersScreenState();
}

class _AgentProvidersScreenState extends ConsumerState<AgentProvidersScreen> {
  late final AgentProvidersController _providers;

  @override
  void initState() {
    super.initState();
    _providers = ref.read(agentProvidersProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _providers.load();
    });
  }

  Future<void> _edit([AgentProvider? provider]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentProviderFormScreen(provider: provider),
      ),
    );
    if (mounted) await _providers.load();
  }

  Future<void> _delete(AgentProvider provider) async {
    final ok = await confirmDialog(
      context,
      'Удалить провайдера',
      '«${provider.label}» исчезнет из настроек pi на маке вместе со своими моделями. '
          'Ключ и адрес придётся вводить заново.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    await _providers.remove(provider.key);
  }

  Future<void> _key(AgentProvider provider) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _KeyDialog(provider: provider),
    );
    if (value == null || !mounted) return;
    final error = await _providers.setKey(provider.key, value);
    if (!mounted) return;
    snack(
      context,
      error ?? (value.trim().isEmpty ? 'Ключ убран' : 'Ключ сохранён на маке'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentProvidersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Модели и ключи',
          style: TextStyle(color: C.fg, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: state.loading ? null : () => _providers.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.accent,
        foregroundColor: C.accentFg,
        onPressed: state.loading ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Свой провайдер'),
      ),
      body: Column(
        children: [
          if (state.error != null) _errorBar(state.error!),
          Expanded(
            child: state.loading && state.providers.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: EdgeInsets.only(
                      top: 8,
                      bottom: 88 + navBarInset(context),
                    ),
                    children: [
                      _sectionTitle('Настроены на маке'),
                      for (final provider in state.custom)
                        _customTile(provider),
                      _sectionTitle('По API: встроены в pi'),
                      for (final provider in state.builtin)
                        _builtinTile(provider),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          'Ключ по API уезжает на мак и остаётся там: в приложении и на сервере он '
                          'не хранится. Свои провайдеры — это любой OpenAI-совместимый сервис: '
                          'адрес, ключ и модели задаются здесь.',
                          style: TextStyle(
                            color: C.fg3,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: const TextStyle(color: C.fg3, fontSize: 12, letterSpacing: 0.3),
    ),
  );

  Widget _customTile(AgentProvider provider) => ListTile(
    leading: Icon(
      provider.local ? Icons.memory : Icons.cloud_outlined,
      color: provider.local ? C.ok : C.fg2,
    ),
    title: Text(
      provider.label,
      style: const TextStyle(color: C.fg, fontSize: 15),
    ),
    subtitle: Text(
      [
        provider.key,
        provider.baseUrl,
        provider.models.isEmpty
            ? 'моделей нет'
            : 'моделей: ${provider.models.length}',
        if (!provider.hasKey) 'ключ не задан',
      ].join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: C.fg3, fontSize: 12),
    ),
    onTap: () => _edit(provider),
    trailing: PopupMenuButton<String>(
      tooltip: 'Действия',
      onSelected: (v) => v == 'edit'
          ? _edit(provider)
          : v == 'key'
          ? _key(provider)
          : _delete(provider),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'edit', child: Text('Изменить')),
        PopupMenuItem(value: 'key', child: Text('Ключ')),
        PopupMenuItem(value: 'delete', child: Text('Удалить')),
      ],
    ),
  );

  Widget _builtinTile(AgentProvider provider) => ListTile(
    leading: Icon(
      provider.hasKey ? Icons.key : Icons.key_off_outlined,
      color: provider.hasKey ? C.ok : C.fg3,
    ),
    title: Text(
      provider.label,
      style: const TextStyle(color: C.fg, fontSize: 15),
    ),
    subtitle: Text(
      provider.hasKey
          ? 'ключ задан (${provider.keyLength} симв.)'
          : 'ключ не задан',
      style: const TextStyle(color: C.fg3, fontSize: 12),
    ),
    trailing: TextButton(
      onPressed: () => _key(provider),
      child: Text(provider.hasKey ? 'Заменить' : 'Задать'),
    ),
  );

  Widget _errorBar(String message) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: C.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.danger),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: C.danger, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
          ),
        ),
      ],
    ),
  );
}

class _KeyDialog extends StatefulWidget {
  final AgentProvider provider;

  const _KeyDialog({required this.provider});

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    return AlertDialog(
      backgroundColor: C.surface,
      title: Text(
        provider.hasKey
            ? 'Заменить ключ: ${provider.label}'
            : 'Ключ: ${provider.label}',
        style: const TextStyle(color: C.fg, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider.hasKey
                ? 'Сейчас ключ задан (${provider.keyLength} симв.). Новый заменит его; пустое '
                      'поле уберёт ключ совсем.'
                : 'Ключ уедет на мак и останется там: в приложении и на сервере он не хранится.',
            style: const TextStyle(color: C.fg3, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            style: const TextStyle(color: C.fg, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'вставьте ключ',
              hintStyle: TextStyle(color: C.fg3, fontSize: 12),
              filled: true,
              fillColor: C.canvas,
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class AgentProviderFormScreen extends ConsumerStatefulWidget {
  final AgentProvider? provider;

  const AgentProviderFormScreen({super.key, this.provider});

  @override
  ConsumerState<AgentProviderFormScreen> createState() =>
      _AgentProviderFormScreenState();
}

class _AgentProviderFormScreenState
    extends ConsumerState<AgentProviderFormScreen> {
  late final TextEditingController _key = TextEditingController(
    text: widget.provider?.key ?? '',
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.provider?.name ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.provider?.baseUrl ?? '',
  );
  late final TextEditingController _api = TextEditingController(
    text: (widget.provider?.api.isNotEmpty ?? false)
        ? widget.provider!.api
        : 'openai-completions',
  );
  final _apiKey = TextEditingController();
  final _manualModel = TextEditingController();

  String? _expandedModel;

  final _ctxController = TextEditingController();
  final _maxTokensController = TextEditingController();

  final List<TextEditingController> _paramKeys = [];
  final List<TextEditingController> _paramValues = [];

  late final List<AgentModel> _models = [...?widget.provider?.models];

  List<AgentModel> _found = const [];

  bool _probing = false;

  bool _saving = false;

  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _api.dispose();
    _apiKey.dispose();
    _manualModel.dispose();
    for (final c in [..._paramKeys, ..._paramValues]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() {
      _probing = true;
      _error = null;
    });
    final controller = ref.read(agentProvidersProvider.notifier);
    final (models, error) = await controller.probe(
      baseUrl: _baseUrl.text,
      provider: widget.provider?.key ?? '',
      apiKey: _apiKey.text,
    );
    if (!mounted) return;
    setState(() {
      _probing = false;
      _found = models;
      _error = error;
    });
    if (error == null && mounted) {
      snack(context, 'Провайдер ответил: моделей ${models.length}');
    }
  }

  void _toggleModel(int index) {
    final model = _models[index];
    if (_expandedModel == model.id) {
      setState(() => _expandedModel = null);
    } else {
      for (final c in [..._paramKeys, ..._paramValues]) {
        c.dispose();
      }
      _paramKeys.clear();
      _paramValues.clear();
      for (final e in model.samplingParams.entries) {
        _paramKeys.add(TextEditingController(text: e.key));
        final value = e.value == null ? '' : switch (e.value) {
          String() => e.value as String,
              final other => jsonEncode(other),
        };
        _paramValues.add(TextEditingController(text: value));
      }
      setState(() {
        _expandedModel = model.id;
        final ctx = model.contextWindow ?? 0;
        _ctxController.text = ctx == 0 ? '' : '$ctx';
        final maxTokens = model.maxTokens ?? 0;
        _maxTokensController.text = maxTokens == 0 ? '' : '$maxTokens';
      });
    }
  }

  void _resetModelDrafts() {
    for (final c in [..._paramKeys, ..._paramValues]) {
      c.dispose();
    }
    _paramKeys.clear();
    _paramValues.clear();
    _ctxController.text = '';
    _maxTokensController.text = '';
  }

  Map<String, Object?> _draftParams() {
    final params = <String, Object?>{};
    for (var i = 0; i < _paramKeys.length; i++) {
      final key = _paramKeys[i].text.trim();
      if (key.isEmpty) continue;
      final value = _parseParamValue(_paramValues[i].text);
      if (value != null) params[key] = value;
    }
    return params;
  }

  static Object? _parseParamValue(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (text == 'true') return true;
    if (text == 'false') return false;
    final number = int.tryParse(text) ?? double.tryParse(text);
    if (number != null && number.toString() == text) return number;
    return text;
  }

  void _syncModelDrafts(int index) {
    final model = _models[index];
    if (_expandedModel != model.id) return;
    setState(() {
      _models[index] = AgentModel(
        provider: model.provider,
        id: model.id,
        name: model.name,
        contextWindow: int.tryParse(_ctxController.text.trim()),
        maxTokens: int.tryParse(_maxTokensController.text.trim()),
        thinking: model.thinking,
        images: model.images,
        samplingParams: _draftParams(),
      );
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await ref
        .read(agentProvidersProvider.notifier)
        .save(
          key: _key.text.trim(),
          name: _name.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          api: _api.text.trim(),
          apiKey: _apiKey.text.trim(),
          models: _models,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.provider != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          editing ? 'Провайдер: ${widget.provider!.label}' : 'Свой провайдер',
          style: const TextStyle(color: C.fg, fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + navBarInset(context)),
        children: [
          _field(
            _key,
            'Идентификатор',
            'например deepseek — латиницей',
            enabled: !editing,
          ),
          _field(_name, 'Название', 'как показывать в выборе модели'),
          _field(_baseUrl, 'Адрес API', 'https://api.deepseek.com/v1'),
          _field(_api, 'Тип API', 'openai-completions'),
          _field(
            _apiKey,
            editing ? 'Ключ (пусто — оставить прежний)' : 'Ключ',
            editing && (widget.provider?.hasKey ?? false)
                ? 'сейчас задан, ${widget.provider!.keyLength} симв.'
                : 'уедет на мак и останется там',
            obscure: true,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _probing ? null : _probe,
                icon: _probing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(
                  _probing ? 'Проверяю…' : 'Проверить и подтянуть модели',
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: C.danger,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          if (_found.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Провайдер вернул модели — отметьте нужные',
              style: TextStyle(color: C.fg2, fontSize: 13),
            ),
            const SizedBox(height: 4),
            for (final model in _found)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _models.any((m) => m.id == model.id),
                onChanged: (on) => setState(() {
                  if (on == true) {
                    _models.add(model);
                  } else {
                    _models.removeWhere((m) => m.id == model.id);
                  }
                }),
                title: Text(
                  model.label,
                  style: const TextStyle(color: C.fg, fontSize: 13.5),
                ),
                subtitle: Text(
                  model.id,
                  style: const TextStyle(color: C.fg3, fontSize: 11.5),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualModel,
                  style: const TextStyle(color: C.fg, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'модель вручную: идентификатор',
                    hintStyle: TextStyle(color: C.fg3, fontSize: 12),
                    filled: true,
                    fillColor: C.canvas,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  final id = _manualModel.text.trim();
                  if (id.isEmpty) return;
                  setState(() {
                    if (!_models.any((m) => m.id == id)) {
                      _models.add(
                        AgentModel(
                          provider: _key.text.trim(),
                          id: id,
                          name: id,
                        ),
                      );
                    }
                    _manualModel.clear();
                  });
                },
                child: const Text('Добавить'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Модели провайдера',
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          for (var i = 0; i < _models.length; i++)
            _modelTile(i),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Сохраняю…' : 'Сохранить на маке'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Провайдер сохраняется в ~/.pi/agent/models.json на маке (прежний файл остаётся рядом '
            'копией .bak). Модели появятся в выборе сразу, а уже открытые сессии продолжат '
            'считаться той моделью, с которой начаты.',
            style: TextStyle(color: C.fg3, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool enabled = true,
    bool obscure = false,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      keyboardType: keyboardType ?? TextInputType.text,
      style: const TextStyle(color: C.fg, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: C.fg3, fontSize: 12),
        hintText: hint,
        hintStyle: const TextStyle(color: C.fg3, fontSize: 12),
        filled: true,
        fillColor: C.canvas,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  Widget _modelTile(int index) {
    final model = _models[index];
    final expanded = _expandedModel == model.id;
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(model.id, style: const TextStyle(color: C.fg, fontSize: 13.5)),
          subtitle: Text(_modelParamsLabel(model), style: const TextStyle(color: C.fg3, fontSize: 11.5)),
          onTap: () => _toggleModel(index),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Параметры',
                onPressed: () => _toggleModel(index),
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
              ),
              IconButton(
                tooltip: 'Убрать',
                onPressed: () {
                  if (_expandedModel == model.id) _resetModelDrafts();
                  setState(() {
                    if (_expandedModel == model.id) _expandedModel = null;
                    _models.removeWhere((m) => m.id == model.id);
                  });
                },
                icon: const Icon(Icons.close, size: 18, color: C.fg3),
              ),
            ],
          ),
        ),
        if (expanded) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
            child: Column(
              children: [
                _field(
                  _ctxController,
                  'Окно контекста',
                  'токены: сколько модели видно из истории',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _syncModelDrafts(index),
                ),
                _field(
                  _maxTokensController,
                  'Потолок ответа',
                  'максимум токенов в одном ответе',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _syncModelDrafts(index),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Размышляет',
                    style: TextStyle(color: C.fg, fontSize: 13),
                  ),
                  value: model.thinking,
                  onChanged: (on) => _patchModel(index, thinking: on == true),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Принимает картинки',
                    style: TextStyle(color: C.fg, fontSize: 13),
                  ),
                  value: model.images,
                  onChanged: (on) => _patchModel(index, images: on == true),
                ),
                ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 8),
                    child: Text(
                      'Параметры сэмплирования',
                      style: TextStyle(color: C.fg3, fontSize: 12),
                    ),
                  ),
                  for (var i = 0; i < _paramKeys.length; i++) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _paramField(_paramKeys[i], 'ключ', index)),
                        const SizedBox(width: 8),
                        Expanded(child: _paramField(_paramValues[i], 'значение', index)),
                        IconButton(
                          tooltip: 'Убрать параметр',
                          onPressed: () => _removeParamRow(i),
                          icon: const Icon(Icons.close, size: 16, color: C.fg3),
                        ),
                      ],
                    ),
                  ],
                  TextButton.icon(
                    onPressed: _addParamRow,
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(
                      'Добавить параметр',
                      style: TextStyle(color: C.accent, fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          )],
      ],
    );
  }

  String _modelParamsLabel(AgentModel model) {
    final parts = <String>[
      if (model.contextWindow != null) 'окно ${_fmtTokens(model.contextWindow!)}',
      if (model.maxTokens != null) 'потолок ${_fmtTokens(model.maxTokens!)}',
    ];
    if (model.thinking) {
      parts.add('размышляет');
    }
    if (model.images) {
      parts.add('картинки');
    }
    final n = model.samplingParams.length;
    if (n > 0) {
      parts.add('$n ${_plural(n, 'параметр', 'параметра', 'параметров')}');
    }
    return parts.join(' · ');
  }

  String _fmtTokens(int v) {
    if (v >= 1024 && v % 1024 == 0) {
      return '${v ~/ 1024}К';
    }
    if (v >= 1 << 20) {
      return '${(v / (1 << 20)).toStringAsFixed(1)}М';
    }
    return '$v';
  }

  String _plural(int n, String one, String few, String many) {
    final m10 = n % 10;
    final m100 = n % 100;
    if (m10 == 1 && m100 != 11) {
      return one;
    }
    if (m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14)) {
      return few;
    }
    return many;
  }

  void _patchModel(int index, {bool? thinking, bool? images}) {
    final model = _models[index];
    setState(() {
      _models[index] = AgentModel(
        provider: model.provider,
        id: model.id,
        name: model.name,
        contextWindow: int.tryParse(_ctxController.text.trim()),
        maxTokens: int.tryParse(_maxTokensController.text.trim()),
        thinking: thinking ?? model.thinking,
        images: images ?? model.images,
        samplingParams: _draftParams(),
      );
    });
  }

  Widget _paramField(TextEditingController controller, String hint, int modelIndex) {
    return TextField(
      controller: controller,
      onChanged: (_) => _syncModelDrafts(modelIndex),
      style: const TextStyle(color: C.fg, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: C.fg3, fontSize: 12),
        filled: true,
        fillColor: C.canvas,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  void _addParamRow() {
    setState(() {
      _paramKeys.add(TextEditingController());
      _paramValues.add(TextEditingController());
    });
  }

  void _removeParamRow(int i) {
    setState(() {
      final k = _paramKeys.removeAt(i);
      k.dispose();
      final v = _paramValues.removeAt(i);
      v.dispose();
    });
  }
}