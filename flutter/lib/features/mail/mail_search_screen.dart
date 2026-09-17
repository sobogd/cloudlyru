import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/widgets.dart';
import 'mail_row.dart';
import 'mail_screen.dart';

/// Сколько строк просим за одну страницу выдачи.
///
/// Столько же, сколько разрешает сервер (`MAIL_SEARCH_MAX = 50` в src/mail/mail-search.service.ts):
/// строки выдачи — те же строки писем, что и в ленте, а их пользователь долистывает сам.
const _pageSize = 50;

/// Минимум символов в запросе. То же ограничение у сервера: он отвечает ошибкой на более
/// короткий запрос, а клиент до этого просто не доходит — искать по одной букве нечего.
const _minQuery = 2;

/// Выдержка перед запросом после последнего нажатия клавиши.
///
/// Поиск идёт по мере набора, и без выдержки каждая буква отправляла бы свой запрос (а поиск
/// по телу письма — не бесплатный: это GIN-индекс по всему архиву). 350 мс — тот же интервал,
/// что у поиска папок в синхронизации, и он ощущается как «ищет сразу».
const _debounce = Duration(milliseconds: 350);

/// Порог догрузки следующей страницы: сколько остаётся до конца списка, когда она запрашивается.
const _loadMoreThreshold = 400.0;

/// Экран поиска по почте: строка запроса и выдача.
///
/// Ищем по ВСЕМУ телу письма (тело разобрано и лежит в поисковом индексе на сервере), а не
/// только по теме — это и было исходной задачей. Область поиска — открытая папка ([box]):
/// во «Входящих» ищутся входящие, в «Исходящих» — исходящие, в «Корзине» — удалённые. Так решил
/// владелец, и так же устроена лента: поиск — продолжение того списка, который пользователь видит.
///
/// Выдача листается страницами по [_pageSize] с догрузкой по скроллу. Список здесь обычный, а не
/// виртуальный, как лента: у поиска нет ни общей высоты прокрутки (число совпадений известно
/// только после запроса), ни ползунка по месяцам — зато есть живой запрос, который меняется
/// на каждую букву, и пересобирать виртуальный список на каждый такой запрос бессмысленно.
class MailSearchScreen extends ConsumerStatefulWidget {
  const MailSearchScreen({super.key, required this.box});

  /// Папка, в которой ищем: `inbox`, `sent` или `trash`.
  final String box;

  @override
  ConsumerState<MailSearchScreen> createState() => _MailSearchScreenState();
}

/// Состояние поиска: запрос, накопленная выдача и служебные флаги.
class _MailSearchScreenState extends ConsumerState<MailSearchScreen> {
  /// Поле запроса. Слушаем его сами (debounce), а не через `onChanged`, чтобы одна и та же
  /// дорога работала и для нажатия «крестика», которое очищает контроллер.
  final TextEditingController _query = TextEditingController();
  final ScrollController _sc = ScrollController();

  Timer? _debounceTimer;
  /// Отмена предыдущего запроса: поиск идёт по мере набора, и без отмены ответ на прежнюю
  /// (более короткую) строку мог прийти после нового и перебить выдачу.
  CancelToken? _cancel;

  /// Поколение запроса: растёт с каждым новым. Ответ применяется, только если его поколение
  /// всё ещё текущее — так же, как в ленте (`mail_screen.dart`), и по той же причине:
  /// ответы приходят не по порядку.
  int _gen = 0;

  /// Накопленная выдача: строки предыдущих страниц плюс текущая. Порядок — как отдал сервер
  /// (по дате, от свежих к старым), поэтому страницы просто дописываются в конец.
  final List<MailListItem> _items = [];
  /// Сколько всего нашлось — по нему видно, есть ли ещё страницы.
  int _total = 0;
  /// Сколько писем папки ещё не в поисковом индексе (сервер разбирает архив фоном).
  int _pending = 0;
  /// Запрос в работе: по нему показывается «ищу…» и не запускается вторая догрузка.
  bool _loading = false;
  /// Запрос уже отправлялся: до этого на экране подсказка, а не «ничего не нашлось».
  bool _searched = false;
  String? _error;
  /// Аккаунты нужны строке письма для подписи ящика — тот же список, что и в ленте.
  List<MailAccountRow> _accounts = const [];

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    _sc.addListener(_onScroll);
    _loadAccounts();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    // Незавершённый запрос снимаем: экран закрыт, и его ответ уже некому показывать.
    _cancel?.cancel();
    _query.dispose();
    _sc.dispose();
    super.dispose();
  }

  /// Аккаунты пользователя для подписи ящика в строке.
  ///
  /// Ошибку глотаем: без аккаунтов выдача показывается, просто вместо домена будет полный адрес.
  Future<void> _loadAccounts() async {
    try {
      final a = await ref.read(appStateProvider).api.mailAccounts();
      if (mounted) setState(() => _accounts = a);
    } catch (_) {}
  }

  /// Ввод изменился: ставим выдержку и запускаем поиск, не дожидаясь конца набора.
  void _onQueryChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => _search());
  }

  /// Скролл: близко к концу списка — просим следующую страницу.
  void _onScroll() {
    if (!_sc.hasClients || _loading) return;
    final left = _sc.position.maxScrollExtent - _sc.position.pixels;
    if (left <= _loadMoreThreshold) _search(more: true);
  }

  /// Поиск: первая страница или следующая.
  ///
  /// [more] — догрузка: тогда смещение берётся по уже показанным строкам и накопленная выдача
  /// не сбрасывается. Догружать нечего, когда всё уже показано, — такой запрос не отправляем.
  ///
  /// Ответ применяется, только если поколение совпало: пока он шёл, пользователь мог набрать
  /// другое слово, и вписать старую выдачу в новую было бы ошибкой.
  Future<void> _search({bool more = false}) async {
    final q = _query.text.trim();
    if (q.length < _minQuery) {
      // Запрос пропал (стёрли текст) — гасим и выдачу, и возможную догрузку: показывать
      // результаты для строки, которой в поле уже нет, не за что.
      _cancel?.cancel();
      _gen++;
      setState(() {
        _items.clear();
        _total = 0;
        _pending = 0;
        _searched = false;
        _loading = false;
        _error = null;
      });
      return;
    }
    if (more && (_loading || _items.length >= _total)) return;

    final gen = ++_gen;
    final token = CancelToken();
    _cancel?.cancel();
    _cancel = token;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _searched = true;
    });

    try {
      final page = await ref.read(appStateProvider).api.mailSearch(
            widget.box,
            q,
            offset: more ? _items.length : 0,
            limit: _pageSize,
            cancelToken: token,
          );
      if (!mounted || gen != _gen) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(page.items);
        _total = page.total;
        _pending = page.pending;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      // Отменённый запрос — не ошибка: его отменили потому, что строка запроса изменилась
      // или экран закрыли.
      if (e is DioException && CancelToken.isCancel(e)) return;
      // Ошибка при догрузке не должна стирать уже показанную выдачу: строки на экране
      // остаются, а причина уходит полоской снизу. Сообщение показываем после `setState`:
      // внутри него строятся виджеты, и вешать туда показ плашки — значит смешивать
      // состояние с побочным действием.
      final keepList = more && _items.isNotEmpty;
      setState(() {
        _loading = false;
        if (!keepList) _error = e.toString();
      });
      if (keepList) snack(context, 'не удалось догрузить: $e');
    }
  }

  /// Открывает письмо из выдачи.
  ///
  /// `inTrash` — по папке поиска: в корзине у письма другой набор действий. После возврата
  /// строка помечается прочитанной локально: сервер её уже пометил, а перечитывать всю выдачу
  /// из-за одной отметки нельзя — пользователь потерял бы место, до которого долистал.
  Future<void> _openMessage(String id) async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailViewerScreen(messageId: id, inTrash: widget.box == 'trash'),
    ));
    if (!mounted) return;
    final i = _items.indexWhere((m) => m.id == id);
    if (i < 0 || _items[i].seen) return;
    setState(() => _items[i] = _items[i].copyWith(seen: true));
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(appStateProvider).api;
    // Строка-подпись считается один раз на сборку: `_note` зависит от трёх полей состояния,
    // и два её вызова (проверка «есть ли» и вывод) давали бы две разные строки в одном кадре.
    final note = _note();
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        // Поле поиска живёт в заголовке: так у экрана нет второй строки, а клавиатура
        // открывается сразу — экран открывают ради поиска, а не ради списка.
        titleSpacing: 0,
        title: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _query,
          builder: (context, value, _) => TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'поиск по письмам: ${mailBoxLabel(widget.box).toLowerCase()}',
              hintStyle: const TextStyle(color: C.fg3, fontSize: 15),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить',
                      icon: const Icon(Icons.close, size: 18, color: C.fg3),
                      onPressed: () => _query.clear(),
                    ),
            ),
            style: const TextStyle(color: C.fg, fontSize: 15),
          ),
        ),
      ),
      body: Column(children: [
        if (note != null) _noteLine(note),
        Expanded(child: _body(api)),
      ]),
    );
  }

  /// Служебная строка над выдачей: сколько нашлось, идёт ли поиск и сколько архива ещё
  /// не проиндексировано. `null` — показывать нечего (запрос ещё не вводили).
  String? _note() {
    if (!_searched) return null;
    final parts = <String>[];
    if (_loading) {
      parts.add('ищу…');
    } else if (_error == null && _total > 0) {
      // Ноль не показываем: про пустую выдачу уже сказано по центру экрана («Ничего не нашлось»),
      // и «найдено: 0» рядом было бы повтором.
      parts.add('найдено: $_total');
    }
    // Письма, которых поиск ещё не видит: без этой оговорки «не нашлось» выглядит как поломка,
    // а на деле сервер в это время разбирает старый архив (см. mail-index.service.ts).
    if (_pending > 0) parts.add('ещё не в поиске: $_pending');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Строка-подпись над выдачей.
  Widget _noteLine(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 12)),
        ),
      );

  /// Тело экрана: подсказка, ошибка, «ничего не нашлось» или выдача.
  ///
  /// Все состояния — прокручиваемые списки, как и в ленте: пустой экран без объяснения
  /// выглядит как поломка, а короткий текст в прокрутке читается одинаково на любом экране.
  Widget _body(CloudlyApi api) {
    if (!_searched) {
      return _hint('Ищем по всему тексту писем — не только по теме.\nВведите минимум $_minQuery символа.');
    }
    if (_error != null && _items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 60),
        Center(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
        )),
      ]);
    }
    if (_items.isEmpty) {
      // «Ищу…» здесь вместо пустоты: запрос уже отправлен, ответа ещё нет, и пустой экран
      // в этот момент читался бы как «ничего не нашлось».
      return _hint(_loading ? 'ищу…' : 'Ничего не нашлось');
    }
    return ListView.builder(
      controller: _sc,
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) return _footer();
        final item = _items[i];
        return MailRow(
          api: api,
          item: item,
          accounts: _accounts,
          onTap: () => _openMessage(item.id),
        );
      },
    );
  }

  /// Есть ли ещё страницы: сервер сказал, сколько всего нашлось, а мы знаем, сколько показали.
  bool get _hasMore => _items.length < _total;

  /// Последняя строка списка: показывается, только пока есть что догружать.
  ///
  /// Смысл у неё служебный — объяснить, что выдача не кончилась: «показано 50 из 320» честнее
  /// пустого места в конце списка. Догрузка при этом запускается раньше, чем пользователь
  /// доскроллит сюда (см. [_loadMoreThreshold]).
  Widget _footer() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            _loading ? 'ищу…' : 'показано ${_items.length} из $_total',
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
        ),
      );

  /// Подсказка по центру экрана: что делать и почему пока пусто.
  Widget _hint(String text) => ListView(
        // Прокрутка нужна не для содержимого, а для того, чтобы экран вёл себя одинаково
        // с выдачей (та же инерция, те же отступы).
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          Center(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.fg3, fontSize: 13)),
          )),
        ],
      );
}
