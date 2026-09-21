import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/widgets.dart';
import 'agent_controller.dart';
import 'agent_types.dart';

/// Экран «Модели и ключи»: провайдеры, которые видит харнесс на маке, и их ключи.
///
/// Всё, что здесь меняется, меняется в файлах pi на маке: свои провайдеры — в
/// `~/.pi/agent/models.json`, ключи встроенных — в `~/.pi/agent/auth.json`. Приложение только
/// показывает список и пишет изменения через мост, поэтому ключи не лежат ни в телефоне, ни на
/// сервере: они уезжают на мак и остаются там.
///
/// Два вида провайдеров, и разница только в том, кто знает адрес API:
/// * **свои** — адрес, тип API, ключ и список моделей задаёт человек; годятся для любого
///   OpenAI-совместимого сервиса, включая свой сервер;
/// * **встроенные** — их pi знает сам (anthropic, openai, deepseek и прочие), у них задаётся
///   только ключ, а список моделей появляется у pi сразу после этого.
class AgentProvidersScreen extends ConsumerStatefulWidget {
  /// Экран провайдеров.
  const AgentProvidersScreen({super.key});

  @override
  ConsumerState<AgentProvidersScreen> createState() =>
      _AgentProvidersScreenState();
}

/// Состояние экрана: контроллер списка, взятый один раз.
class _AgentProvidersScreenState extends ConsumerState<AgentProvidersScreen> {
  /// Контроллер списка провайдеров.
  late final AgentProvidersController _providers;

  @override
  void initState() {
    super.initState();
    _providers = ref.read(agentProvidersProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _providers.load();
    });
  }

  /// Открывает форму своего провайдера: новую или для правки существующего.
  Future<void> _edit([AgentProvider? provider]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentProviderFormScreen(provider: provider),
      ),
    );
    if (mounted) await _providers.load();
  }

  /// Удаляет своего провайдера с подтверждением.
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

  /// Спрашивает ключ встроенного провайдера и сохраняет (или убирает) его.
  ///
  /// Показываем только признак «ключ задан»: сохранённый ключ не читается обратно ни в
  /// приложение, ни на сервер — заменить его можно, а подсмотреть нельзя. Пустое поле убирает
  /// ключ совсем: так провайдер отключается, не трогая ничего лишнего.
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

  /// Заголовок раздела списка.
  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: const TextStyle(color: C.fg3, fontSize: 12, letterSpacing: 0.3),
    ),
  );

  /// Строка своего провайдера: адрес, модели, правка и удаление.
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
    onTap: provider.local ? null : () => _edit(provider),
    trailing: provider.local
        ? const Icon(Icons.lock_outline, size: 18, color: C.fg3)
        : PopupMenuButton<String>(
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

  /// Строка встроенного провайдера: задан ли ключ и кнопка его замены.
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

  /// Сообщение об ошибке над списком.
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

/// Диалог ввода ключа встроенного провайдера.
///
/// Отдельный виджет, а не поле в обработчике нажатия: контроллер поля должен освобождаться
/// тогда же, когда исчезает само поле (в [State.dispose]), иначе диалог, закрываясь с
/// анимацией, обращается к уже освобождённому контроллеру.
class _KeyDialog extends StatefulWidget {
  /// Провайдер, для которого вводится ключ.
  final AgentProvider provider;

  /// Диалог ключа.
  const _KeyDialog({required this.provider});

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

/// Состояние диалога: одно поле с ключом.
class _KeyDialogState extends State<_KeyDialog> {
  /// Поле ключа; новый ключ не подставляем — сохранённый не читается обратно.
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

/// Форма своего провайдера: адрес, ключ и модели.
///
/// Модели не заставляют вписывать руками: кнопка «Проверить и подтянуть» спрашивает у
/// провайдера его собственный список (`GET /models`), и выбранные модели добавляются в
/// настройки. Проверка заодно отвечает на вопрос, рабочий ли ключ, — до сохранения.
class AgentProviderFormScreen extends ConsumerStatefulWidget {
  /// Провайдер для правки; `null` — новый.
  final AgentProvider? provider;

  /// Форма своего провайдера.
  const AgentProviderFormScreen({super.key, this.provider});

  @override
  ConsumerState<AgentProviderFormScreen> createState() =>
      _AgentProviderFormScreenState();
}

/// Состояние формы: поля, черновики моделей и признак «идёт проверка».
class _AgentProviderFormScreenState
    extends ConsumerState<AgentProviderFormScreen> {
  /// Поля формы: идентификатор, название, адрес, тип API и ключ.
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

  /// Модели провайдера: выбранные в списке и добавленные вручную.
  late final List<AgentModel> _models = [...?widget.provider?.models];

  /// Модели, полученные от провайдера при проверке (ещё не выбранные).
  List<AgentModel> _found = const [];

  /// Идёт проверка провайдера.
  bool _probing = false;

  /// Идёт сохранение.
  bool _saving = false;

  /// Текст ошибки, показываемый рядом с полями.
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _api.dispose();
    _apiKey.dispose();
    _manualModel.dispose();
    super.dispose();
  }

  /// Проверяет адрес и ключ и подтягивает список моделей провайдера.
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

  /// Сохраняет провайдера и закрывает форму.
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
          for (final model in _models)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                model.id,
                style: const TextStyle(color: C.fg, fontSize: 13.5),
              ),
              subtitle: Text(
                [
                  if (model.contextWindow != null)
                    'окно ${model.contextWindow}',
                  if (model.maxTokens != null) 'потолок ${model.maxTokens}',
                  if (model.thinking) 'размышления',
                ].join(' · '),
                style: const TextStyle(color: C.fg3, fontSize: 11.5),
              ),
              trailing: IconButton(
                tooltip: 'Убрать',
                onPressed: () => setState(
                  () => _models.removeWhere((m) => m.id == model.id),
                ),
                icon: const Icon(Icons.close, size: 18, color: C.fg3),
              ),
            ),
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

  /// Поле формы с подписью и подсказкой.
  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool enabled = true,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
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
}
