import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
// kDebugMode приходит из foundation: material его больше не реэкспортирует, а без него
// отладочную печать в проглатываемой ошибке пришлось бы либо печатать всегда, либо убрать.
import 'package:flutter/foundation.dart';
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

/// Базовая высота строки письма — до поправки на системный размер шрифта.
///
/// Высота фиксирована (`itemExtent`) и служит не только вёрстке: по ней считаются индексы
/// видимой части — список на десятки тысяч писем строится целиком, а данные приходят только для
/// строк, попавших в окно (`_fetchVisible`). Поэтому `itemExtent` и расчёт окна обязаны брать
/// одно и то же число — фактическое, из `_rowH`, а не эту константу.
const _rowBase = 76.0;

/// Базовая высота заглушки строки (серый прямоугольник на месте не приехавшего письма).
///
/// Ниже настоящей строки: заглушка держит место, чтобы список не прыгал, когда данные доедут,
/// и ничего из себя не изображает.
const _skeletonBase = 52.0;

/// Сколько строк письма просит одна порция `mailRange`.
///
/// 200 — меньше серверного потолка (`MAIL_RANGE_MAX = 500`, src/mail/mail-feed.service.ts) и
/// выбрано под вес строки: в письме отправитель, тема, превью и тег аккаунта, а видимое окно при
/// высоте строки 76 — это около десяти строк, так что порции с большим запасом хватает и на окно,
/// и на несколько следующих остановок скролла.
const _rangeChunk = 200;

/// Запас строк сверху и снизу от видимого окна.
///
/// Столько проскакивает инерционный скролл, пока идёт запрос, и столько же остаётся готовым,
/// когда пользователь долистает.
const _overscan = 6;

/// Задержка перед загрузкой видимого окна при скролле (см. `_onScroll`).
const _scrollDebounce = Duration(milliseconds: 400);

/// Экран «Почта»: список писем выбранной папки — входящие, исходящие, корзина.
///
/// Список виртуальный в двух смыслах: сервер знает только общее число (`mailCount`), а
/// содержимое каждой строки приходит отдельным запросом по абсолютному смещению (`mailRange`).
/// Отсюда главное правило файла: `_items` и `_total` описывают **одну** папку `_box`;
/// при переключении вкладки оба сбрасываются, потому что индексы у папок свои.
///
/// Порядок такой же, как в списке: от свежих к старым, поэтому индекс `0` — самое новое письмо.
class MailScreen extends ConsumerStatefulWidget {
  const MailScreen({super.key});

  @override
  ConsumerState<MailScreen> createState() => _MailScreenState();
}

/// Состояние списка: открытая папка, её счётчик, загруженные строки и служебные флаги.
class _MailScreenState extends ConsumerState<MailScreen> {
  /// Открытая папка: `inbox`, `sent` или `trash`. Уходит на сервер в каждом запросе
  /// (`mailCount`, `mailRange`), поэтому это ещё и часть ключа, по которому трактуются
  /// `_total` и `_items`.
  String _box = 'inbox';
  /// Сколько писем в текущей папке — по нему `ListView` считает высоту скролла.
  /// `null` — ответа ещё не было, поэтому вместо списка показывается спиннер.
  int? _total;
  /// Загруженные строки по абсолютному индексу письма.
  ///
  /// Инвариант: ключи относятся к текущей `_box`. Смена папки очищает словарь, потому что
  /// письмо «номер 5 во входящих» и «номер 5 в корзине» — разные записи, а на экране список
  /// строится по индексам, а не по идентификаторам.
  final Map<int, MailListItem> _items = {};
  /// Аккаунты пользователя: нужны для фавиконов в аватарах, подписи аккаунта в строке и
  /// решения, доступна ли кнопка «Написать» (нет включённых аккаунтов — писать не с чего).
  List<MailAccountRow> _accounts = const [];
  String? _error;
  /// Идёт перечитка списка: блокирует кнопку «Проверить» и крутит на ней спиннер.
  bool _busy = false;
  /// Скролл списка: из его позиции считается видимое окно строк.
  final ScrollController _sc = ScrollController();
  /// Задержка перед загрузкой видимого окна (см. `_onScroll`).
  Timer? _debounce;

  /// Поколение данных: растёт с каждым новым запросом счётчиков.
  ///
  /// Ответы приходят не по порядку, а индексы строк у папок свои: пока «Входящие» отвечали,
  /// пользователь мог уйти в «Корзину» и вернуться, и запоздавший ответ вписал бы счётчик и
  /// строки одной папки в состояние другой. Поэтому каждый запрос запоминает своё поколение
  /// (и свою папку) и применяет ответ, только если оно всё ещё текущее.
  int _gen = 0;

  /// Проход по видимым строкам уже идёт.
  ///
  /// Скролл порождает поводы один за другим, и без этого флага два прохода шли бы параллельно,
  /// спрашивая одни и те же строки. Вместо второго запроса помечаем окно уехавшим
  /// ([_fetchAgain]) и делаем ещё один проход после текущего.
  bool _fetching = false;
  /// Во время прохода окно уехало: после него нужен ещё один проход.
  bool _fetchAgain = false;

  /// Высота строки с поправкой на системный размер шрифта — по ней считается видимое окно.
  ///
  /// Строка — это три строки текста фиксированными кеглями, и `itemExtent` обязан расти вместе
  /// с системным шрифтом: иначе при размере больше ~1.3 текст обрезается. Значение обновляется
  /// в [didChangeDependencies] (единственное место, где `MediaQuery` читается правильно), а
  /// `_fetchVisible` берёт его оттуда же — иначе окно разъехалось бы с тем, что видно на экране.
  double _rowH = _rowBase;
  /// То же для заглушки строки: она держит место настоящей строки и растёт вместе с ней.
  double _skeletonH = _skeletonBase;

  @override
  /// Открытие списка: подписка на скролл, аккаунты и первая порция счётчиков.
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _loadAccounts();
    _loadCounters();
  }

  @override
  /// Пересчитывает высоту строки под системный шрифт.
  ///
  /// Делается здесь, а не в `build`: высота нужна и `itemExtent`, и `_fetchVisible`, а поля
  /// состояния нельзя менять во время сборки — при `textScaler` отличном от прежнего виджет
  /// перестраивается, и `didChangeDependencies` вызывается до `build`.
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    _rowH = scaler.scale(_rowBase);
    _skeletonH = scaler.scale(_skeletonBase);
  }

  @override
  /// Уходим с экрана — снимаем задержку и контроллер скролла.
  void dispose() {
    _debounce?.cancel();
    _sc.dispose();
    super.dispose();
  }

  /// Читает аккаунты пользователя.
  ///
  /// Ошибку глотаем: без аккаунтов список писем всё равно показывается, просто вместо фавиконов
  /// будут буквы, а вместо тега аккаунта — домен из адреса. Побочно: перерисовка.
  Future<void> _loadAccounts() async {
    try {
      final a = await ref.read(appStateProvider).api.mailAccounts();
      if (mounted) setState(() => _accounts = a);
    } catch (_) {}
  }

  /// Перечитывает «шапку» папки: число писем — и забывает загруженные строки, чтобы окно
  /// наполнилось заново.
  ///
  /// Сброс нужен потому, что состав папки меняется на сервере (письмо пришло по IDLE, ушло
  /// после отправки, удалено), а локально понять, какие именно строки устарели, нельзя:
  /// индексы сдвигаются. Дешевле перезагрузить видимое окно. Чистка идёт только при успехе:
  /// неудачное обновление не должно оставлять пользователя без уже загруженного списка.
  ///
  /// Ответ применяется, только если папка и поколение всё ещё те, с которых начался запрос
  /// ([_gen]): иначе счётчик одной папки лёг бы в состояние другой.
  ///
  /// Видимое окно запрашивается после кадра (`addPostFrameCallback`): до перестройки у списка
  /// ещё нет ни размеров, ни позиции, и окно посчиталось бы по нулям.
  ///
  /// Ошибка показывается двумя разными способами: если показывать нечего (`_total == null`) —
  /// красным на весь экран, а если список уже на экране — полоской снизу, чтобы данные не
  /// пропадали из-за неудачного фонового обновления.
  Future<void> _loadCounters() async {
    final gen = ++_gen;
    final box = _box;
    try {
      final api = ref.read(appStateProvider).api;
      final n = await api.mailCount(box);
      if (!mounted || gen != _gen || box != _box) return;
      setState(() {
        _total = n;
        _items.clear();
        _error = null;
      });
      // Строки прежнего окна забыты: их принесёт проход по видимой части.
      _fetchAgain = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _gen) _fetchVisible();
      });
    } catch (e) {
      if (!mounted || gen != _gen || box != _box) return;
      if (_total == null) {
        setState(() => _error = e.toString());
      } else {
        // Список на экране: сообщение полоской, а не подменой содержимого.
        snack(context, 'не удалось обновить: $e');
      }
    }
  }

  /// Ставит задержку перед загрузкой видимого окна при каждом событии скролла.
  ///
  /// Событие приходит на каждый кадр прокрутки, и запрос на каждое событие — это десятки
  /// запросов за один флинг. Таймер при этом перезапускается, поэтому `_fetchVisible` уходит
  /// один раз — через [_scrollDebounce] после остановки: инерция успевает закончиться, и запрос
  /// идёт уже за тем окном, где пользователь остался. Меньше 400 мс — запросы пошли бы пачками
  /// на каждое движение, заметно больше — серые заглушки висели бы на глазах.
  void _onScroll() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(_scrollDebounce, _fetchVisible);
  }

  /// Загружает строки, попавшие в видимое окно списка (с запасом сверху и снизу).
  ///
  /// Как считается окно: по позиции скролла и фактической высоте строки берём диапазон индексов,
  /// к нему добавляем по [_overscan] строк запаса с каждой стороны.
  ///
  /// Куски: из диапазона выбираются только непрерывные участки ещё не загруженных строк
  /// (уже загруженные не перезапрашиваются), и каждый участок режется на порции по [_rangeChunk].
  ///
  /// Слоты, которые ещё не пришли, остаются заглушками: `_row` рисует для них серый
  /// прямоугольник той же высоты, поэтому список не прыгает, когда ответ доехал.
  /// Побочно: `setState` с новыми строками.
  ///
  /// Проход один за раз: на время запроса поднимается [_fetching], а пришедшие за это время
  /// поводы (скролл, перечитка) не запускают второй такой же, а отмечаются в [_fetchAgain] —
  /// иначе быстрый скролл порождал параллельные запросы одних и тех же строк. Ответ применяется,
  /// только если папка и поколение те же, с которых проход начался: индексы строк у папок свои,
  /// и запоздавший ответ не должен вписаться в чужой список.
  Future<void> _fetchVisible() async {
    final t = _total;
    if (t == null || t == 0) return;
    if (_fetching) {
      _fetchAgain = true;
      return;
    }
    _fetching = true;
    final gen = _gen;
    final box = _box;
    try {
      final api = ref.read(appStateProvider).api;
      // Список тоже надо наполнить до первого скролла (контроллер может быть ещё не привязан).
      final top = _sc.hasClients ? _sc.offset : 0.0;
      // Высота окна нужна для расчёта; до первой раскладки берём типовой экран телефона.
      final vh = _sc.hasClients ? _sc.position.viewportDimension : 900.0;
      final first = math.max(0, (top / _rowH).floor() - _overscan);
      final last = math.min(t - 1, ((top + vh) / _rowH).ceil() + _overscan);
      if (first > last) return;
      // Непрерывные пропуски: строки, которых ещё нет в `_items`.
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
        for (var off = s; off <= e; off += _rangeChunk) {
          final len = math.min(_rangeChunk, e - off + 1);
          try {
            final page = await api.mailRange(box, off, len);
            if (!mounted || gen != _gen || box != _box) return;
            setState(() {
              // Ключ — абсолютный индекс письма, а не порядок прихода: ответы на разные куски
              // могут прийти вразнобой, и по индексу они всё равно лягут на нужные строки.
              for (var j = 0; j < page.length; j++) {
                _items[off + j] = page[j];
              }
            });
          } catch (e) {
            // Неудачу глотаем: следующий скролл спросит эти же слоты снова, а падать из-за
            // одного запроса список не должен. Печать только в отладке — в релизе сообщать
            // об этом некуда.
            if (kDebugMode) debugPrint('mail range error: $e');
          }
        }
      }
    } finally {
      _fetching = false;
    }
    // Пока шёл запрос, окно могло уехать: один повторный проход накрывает и его.
    if (mounted && gen == _gen && _fetchAgain) {
      _fetchAgain = false;
      await _fetchVisible();
    }
  }

  /// Кнопка «Проверить»: перечитывает список открытой папки.
  ///
  /// Отдельного прохода по IMAP тут нет — сервер держит IDLE и складывает письма в базу сам,
  /// поэтому достаточно перечитать счётчики. Полная синхронизация с почтовым сервером осталась
  /// кнопкой «Проверить» в настройках (`mailSync`).
  /// Ошибку показывает `_loadCounters` (полоской, если список уже на экране), а `_busy` крутит
  /// спиннер на кнопке и блокирует повторные нажатия.
  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _loadCounters();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Очищает корзину почты целиком (безвозвратно — в отличие от удаления письма, которое
  /// только переносит его в корзину). Отмена в диалоге — выход без запроса. Побочно: перечитка
  /// счётчиков, чтобы пустая корзина сразу показалась пустой.
  ///
  /// [_busy] поднимается и здесь: очистка необратима, а двойное нажатие (или нажатие в момент
  /// идущего обновления) отправило бы второй запрос по уже пустой корзине.
  Future<void> _emptyTrash() async {
    if (_busy) return;
    final ok = await confirmDialog(context, 'Очистить корзину почты?', 'Письма будут удалены безвозвратно.', danger: true);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.mailPurgeTrash();
      await _loadCounters();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Открывает письмо в просмотрщике.
  ///
  /// `inTrash` передаётся флагом: в корзине набор действий другой (восстановить и удалить
  /// навсегда вместо ответа и удаления в корзину). После возврата список перечитывается всегда —
  /// письмо оттуда могли удалить, восстановить или оно стало прочитанным.
  ///
  /// Проверка `mounted` обязательна: пока открыт просмотрщик, экран списка мог быть закрыт
  /// (выход из аккаунта, переход в другой раздел), и запрос ушёл бы в мёртвое состояние.
  void _openMessage(String id) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailViewerScreen(messageId: id, inTrash: _box == 'trash'),
    )).then((_) {
      if (mounted) _loadCounters();
    });
  }

  /// Открывает форму письма — новое, ответ, ответ всем или пересылку.
  ///
  /// Что именно писать, решает контекст `ctx`: сервер вернул готовые адресатов, тему,
  /// процитированное тело и вложения, а форма только раскладывает их по полям. Аккаунты
  /// передаются параметром: у формы нет своего запроса, чтобы не мигать пустым списком «откуда».
  ///
  /// Если письмо отправлено (`true`), переключаемся на «Исходящие» — так отправленное видно
  /// сразу, а не после ручного перехода на вкладку. Проверка `mounted` тут не формальность:
  /// форма письма — отдельный маршрут, и списка к моменту возврата может уже не быть.
  ///
  /// Второй параметр контекста назван `context_`, потому что имя `context` занято `BuildContext`.
  void _openCompose({MailReplyContext? ctx}) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailComposerScreen(
        accounts: _accounts,
        context_: ctx,
      ),
    )).then((sent) {
      if (!mounted || sent != true) return;
      setState(() {
        _box = 'sent';
        // Список «Исходящих» ещё не загружен: пока не пришёл счётчик, показывается спиннер,
        // а не счётчик и строки прежней папки (индексы у папок свои).
        _total = null;
        _items.clear();
      });
      _loadCounters();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _total;
    // Клиент берётся один раз на сборку: `_row` вызывается на каждую видимую строку, и чтение
    // провайдера в нём — это чтение на строку на кадр.
    final api = ref.read(appStateProvider).api;
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
        title: Row(children: [
          _boxTab('inbox', Icons.inbox_outlined, 'Входящие'),
          _boxTab('sent', Icons.send_outlined, 'Исходящие'),
          _boxTab('trash', Icons.delete_outline, 'Корзина'),
        ]),
        actions: [
          if (_box == 'trash' && (t ?? 0) > 0)
            IconButton(tooltip: 'Очистить корзину', icon: const Icon(Icons.delete_sweep_outlined, color: C.fg), onPressed: _busy ? null : _emptyTrash),
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
                      itemBuilder: (context, i) => _row(api, i),
                    ),
    );
  }

  /// Вкладка папки в заголовке (входящие, исходящие, корзина).
  ///
  /// Переключение обнуляет `_total` и очищает `_items` ещё до запроса: пока новый счётчик
  /// не пришёл, показывается спиннер, а не список чужой папки (индексы у папок свои).
  Widget _boxTab(String id, IconData icon, String label) {
    final active = _box == id;
    return InkWell(
      onTap: () {
        setState(() {
          _box = id;
          _total = null;
          _items.clear();
        });
        // Новый запрос поднимет поколение, и ответы прежней папки (счётчик и уже запрошенные
        // порции строк) будут отброшены по `gen != _gen`.
        _loadCounters();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Icon(icon, color: active ? C.accent : C.fg3),
      ),
    );
  }

  /// Строка письма по абсолютному индексу.
  ///
  /// Если строка ещё не загружена (`_items[i] == null`) — заглушка той же высоты: список
  /// виртуальный, и заглушка держит место, чтобы скролл не прыгал, когда данные доедут.
  /// [api] приходит из `build`: строка строится на каждый кадр, и читать провайдер здесь значило
  /// бы читать его на каждую строку.
  Widget _row(CloudlyApi api, int i) {
    final item = _items[i];
    if (item == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Container(color: C.surface3, height: _skeletonH, width: double.infinity),
      );
    }
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
                // Жирный шрифт — признак непрочитанного: отдельной точки-индикатора в строке нет,
                // поэтому вес шрифта несёт всю разницу между прочитанным и новым письмом.
                Expanded(
                  child: Text(
                    item.fromName ?? item.fromAddr ?? 'без отправителя',
                    style: TextStyle(color: C.fg, fontSize: 14, fontWeight: item.seen ? FontWeight.w400 : FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Число писем в цепочке: сервер уже свернул переписку в одну строку, и без
                // этой цифры непонятно, что внутри ещё есть письма.
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

  /// Подпись аккаунта в строке: обычно домен, но если на этом домене больше одного аккаунта —
  /// полный адрес.
  ///
  /// Так видно, куда пришло письмо (у пользователя бывает несколько ящиков), и при этом
  /// «@gmail.com» не повторяется в каждой строке, когда ящик один.
  ///
  /// Домен разбирается тем же [_domainOfEmail], что и для фавикона в [_avatar]: разбор адреса
  /// в одном файле должен быть один, иначе «домен» в подписи и домен для иконки разойдутся —
  /// например, на адресе с заглавными буквами или с лишней «собакой».
  String _accountTag(MailListItem item) {
    final domain = _domainOfEmail(item.accountEmail) ?? item.accountEmail;
    final same = _accounts.where((a) => (_domainOfEmail(a.email) ?? a.email) == domain).length > 1;
    return same ? item.accountEmail : domain;
  }

  /// Аватар отправителя: фавикон его домена (сервер сам ходит за ним и кэширует).
  ///
  /// Пока картинки нет или домена у адреса не разобрать — кружок с первой буквой имени:
  /// строка не должна зависеть от чужого сайта и от того, отдал ли он иконку.
  Widget _avatar(CloudlyApi api, MailListItem item) {
    final domain = _domainOfEmail(item.fromAddr);
    final letter = _firstLetter(item.fromName ?? item.fromAddr);
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
          errorWidget: (_, _, _) => _letterAvatar(letter),
        ),
      ),
    );
  }

  /// Первая буква имени для запасного аватара.
  ///
  /// Первым символом берётся графема (`characters`), а не кодовая единица UTF-16: у имени,
  /// начинающегося с эмодзи или составного символа, `[0]` разрезал бы суррогатную пару
  /// и в кружке оказался бы битый глиф. Пустое имя и строка из пробелов дают «?».
  String _firstLetter(String? name) {
    final trimmed = name?.trim() ?? '';
    final chars = trimmed.characters;
    return chars.isEmpty ? '?' : chars.first.toUpperCase();
  }

  /// Запасной аватар: буква на сером кружке. Размер тот же, что у фавикона, — строки не
  /// разъезжаются, когда иконка не пришла.
  Widget _letterAvatar(String letter) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: C.surface3, shape: BoxShape.circle),
      child: Text(letter, style: const TextStyle(color: C.fg2, fontSize: 16)),
    );
  }
}

/// Домен адреса в нижнем регистре или `null`, если адрес пустой или битый (нет «собаки»
/// либо после неё пусто).
///
/// Один разбор на весь файл: домен нужен и для фавикона в аватаре, и для подписи аккаунта
/// в строке, и две разные реализации здесь уже расходились (одна падала на адресе с двумя
/// «собаками», другая считала доменом часть строки после первой). Функция свободная, а не метод
/// состояния: от состояния она не зависит, и её можно проверить тестом без виджета.
String? _domainOfEmail(String? addr) {
  if (addr == null) return null;
  // Последняя «собака»: в local-part она допустима в кавычках, а домен идёт после последней.
  final i = addr.lastIndexOf('@');
  if (i <= 0 || i == addr.length - 1) return null;
  return addr.substring(i + 1).toLowerCase();
}

// ---------- просмотр письма ----------

/// Просмотр письма: шапка, тело и вложения.
///
/// Тело приходит с сервера уже очищенным (см. src/mail/mail-html.ts) и рисуется в WebView —
/// почему именно так, написано в `MailBodyWeb`. Здесь решается, что показывать: разметку или
/// текстовую версию, — и что делать с письмом (ответ, пересылка, скачивание `.eml`,
/// удаление в корзину; в корзине — восстановление и удаление навсегда).
///
/// `inTrash` приходит от списка: от него зависит набор действий в AppBar, а чтение письма
/// и тела у корзины и входящих одинаковое.
class MailViewerScreen extends ConsumerStatefulWidget {
  final String messageId;
  final bool inTrash;
  const MailViewerScreen({super.key, required this.messageId, required this.inTrash});

  @override
  ConsumerState<MailViewerScreen> createState() => _MailViewerScreenState();
}

/// Состояние просмотрщика: письмо, его тело в выбранной версии и флаги показа.
class _MailViewerScreenState extends ConsumerState<MailViewerScreen> {
  MailMessageView? _msg;
  /// Тело от сервера. Разметка приходит готовым документом, текст — тем же полем `html`,
  /// но с текстом внутри `<pre>`, поэтому дорога до отрисовки одна.
  Map<String, dynamic>? _body;
  String? _error;
  /// Идёт операция над письмом (удаление, переключение вида): блокирует повторные нажатия.
  bool _busy = false;
  /// Показываем текстовую версию вместо разметки: у рассылок, которые и в браузере едут,
  /// читаемый выход важнее оформления.
  bool _asText = false;
  /// Была ли у письма версия с разметкой: по ней решаем, показывать ли переключатель.
  bool _hasHtml = false;
  /// Пользователь разрешил грузить внешние картинки письма.
  ///
  /// По умолчанию нет: картинка по ссылке — это трекер, по которому отправитель узнаёт, что
  /// письмо открыли, когда и с какого адреса (src/mail/mail-html.ts). Сервер по флагу `images`
  /// либо оставляет внешние `src`, либо убирает их и считает в `blockedRemote` — по этому счёту
  /// и появляется предложение показать картинки.
  bool _images = false;
  /// Сколько внешних картинок сервер не отдал из-за [_images] == false.
  int _blockedRemote = 0;
  /// Сервер отдал не весь текст письма (взял превью из базы): об этом надо сказать, иначе
  /// «показать как текст» выглядит как потерянное письмо.
  bool _truncated = false;

  @override
  /// Открытие письма: читаем его вместе с телом.
  void initState() {
    super.initState();
    _load();
  }

  /// Читает письмо, отмечает его прочитанным и подтягивает тело.
  ///
  /// Пометка «прочитано» уходит без ожидания и с проглоченной ошибкой: если она не пройдёт,
  /// письмо просто останется непрочитанным, а показ от этого зависеть не должен.
  /// Ошибка самого чтения идёт в `_error` — тело в этом случае не запрашивается.
  Future<void> _load() async {
    final api = ref.read(appStateProvider).api;
    try {
      final m = await api.mailMessage(widget.messageId);
      if (mounted) setState(() => _msg = m);
      // В корзине пометка серверу не по силам: и `seen`, и `flagged` там требуют
      // `deletedAt: null` и отвечают 404 (src/mail/mail-feed.service.ts). Просить заведомо
      // отказанное незачем — раньше отказ гасился `catchError`, и выглядел он как успех.
      if (!m.seen && m.box != 'trash') {
        api.mailSetSeen(m.id, true).catchError((_) {});
      }
      await _loadBody();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Тело письма в нужной версии: разметка или текст.
  ///
  /// Внешние картинки показываются только после явного согласия ([_images]): пока его нет,
  /// сервер убирает внешние `src` и возвращает их число в `blockedRemote`, а экран предлагает
  /// «показать картинки». Вшитые в письмо (`data:`) картинки приходят всегда — они никуда
  /// не ходят. Подробности — в src/mail/mail-html.ts.
  ///
  /// `_hasHtml` выставляется только при непустой разметке: если сервер отдал текст, переключать
  /// нечего и кнопка «показать как текст» не показывается вовсе.
  Future<void> _loadBody() async {
    final api = ref.read(appStateProvider).api;
    final b = await api.mailBody(widget.messageId, _images, text: _asText);
    if (!mounted) return;
    setState(() {
      _body = b;
      if (!_asText && b['kind'] == 'html') _hasHtml = true;
      _blockedRemote = _images ? 0 : (toNum(b['blockedRemote'])?.toInt() ?? 0);
      _truncated = b['truncated'] == true;
    });
  }

  /// Переключает тело между разметкой и текстом и перезапрашивает его.
  ///
  /// Версия не хранится на клиенте: сервер отдаёт либо разметку, либо текст, поэтому
  /// переключение — это новый запрос. Флаг меняется до запроса (кнопка сразу меняет вид),
  /// а если запрос упал — показывается подсказка, а на экране остаётся прежнее тело.
  Future<void> _toggleText() async {
    setState(() => _asText = !_asText);
    try {
      await _loadBody();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  /// Открывает форму письма как ответ, «ответ всем» или пересылку.
  ///
  /// Что подставить в поля, решает сервер: `mailReplyContext` возвращает адресатов, тему,
  /// процитированное тело и вложения. Аккаунты перечитываются перед открытием формы — список
  /// «откуда» берётся из них, и после правок в настройках он мог поменяться.
  ///
  /// Если письмо отправлено (`true`), закрываем и просмотрщик: список обновится в `MailScreen`.
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
      // Экран мог быть закрыт, пока открыта форма письма: без проверки `pop` ушёл бы
      // в маршрут, который уже не наш.
      if (!mounted) return;
      if (sent == true) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  /// Удаляет письмо — оно уходит в корзину почты, откуда его можно вернуть.
  ///
  /// `_busy` включён на время запроса, чтобы письмо не удалили дважды. Успех закрывает экран
  /// с `true`: строки в списке больше нет.
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

  /// Возвращает письмо из корзины во входящие и закрывает экран с `true` — список перечитается
  /// и письмо появится там, где ему место.
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

  /// Удаляет письмо навсегда (только из корзины). Диалог подчёркивает необратимость: вернуть
  /// после этого нельзя ни из приложения, ни из веб-клиента.
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

  /// Разрешает показ внешних картинок письма и перезапрашивает тело.
  ///
  /// Согласие разовое и живёт в состоянии экрана: это не настройка, а «показать картинки
  /// в этом письме». Тот же смысл у флага `images` у `/mail/messages/:id/body` — до него сервер
  /// сам убирает внешние `src`, поэтому переключать что-то на клиенте нечем: нужен новый запрос.
  Future<void> _showImages() async {
    setState(() => _images = true);
    try {
      await _loadBody();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _msg;
    final api = ref.read(appStateProvider).api;
    // `inline`-вложения (картинки, вшитые в письмо по cid) сервер уже подставил в тело
    // data:-ссылками, поэтому в списке вложений показываем только настоящие файлы.
    final files = m == null ? const <MailAttachment>[] : m.attachments.where((a) => !a.inline).toList();
    return Scaffold(
      backgroundColor: C.canvas,
      appBar: AppBar(
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
            // Внешние картинки не грузились, пока пользователь не согласился: сервер вырезал
            // их из разметки и сказал, сколько было. Показываем это предложением, а не молчанием:
            // без него рассылка выглядит поломанной, а причина (трекеры) не видна.
            if (_blockedRemote > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _showImages,
                  icon: const Icon(Icons.image_outlined, color: C.accent, size: 18),
                  label: Text('Показать картинки из интернета ($_blockedRemote)',
                      style: const TextStyle(color: C.accent, fontSize: 13)),
                ),
              ),
            // Текст пришёл не целиком: сервер отдал превью из базы, потому что письмо
            // не разобралось. Молчать об этом нельзя — обрезанное письмо читается как полное.
            if (_truncated)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Письмо показано не полностью: остальное не удалось разобрать.',
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
              ),
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
                    IconButton(icon: const Icon(Icons.download, color: C.fg), onPressed: () => _download(api, a.entryId, a.name)),
                  ]),
                )),
              ])),
            ],
          ],
        ],
      ),
    );
  }

  /// Скачивает письмо как `.eml` — исходник со всеми заголовками и вложениями. Имя файла
  /// фиксированное: письмо открывается системным почтовым клиентом, и ему важнее расширение,
  /// чем название.
  ///
  /// URL ручки передаём готовым: у исходника письма свой адрес `/mail/messages/:id/raw`,
  /// а `/files/<id>/content` отвечает 404 — id письма не запись файлового дерева. Ключ отсечки
  /// повторных нажатий делаем составным (`mail:<id>`), чтобы он не совпал с id файла.
  Future<void> _downloadRaw(CloudlyApi api, String id) =>
      _download(api, 'mail:$id', 'message.eml', url: api.mailRawUrl(id));

  /// Скачивает запись во временный файл и открывает её; ошибку показывает полоской.
  ///
  /// `downloadAndOpen` возвращает текст ошибки, а не бросает: без показа результат неудачи
  /// выглядел бы как «кнопка не работает».
  Future<void> _download(CloudlyApi api, String entryId, String name, {String? url}) async {
    final problem = await downloadAndOpen(api, entryId, name, url: url);
    if (problem != null && mounted) snack(context, problem);
  }
}

// ---------- форма письма ----------

/// Форма письма: кому, копия, тема, текст и вложения.
///
/// Одна форма на все случаи — новое письмо, ответ, пересылка: различия приходят готовым
/// контекстом `MailReplyContext` от сервера (адресаты, тема, процитированное тело, вложения),
/// и форма только раскладывает его по полям. Аккаунты тоже приходят параметром: своего запроса
/// у формы нет, поэтому список «откуда» не мигает пустотой.
///
/// Возврат: `true` — письмо отправлено (список на экране почты переключается на «Исходящие»),
/// `null` — форму закрыли, ничего не отправив.
class MailComposerScreen extends ConsumerStatefulWidget {
  final List<MailAccountRow> accounts;
  final MailReplyContext? context_;
  const MailComposerScreen({super.key, required this.accounts, this.context_});

  @override
  ConsumerState<MailComposerScreen> createState() => _MailComposerScreenState();
}

/// Состояние формы: контроллеры полей, выбранный аккаунт и признак отправки.
class _MailComposerScreenState extends ConsumerState<MailComposerScreen> {
  /// Аккаунт-отправитель. Начальное значение — из контекста ответа, иначе первый включённый
  /// аккаунт; если включённых нет, остаётся пустая строка, и кнопка отправки заблокирована.
  late String _accountId;
  late final _to = TextEditingController(text: widget.context_?.to ?? '');
  late final _cc = TextEditingController(text: widget.context_?.cc ?? '');
  late final _subject = TextEditingController(text: widget.context_?.subject ?? '');
  late final _text = TextEditingController(text: widget.context_?.body ?? '');
  /// Поле «копия» раскрыто, если копия уже непустая (так приходит «ответ всем»); в остальных
  /// случаях оно спрятано за ссылкой «+ копия», чтобы не занимать место в обычном письме.
  late bool _ccOpen = (widget.context_?.cc.isNotEmpty ?? false);
  bool _busy = false;
  String? _error;

  @override
  /// Выбираем аккаунт-отправителя: из контекста ответа, иначе первый включённый.
  void initState() {
    super.initState();
    _accountId = widget.context_?.accountId ??
        widget.accounts.where((a) => a.enabled).firstOrNull?.id ??
        widget.accounts.firstOrNull?.id ??
        '';
  }

  @override
  /// Контроллеры полей принадлежат виджету — уничтожаем их вместе с ним.
  void dispose() {
    _to.dispose();
    _cc.dispose();
    _subject.dispose();
    _text.dispose();
    super.dispose();
  }

  /// Отправляет письмо: собирает поля формы и вложения из контекста в один запрос.
  ///
  /// `_busy` защищает от второго нажатия: отправку отменить нельзя, а два запроса отправят
  /// письмо дважды. Ответ сервера разбирается на «не принятые» адреса (`rejected`): если такие
  /// есть, форма остаётся открытой с сообщением — иначе пользователь решил бы, что письмо ушло
  /// всем. `inReplyToId` берётся из контекста, чтобы письмо встало в цепочку ответов.
  /// Успех — `Navigator.pop(context, true)`.
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
        leading: IconButton(icon: const Icon(Icons.close, color: C.fg), onPressed: () => Navigator.pop(context)),
        title: const Text('Письмо', style: TextStyle(color: C.fg, fontSize: 16)),
        actions: [
          // Кнопка слушает поле «кому» сама: её доступность зависит от текста, который
          // пользователь печатает, а `build` формы при вводе не перезапускается (у `TextField`
          // нет ни `onChanged`, ни слушателя). Без этого `onPressed` оставался бы `null` до
          // любого постороннего `setState` — и новое письмо отправить было бы нечем.
          // `ValueListenableBuilder` вместо `setState` на каждую букву: перестраивается
          // только кнопка, а не вся форма с полями и вложениями.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _to,
            builder: (_, value, _) => FilledButton(
              // Отправлять нечего без адресата и без аккаунта-отправителя, а во время запроса
              // кнопка выключена, чтобы письмо не ушло дважды.
              onPressed: (_busy || value.text.trim().isEmpty || _accountId.isEmpty) ? null : _send,
              child: _busy ? const Text('Отправляем…') : const Text('Отправить'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // Выбор виден только при нескольких включённых аккаунтах: с одним ящиком это лишнее
          // поле, а `_accountId` и так указывает на него.
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
