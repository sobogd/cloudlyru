import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import '../files/file_detail.dart';
import 'mail_body_web.dart';

const _rowH = 76.0;

class MailScreen extends ConsumerStatefulWidget {
  const MailScreen({super.key});

  @override
  ConsumerState<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends ConsumerState<MailScreen> {
  String _box = 'inbox';
  int? _total;
  List<MailMonthBucket> _months = const [];
  final Map<int, MailListItem> _items = {};
  List<MailAccountRow> _accounts = const [];
  String? _error;
  bool _busy = false;
  final ScrollController _sc = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _loadAccounts();
    _loadCounters();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sc.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    try {
      final a = await ref.read(appStateProvider).api.mailAccounts();
      if (mounted) setState(() => _accounts = a);
    } catch (_) {}
  }

  Future<void> _loadCounters() async {
    try {
      final api = ref.read(appStateProvider).api;
      final n = await api.mailCount(_box);
      final m = await api.mailMonths(_box);
      if (mounted) setState(() {
        _total = n;
        _months = m;
        _items.clear();
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchVisible();
      });
    } catch (e) {
      debugPrint('mail counters error: $e');
      if (mounted && _total == null) setState(() => _error = e.toString());
    }
  }

  void _onScroll() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _fetchVisible);
  }

  Future<void> _fetchVisible() async {
    final t = _total;
    if (t == null || t == 0) return;
    final api = ref.read(appStateProvider).api;
    // Список тоже надо наполнить до первого скролла (контроллер может быть ещё не привязан).
    final top = _sc.hasClients ? _sc.offset : 0.0;
    final vh = _sc.hasClients ? _sc.position.viewportDimension : 900.0;
    final first = math.max(0, (top / _rowH).floor() - 6);
    final last = math.min(t - 1, ((top + vh) / _rowH).ceil() + 6);
    if (first > last) return;
    final spans = <(int, int)>[];
    var a = -1;
    for (var i = first; i <= last; i++) {
      if (!_items.containsKey(i)) {
        if (a == -1) a = i;
      } else if (a != -1) {
        spans.add((a, i - 1));
        a = -1;
      }
    }
    if (a != -1) spans.add((a, last));
    for (final (s, e) in spans) {
      for (var off = s; off <= e; off += 200) {
        final len = math.min(200, e - off + 1);
        try {
          final page = await api.mailRange(_box, off, len);
          if (!mounted) return;
          setState(() {
            for (var j = 0; j < page.length; j++) {
              _items[off + j] = page[j];
            }
          });
          debugPrint('mail fetched: off=$off len=${page.length}');
        } catch (e) {
          debugPrint('mail range error: $e');
        }
      }
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      // Сервер держит IDLE, поэтому новое письмо уже в базе — просто перечитываем список.
      // Настоящий проход по IMAP остался кнопкой «Проверить» в настройках.
      await _loadCounters();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _emptyTrash() async {
    final ok = await confirmDialog(context, 'Очистить корзину почты?', 'Письма будут удалены безвозвратно.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.mailPurgeTrash();
      await _loadCounters();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  void _openMessage(String id) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailViewerScreen(messageId: id, inTrash: _box == 'trash'),
    )).then((_) => _loadCounters());
  }

  void _openCompose({MailReplyContext? ctx, String? inReplyToId}) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailComposerScreen(
        accounts: _accounts,
        context_: ctx,
      ),
    )).then((sent) {
      if (sent == true) {
        setState(() => _box = 'sent');
        _loadCounters();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _total;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Row(children: [
          _boxTab('inbox', Icons.inbox_outlined, 'Входящие'),
          _boxTab('sent', Icons.send_outlined, 'Исходящие'),
          _boxTab('trash', Icons.delete_outline, 'Корзина'),
        ]),
        actions: [
          if (_box == 'trash' && (t ?? 0) > 0)
            IconButton(tooltip: 'Очистить корзину', icon: const Icon(Icons.delete_sweep_outlined, color: C.fg), onPressed: _emptyTrash),
          IconButton(
            tooltip: 'Проверить почту',
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, color: C.fg),
            onPressed: _busy ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Написать письмо',
            icon: const Icon(Icons.edit_outlined, color: C.fg),
            onPressed: _accounts.any((a) => a.enabled) ? () => _openCompose() : null,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: C.danger)))
          : t == null
              ? const Center(child: CircularProgressIndicator())
              : t == 0
                  ? Center(child: Text(
                      _box == 'inbox' ? 'Входящих пока нет' : _box == 'sent' ? 'Исходящих пока нет' : 'Корзина пуста',
                      style: const TextStyle(color: C.fg3)))
                  : ListView.builder(
                      controller: _sc,
                      itemCount: t,
                      itemExtent: _rowH,
                      itemBuilder: (context, i) => _row(i),
                    ),
    );
  }

  Widget _boxTab(String id, IconData icon, String label) {
    final active = _box == id;
    return InkWell(
      onTap: () {
        setState(() {
          _box = id;
          _total = null;
          _items.clear();
        });
        _loadCounters();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Icon(icon, color: active ? C.accent : C.fg3),
      ),
    );
  }

  Widget _row(int i) {
    final item = _items[i];
    if (item == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Container(color: C.surface3, height: 52, width: double.infinity),
      );
    }
    final api = ref.read(appStateProvider).api;
    return InkWell(
      onTap: () => _openMessage(item.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.brd))),
        child: Row(children: [
          _avatar(api, item),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    item.fromName ?? item.fromAddr ?? 'без отправителя',
                    style: TextStyle(color: C.fg, fontSize: 14, fontWeight: item.seen ? FontWeight.w400 : FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (item.threadCount > 1) Text('${item.threadCount}', style: const TextStyle(color: C.fg3, fontSize: 11)),
                const SizedBox(width: 6),
                Text(_accountTag(item), style: const TextStyle(color: C.fg3, fontSize: 11)),
                const SizedBox(width: 6),
                Text(item.sortAt == null ? '' : listDate(DateTime.parse(item.sortAt!), DateTime.now()),
                    style: const TextStyle(color: C.fg3, fontSize: 11)),
              ]),
              const SizedBox(height: 2),
              Text(item.subject ?? '(без темы)',
                  style: TextStyle(color: C.fg, fontSize: 13, fontWeight: item.seen ? FontWeight.w400 : FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 1),
              Text(item.preview.isEmpty ? ' ' : item.preview,
                  style: const TextStyle(color: C.fg3, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (item.hasAttachments) const Icon(Icons.attach_file, size: 14, color: C.fg3),
        ]),
      ),
    );
  }

  String _accountTag(MailListItem item) {
    final domain = item.accountEmail.contains('@') ? item.accountEmail.split('@')[1] : item.accountEmail;
    final same = _accounts.where((a) => (a.email.contains('@') ? a.email.split('@')[1] : a.email) == domain).length > 1;
    return same ? item.accountEmail : domain;
  }

  Widget _avatar(CloudlyApi api, MailListItem item) {
    final domain = _domainOf(item.fromAddr);
    final letter = (item.fromName ?? item.fromAddr ?? '?').isNotEmpty ? (item.fromName ?? item.fromAddr ?? '?')[0].toUpperCase() : '?';
    if (domain == null) return _letterAvatar(letter);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 36,
        height: 36,
        child: CachedNetworkImage(
          imageUrl: api.faviconUrl(domain),
          httpHeaders: api.authHeaders,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _letterAvatar(letter),
        ),
      ),
    );
  }

  Widget _letterAvatar(String letter) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: C.surface3, shape: BoxShape.circle),
      child: Text(letter, style: const TextStyle(color: C.fg2, fontSize: 16)),
    );
  }

  String? _domainOf(String? addr) {
    if (addr == null) return null;
    final i = addr.lastIndexOf('@');
    if (i <= 0 || i == addr.length - 1) return null;
    return addr.substring(i + 1).toLowerCase();
  }
}

// ---------- просмотр письма ----------

class MailViewerScreen extends ConsumerStatefulWidget {
  final String messageId;
  final bool inTrash;
  const MailViewerScreen({super.key, required this.messageId, required this.inTrash});

  @override
  ConsumerState<MailViewerScreen> createState() => _MailViewerScreenState();
}

class _MailViewerScreenState extends ConsumerState<MailViewerScreen> {
  MailMessageView? _msg;
  Map<String, dynamic>? _body;
  String? _error;
  bool _busy = false;
  /// Показываем текстовую версию вместо разметки: у рассылок, которые и в браузере едут,
  /// читаемый выход важнее оформления.
  bool _asText = false;
  /// Была ли у письма версия с разметкой: по ней решаем, показывать ли переключатель.
  bool _hasHtml = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(appStateProvider).api;
    try {
      final m = await api.mailMessage(widget.messageId);
      if (mounted) setState(() => _msg = m);
      if (!m.seen) {
        api.mailSetSeen(m.id, true).catchError((_) {});
      }
      await _loadBody();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Тело письма в нужной версии: разметка или текст. Картинки разрешены всегда — трекеры
  /// тут не новость, а без картинок письмо не прочитать; подробности — в src/mail/mail-html.ts.
  Future<void> _loadBody() async {
    final api = ref.read(appStateProvider).api;
    final b = await api.mailBody(widget.messageId, true, text: _asText);
    if (!mounted) return;
    setState(() {
      _body = b;
      if (!_asText && b['kind'] == 'html') _hasHtml = true;
    });
  }

  Future<void> _toggleText() async {
    setState(() => _asText = !_asText);
    try {
      await _loadBody();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _reply(String mode) async {
    final m = _msg;
    if (m == null) return;
    try {
      final ctx = await ref.read(appStateProvider).api.mailReplyContext(m.id, mode);
      if (!mounted) return;
      final accounts = await ref.read(appStateProvider).api.mailAccounts();
      if (!mounted) return;
      final sent = await Navigator.push<bool>(context, MaterialPageRoute(
        builder: (_) => MailComposerScreen(accounts: accounts, context_: ctx),
      ));
      if (sent == true) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _delete() async {
    final m = _msg;
    if (m == null) return;
    final ok = await confirmDialog(context, 'Удалить письмо?', 'Оно уйдёт в корзину.', danger: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.mailDelete(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final m = _msg;
    if (m == null) return;
    try {
      await ref.read(appStateProvider).api.mailRestore(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  Future<void> _purgeForever() async {
    final m = _msg;
    if (m == null) return;
    final ok = await confirmDialog(context, 'Удалить навсегда?', 'Вернуть письмо будет нельзя.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.mailPurgeMessage(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _msg;
    final api = ref.read(appStateProvider).api;
    final files = m == null ? const <MailAttachment>[] : m.attachments.where((a) => !a.inline).toList();
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: C.fg), onPressed: () => Navigator.pop(context)),
        title: Text(m == null ? 'Письмо' : fullDate(DateTime.parse(m.sortAt ?? DateTime.now().toIso8601String())),
            style: const TextStyle(color: C.fg3, fontSize: 14)),
        actions: [
          if (_hasHtml)
            IconButton(
              tooltip: _asText ? 'Показать письмо' : 'Показать как текст',
              icon: Icon(_asText ? Icons.html : Icons.notes, color: C.fg),
              onPressed: _busy ? null : _toggleText,
            ),
          if (m != null && !widget.inTrash) ...[
            IconButton(tooltip: 'Ответить', icon: const Icon(Icons.reply, color: C.fg), onPressed: () => _reply('reply')),
            IconButton(tooltip: 'Ответить всем', icon: const Icon(Icons.reply_all, color: C.fg), onPressed: () => _reply('replyAll')),
            IconButton(tooltip: 'Переслать', icon: const Icon(Icons.forward, color: C.fg), onPressed: () => _reply('forward')),
          ],
          if (m != null)
            IconButton(
              tooltip: 'Скачать .eml',
              icon: const Icon(Icons.download, color: C.fg),
              onPressed: () => _downloadRaw(api, m.id),
            ),
          if (m != null && widget.inTrash) ...[
            IconButton(tooltip: 'Восстановить', icon: const Icon(Icons.restore, color: C.fg), onPressed: _restore),
            IconButton(tooltip: 'Удалить навсегда', icon: const Icon(Icons.delete_forever_outlined, color: C.danger), onPressed: _purgeForever),
          ] else if (m != null)
            IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.fg), onPressed: _busy ? null : _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
          if (m == null && _error == null)
            const Center(child: CircularProgressIndicator())
          else if (m != null) ...[
            Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.subject ?? '(без темы)', style: const TextStyle(color: C.fg, fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('${m.fromName ?? m.fromAddr ?? 'без отправителя'}${m.fromName != null && m.fromAddr != null ? ' <${m.fromAddr}>' : ''}',
                  style: const TextStyle(color: C.fg2, fontSize: 13)),
              Text('кому: ${[...m.toAddrs, ...m.ccAddrs].join(', ')}', style: const TextStyle(color: C.fg3, fontSize: 12)),
              Text('аккаунт: ${m.accountEmail}', style: const TextStyle(color: C.fg3, fontSize: 12)),
            ])),
            const SizedBox(height: 8),
            if (_body == null)
              const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
            else
              // Тело письма — в системном WebView: разметка рассылок (таблицы, медиазапросы,
              // inline-стили) рассчитана на браузерный движок, а не на виджеты Flutter.
              // Обе версии — и разметка, и текст в `<pre>` от сервера — идут одной дорогой.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: MailBodyWeb(_body!['html'] as String? ?? ''),
              ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 8),
              Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Вложения (${files.length})', style: const TextStyle(color: C.fg3, fontSize: 13)),
                ...files.map((a) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.attach_file, color: C.fg3),
                  title: Text(a.name, style: const TextStyle(color: C.fg, fontSize: 14)),
                  subtitle: Text('${fmtSize(a.size)} · ${a.mime}', style: const TextStyle(color: C.fg3, fontSize: 12)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.open_in_new, color: C.accent), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FileDetailScreen(entryId: a.entryId)))),
                    IconButton(icon: const Icon(Icons.download, color: C.fg), onPressed: () => downloadAndOpen(api, a.entryId, a.name)),
                  ]),
                )),
              ])),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _downloadRaw(CloudlyApi api, String id) async {
    await downloadAndOpen(api, id, 'message.eml');
  }
}

// ---------- форма письма ----------

class MailComposerScreen extends ConsumerStatefulWidget {
  final List<MailAccountRow> accounts;
  final MailReplyContext? context_;
  const MailComposerScreen({super.key, required this.accounts, this.context_});

  @override
  ConsumerState<MailComposerScreen> createState() => _MailComposerScreenState();
}

class _MailComposerScreenState extends ConsumerState<MailComposerScreen> {
  late String _accountId;
  late final _to = TextEditingController(text: widget.context_?.to ?? '');
  late final _cc = TextEditingController(text: widget.context_?.cc ?? '');
  late final _subject = TextEditingController(text: widget.context_?.subject ?? '');
  late final _text = TextEditingController(text: widget.context_?.body ?? '');
  late bool _ccOpen = (widget.context_?.cc.isNotEmpty ?? false);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _accountId = widget.context_?.accountId ??
        widget.accounts.where((a) => a.enabled).firstOrNull?.id ??
        widget.accounts.firstOrNull?.id ??
        '';
  }

  @override
  void dispose() {
    _to.dispose();
    _cc.dispose();
    _subject.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final attachments = widget.context_?.attachments.map((a) => a.entryId).toList() ?? const <String>[];
      final res = await ref.read(appStateProvider).api.mailSend({
        'accountId': _accountId,
        'to': _to.text.trim(),
        'cc': _cc.text.trim(),
        'subject': _subject.text.trim(),
        'text': _text.text,
        if (widget.context_?.inReplyToId != null) 'inReplyToId': widget.context_!.inReplyToId,
        'attachEntryIds': attachments,
      });
      final rejected = (res['rejected'] as List? ?? const []).cast<String>();
      if (rejected.isNotEmpty) {
        if (mounted) setState(() => _error = 'не приняты адреса: ${rejected.join(', ')}');
      } else {
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.accounts.where((a) => a.enabled).toList();
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        backgroundColor: C.canvas,
        leading: IconButton(icon: const Icon(Icons.close, color: C.fg), onPressed: () => Navigator.pop(context)),
        title: const Text('Письмо', style: TextStyle(color: C.fg, fontSize: 16)),
        actions: [
          FilledButton(
            onPressed: (_busy || _to.text.trim().isEmpty || _accountId.isEmpty) ? null : _send,
            child: _busy ? const Text('Отправляем…') : const Text('Отправить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (enabled.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'откуда'),
              items: enabled.map((a) => DropdownMenuItem(value: a.id, child: Text(a.email))).toList(),
              onChanged: (v) => setState(() => _accountId = v ?? _accountId),
            ),
          TextField(controller: _to, decoration: const InputDecoration(labelText: 'кому'), autocorrect: false),
          const SizedBox(height: 8),
          if (_ccOpen)
            TextField(controller: _cc, decoration: const InputDecoration(labelText: 'копия'), autocorrect: false)
          else
            TextButton(onPressed: () => setState(() => _ccOpen = true), child: const Text('+ копия')),
          TextField(controller: _subject, decoration: const InputDecoration(labelText: 'тема')),
          const SizedBox(height: 8),
          TextField(controller: _text, minLines: 10, maxLines: null, decoration: const InputDecoration(hintText: 'текст письма')),
          if ((widget.context_?.attachments ?? const []).isNotEmpty) ...[
            const SizedBox(height: 8),
            Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Вложения (${widget.context_!.attachments.length})', style: const TextStyle(color: C.fg3, fontSize: 13)),
              ...widget.context_!.attachments.map((a) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.attach_file, color: C.fg3),
                title: Text(a.filename, style: const TextStyle(color: C.fg, fontSize: 14)),
                subtitle: Text(fmtSize(a.size), style: const TextStyle(color: C.fg3, fontSize: 12)),
              )),
            ])),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: C.danger)),
          ],
        ],
      ),
    );
  }
}
