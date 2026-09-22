import 'dart:async';
import 'dart:math' as math;

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
import 'mail_row.dart';
import 'mail_search_screen.dart';
import 'mail_translate.dart';

/// Базовая высота строки письма — до поправки на системный размер шрифта.
///
/// Само число живёт в `mail_row.dart` (`mailRowBase`): строку рисуют и лента, и поиск, и высота
/// у них обязана совпадать. Здесь важна вторая роль этой высоты — не вёрстка, а расчёт:
/// по ней считаются индексы видимой части списка, потому что список на десятки тысяч писем
/// строится целиком, а данные приходят только для строк, попавших в окно (`_fetchVisible`).
/// Поэтому `itemExtent` и расчёт окна обязаны брать одно и то же число — фактическое, из `_rowH`.
const _rowBase = mailRowBase;

/// Сколько строк письма просит одна порция `mailRange`.
///
/// 200 — меньше серверного потолка (`MAIL_RANGE_MAX = 500`, src/mail/mail-feed.service.ts) и
/// выбрано под вес строки: в письме отправитель, тема и тег аккаунта, а видимое окно при
/// высоте строки 52 — это больше десяти строк, так что порции с запасом хватает и на окно,
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
  /// `null` — ответа ещё не было: список пуст, индикатора загрузки у экрана нет.
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
  /// Идёт необратимая операция над папкой (очистка корзины): блокирует повторное нажатие.
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
    _rowH = MediaQuery.textScalerOf(context).scale(_rowBase);
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
  /// красным текстом по центру экрана, а если список уже на экране — полоской снизу, чтобы данные
  /// не пропадали из-за неудачного фонового обновления.
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
  /// на каждое движение, заметно больше — пустые строки висели бы на глазах.
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
  /// Слоты, которые ещё не пришли, остаются пустыми: `_row` возвращает для них пустой виджет,
  /// а место под строку уже занято `itemExtent`, поэтому список не прыгает, когда ответ доехал.
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

  /// Обновление списка жестом «потянуть вниз» — единственный способ обновить почту с экрана.
  ///
  /// Отдельного прохода по IMAP тут нет — сервер держит IDLE и складывает письма в базу сам,
  /// поэтому достаточно перечитать счётчики. Полная синхронизация с почтовым сервером осталась
  /// кнопкой «Проверить» в настройках (`mailSync`).
  ///
  /// Кнопки обновления у экрана нет намеренно: она дублировала жест, а её спиннер был ещё одним
  /// индикатором загрузки на экране. Ошибку показывает `_loadCounters` — полоской снизу, если
  /// список уже на экране, и текстом, если показывать больше нечего.
  Future<void> _refresh() => _loadCounters();

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

  /// Открывает поиск по письмам.
  ///
  /// Поиск идёт ровно в той папке, которую смотрит пользователь (так решил владелец: «ищу там,
  /// где нахожусь»), поэтому папка передаётся параметром, а не выбирается внутри поиска.
  ///
  /// Отдельный экран, а не режим этого: список здесь виртуальный, по `itemExtent` и абсолютным
  /// индексам, и подмешивать в него вторую модель выдачи — значит сломать и то, и другое.
  ///
  /// После возврата список перечитывается — как и после открытия письма ([_openMessage]):
  /// из поиска письмо могли открыть и прочитать, а счётчик непрочитанных и вес шрифта в строках
  /// живут на этом экране и о чужой правке не знают. Возврат без единого открытого письма тоже
  /// перечитывает счётчики: отличить этот случай от «открыл и прочитал» отсюда нечем, а лишний
  /// запрос дешевле, чем строка, которая выглядит непрочитанной после того, как её прочли.
  void _openSearch() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => MailSearchScreen(box: _box),
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
        // Список «Исходящих» ещё не загружен: пока не пришёл счётчик, экран пуст, а не
        // показывает строки прежней папки (индексы у папок свои).
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
        // В заголовке — открытая папка, а не три иконки подряд: папки переключаются баром из
        // иконки в шапке (как разделы фактур), и на узком экране одна подпись читается лучше,
        // чем три пиктограммы, значение которых надо угадывать.
        title: Text(_boxLabel(_box), style: const TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          if (_box == 'trash' && (t ?? 0) > 0)
            IconButton(tooltip: 'Очистить корзину', icon: const Icon(Icons.delete_sweep_outlined, color: C.fg), onPressed: _busy ? null : _emptyTrash),
          IconButton(
            tooltip: 'Поиск по письмам',
            icon: const Icon(Icons.search, color: C.fg),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: 'Написать письмо',
            icon: const Icon(Icons.edit_outlined, color: C.fg),
            onPressed: _accounts.any((a) => a.enabled) ? () => _openCompose() : null,
          ),
          IconButton(
            tooltip: 'Папки почты',
            icon: const Icon(Icons.grid_view, color: C.fg),
            onPressed: _openFoldersMenu,
          ),
        ],
      ),
      // Обновление — только жестом «потянуть вниз»: своей кнопки у экрана нет.
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _list(t, api),
      ),
    );
  }

  /// Тело экрана: ошибка, пустая папка или список писем.
  ///
  /// Всё это — прокручиваемые списки, даже когда показывать нечего: `RefreshIndicator` работает
  /// только на прокручиваемом содержимом, и на непрокручиваемом виджете жест «потянуть вниз»
  /// не сработал бы — то есть после сбоя обновить список было бы нечем.
  ///
  /// Спиннера первой загрузки здесь больше нет: пока ответа нет, экран пуст. Так просил
  /// владелец — лишних индикаторов на экране быть не должно, а на быстром соединении спиннер
  /// всё равно не успевают заметить. Ошибка при этом показывается текстом: пустой экран без
  /// объяснения выглядел бы как «почты нет».
  Widget _list(int? t, CloudlyApi api) {
    if (_error != null && t == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          Center(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
          )),
        ],
      );
    }
    if (t == null || t == 0) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 100),
          if (t == 0)
            Center(child: Text(
              _box == 'inbox' ? 'Входящих пока нет' : _box == 'sent' ? 'Исходящих пока нет' : 'Корзина пуста',
              style: const TextStyle(color: C.fg3),
            )),
        ],
      );
    }
    return ListView.builder(
      controller: _sc,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: t,
      itemExtent: _rowH,
      itemBuilder: (context, i) => _row(api, i),
    );
  }

  /// Подпись папки: в заголовке экрана и в баре папок — одна и та же функция `mailBoxLabel`
  /// из `mail_row.dart`, поэтому поиск называет папку теми же словами.
  String _boxLabel(String id) => mailBoxLabel(id);

  /// Открывает бар папок почты — тот же приём, что у разделов фактур.
  ///
  /// Папок три, и переключение между ними — не переход на другой экран, а смена содержимого
  /// этого же: список, счётчик и прокрутка у каждой папки свои, поэтому бар только выбирает
  /// папку, а показывает её тот же экран. Открытая папка в баре выключена и подписана «Текущая
  /// папка» — так видно, где находишься, и не приходится нажимать пункт, который ничего не меняет.
  Future<void> _openFoldersMenu() async {
    const folders = <(String, IconData, String)>[
      ('inbox', Icons.inbox_outlined, 'Письма, которые вам пришли'),
      ('sent', Icons.send_outlined, 'Отправленные вами'),
      ('trash', Icons.delete_outline, 'Удалённые письма: можно вернуть'),
    ];
    final target = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (id, icon, hint) in folders)
              ListTile(
                leading: Icon(icon, color: _box == id ? C.accent : C.fg3),
                title: Text(_boxLabel(id)),
                subtitle: Text(_box == id ? 'Текущая папка' : hint),
                enabled: _box != id,
                onTap: () => Navigator.pop(ctx, id),
              ),
          ],
        ),
      ),
    );
    // `null` — бар закрыли, не выбрав папку; выбор той же папки ничего не перечитывает.
    if (target == null || !mounted || target == _box) return;
    _switchBox(target);
  }

  /// Переключает открытую папку.
  ///
  /// `_total` и `_items` сбрасываются ещё до запроса: индексы у папок свои, и до нового счётчика
  /// показывать строки прежней папки нельзя — «письмо №5 во входящих» и «письмо №5 в корзине»
  /// это разные записи. Пока счётчика нет, список пуст.
  void _switchBox(String id) {
    setState(() {
      _box = id;
      _total = null;
      _items.clear();
    });
    // Новый запрос поднимет поколение, и ответы прежней папки (счётчик и уже запрошенные
    // порции строк) будут отброшены по `gen != _gen`.
    _loadCounters();
  }

  /// Строка письма по абсолютному индексу.
  ///
  /// Строка, которой ещё нет в `_items`, рисуется пустой: место под неё уже занято
  /// (`itemExtent`), поэтому список не прыгает, когда данные доедут, а серых заглушек и
  /// спиннеров на месте писем в приложении нет намеренно — незагруженная строка выглядит
  /// просто пустой, а не «письмом, которое вот-вот нарисуется».
  /// [api] приходит из `build`: строка строится на каждый кадр, и читать провайдер здесь значило
  /// бы читать его на каждую строку.
  ///
  /// Вёрстка строки — в `MailRow` (`mail_row.dart`): та же строка рисуется в выдаче поиска,
  /// и вторая её копия здесь разошлась бы с первой при первой же правке.
  Widget _row(CloudlyApi api, int i) {
    final item = _items[i];
    if (item == null) return const SizedBox.shrink();
    return MailRow(
      api: api,
      item: item,
      accounts: _accounts,
      onTap: () => _openMessage(item.id),
    );
  }
}

// ---------- просмотр письма ----------

/// Просмотр письма: шапка, карточка с телом и вложения.
///
/// Тело приходит с сервера уже очищенным (см. src/mail/mail-html.ts) и рисуется в WebView —
/// почему именно так, написано в `MailBodyWeb`. Здесь решается, что делать с письмом (ответ,
/// пересылка, скачивание `.eml`, удаление в корзину; в корзине — восстановление и удаление
/// навсегда) и как разложить экран.
///
/// Раскладка: письмо прокручивается **внутри карточки**, а не вместе со страницей. Отправитель
/// и тема живут в шапке, «кому» и аккаунт — строкой над карточкой, вложения — строкой чипов там
/// же. Всё это не прокручивается вовсе, поэтому отправитель виден всегда, а письмо занимает ровно
/// ту часть экрана, что осталась, и не уезжает под системную навигацию Android.
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

/// Состояние просмотрщика: письмо, его тело и флаги показа.
class _MailViewerScreenState extends ConsumerState<MailViewerScreen> {
  MailMessageView? _msg;
  /// Тело от сервера: разметка приходит готовым документом в поле `html`.
  Map<String, dynamic>? _body;
  String? _error;
  /// Идёт операция над письмом (удаление): блокирует повторные нажатия.
  bool _busy = false;
  /// Сервер отдал не весь текст письма (взял превью из базы, потому что исходник не разобрался):
  /// об этом надо сказать, иначе обрезанное письмо читается как полное.
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

  /// Тело письма — всегда полная разметка, вместе с картинками по ссылке.
  ///
  /// Раньше картинки по ссылке не грузились до явного согласия: картинка по ссылке — это трекер,
  /// по которому отправитель узнаёт, что письмо открыли, когда и с какого адреса
  /// (src/mail/mail-html.ts). Кнопка «показать картинки» и счёт неотданных картинок убраны по
  /// решению владельца: письмо должно выглядеть как задумано, а не как набор пустых рамок, и
  /// лишних кнопок на экране быть не должно.
  ///
  /// Версии «как текст» здесь тоже больше нет: сервер умеет отдавать текстовую версию, но
  /// переключателя в приложении нет — письмо показывается так, как его сверстали.
  Future<void> _loadBody() async {
    final api = ref.read(appStateProvider).api;
    final b = await api.mailBody(widget.messageId);
    if (!mounted) return;
    setState(() {
      _body = b;
      _truncated = b['truncated'] == true;
    });
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

  /// Открывает модалку с переводом письма на русский.
  ///
  /// Запрос уходит уже из самой модалки (см. [MailTranslationSheet]): перевод идёт десятки
  /// секунд, и открывать её сразу с индикатором честнее, чем ждать ответа на экране письма без
  /// единого признака работы. `backgroundColor` и скругление заданы тут, потому что цвета и форма
  /// модалки — дело экрана, а не её содержимого.
  Future<void> _translate() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: C.canvas,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => MailTranslationSheet(messageId: widget.messageId),
      );

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
        // Отправитель — в шапке: письмо прокручивается внутри карточки, и всё, что стояло бы над
        // ней в прокручиваемой части, уезжало бы вверх. В шапке отправитель виден всегда.
        title: Text(_sender(m),
            style: const TextStyle(color: C.fg, fontSize: 16),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          if (m != null) ...[
            IconButton(
              tooltip: 'Перевести на русский',
              icon: const Icon(Icons.translate, color: C.fg),
              onPressed: _translate,
            ),
            if (!widget.inTrash) ...[
              IconButton(tooltip: 'Ответить', icon: const Icon(Icons.reply, color: C.fg), onPressed: () => _reply('reply')),
              IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.fg), onPressed: _busy ? null : _delete),
            ],
            if (widget.inTrash) ...[
              IconButton(tooltip: 'Восстановить', icon: const Icon(Icons.restore, color: C.fg), onPressed: _restore),
              IconButton(tooltip: 'Удалить навсегда', icon: const Icon(Icons.delete_forever_outlined, color: C.danger), onPressed: _purgeForever),
            ],
          ],
          // Остальные действия — в меню: в шапке стоит отправитель, и четыре-пять иконок рядом
          // с подписью оставляли бы от неё считанные буквы.
          if (m != null)
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              onSelected: (v) => switch (v) {
                'replyAll' => _reply('replyAll'),
                'forward' => _reply('forward'),
                _ => _downloadRaw(api, m.id),
              },
              itemBuilder: (_) => [
                if (!widget.inTrash) ...[
                  const PopupMenuItem(value: 'replyAll', child: Text('Ответить всем')),
                  const PopupMenuItem(value: 'forward', child: Text('Переслать')),
                ],
                const PopupMenuItem(value: 'eml', child: Text('Скачать .eml')),
              ],
            ),
        ],
      ),
      // Экран — колонка из неподвижной части (тема, кому, аккаунт, вложения) и карточки с письмом,
      // которая занимает всё оставшееся место и прокручивается сама. Отступ снизу — системная
      // навигация Android: карточка кончается над полосой, и под ней ничего не просвечивает,
      // даже когда письмо внутри карточки доехало до конца.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m != null) _header(m),
          // Текст пришёл не целиком: сервер отдал превью из базы, потому что исходник
          // не разобрался. Молчать об этом нельзя — обрезанное письмо читается как полное.
          if (_truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('Письмо показано не полностью: остальное не удалось разобрать.',
                  style: const TextStyle(color: C.fg3, fontSize: 12)),
            ),
          if (files.isNotEmpty) _attachments(files),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, 8 + navBarInset(context)),
              child: _bodyCard(),
            ),
          ),
        ],
      ),
    );
  }

  /// Отправитель письма для шапки: имя и адрес, если имя есть.
  ///
  /// Подпись та же, что в списке и в блоке над карточкой, — письмо должно узнаваться по одной
  /// и той же строке, а не по трём разным.
  String _sender(MailMessageView? m) {
    if (m == null) return 'Письмо';
    final name = m.fromName?.trim() ?? '';
    final addr = m.fromAddr?.trim() ?? '';
    if (name.isEmpty) return addr.isEmpty ? 'без отправителя' : addr;
    return addr.isEmpty ? name : '$name <$addr>';
  }

  /// Неподвижная часть над карточкой: тема, кому и в какой аккаунт пришло письмо.
  ///
  /// Письмо прокручивается внутри карточки, поэтому всё это видно всё время чтения — в отличие
  /// от прежней раскладки, где шапка уезжала вверх вместе со списком.
  Widget _header(MailMessageView m) {
    final date = m.sortAt == null ? '' : fullDate(DateTime.parse(m.sortAt!));
    final subject = m.subject?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(subject.isEmpty ? '(без темы)' : subject,
            style: const TextStyle(color: C.fg, fontSize: 15, fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text('кому: ${[...m.toAddrs, ...m.ccAddrs].join(', ')}',
            style: const TextStyle(color: C.fg3, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        Text('аккаунт: ${m.accountEmail}${date.isEmpty ? '' : ' · $date'}',
            style: const TextStyle(color: C.fg3, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  /// Вложения — строкой чипов над карточкой.
  ///
  /// Раньше это была панель со списком (имя, размер и две кнопки на каждое вложение) и стояла она
  /// под телом письма; теперь тело занимает всё место до низа экрана, и панель отнимала бы у него
  /// половину высоты. Нажатие открывает запись файла: там и предпросмотр, и скачивание.
  Widget _attachments(List<MailAttachment> files) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = files[i];
          return ActionChip(
            avatar: const Icon(Icons.attach_file, size: 16, color: C.fg3),
            label: Text('${a.name} · ${fmtSize(a.size)}',
                style: const TextStyle(color: C.fg, fontSize: 12)),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => FileDetailScreen(entryId: a.entryId))),
          );
        },
      ),
    );
  }

  /// Карточка с телом письма: та же форма, что у панелей приложения (скругление и рамка),
  /// только внутри не виджеты, а документ письма.
  ///
  /// Белая подложка нужна с двух сторон. Сама карточка белая, чтобы за документом не просвечивал
  /// тёмный фон приложения, а `MailBodyWeb` белит ещё и `html`/`body` самого документа и делает
  /// это с `!important`: у части писем подложка подписана своим цветом, и без веса наше правило
  /// проигрывало — письмо с чёрным текстом оказывалось на чёрном фоне.
  ///
  /// `clipBehavior` обязателен: без него прямоугольный документ вылезал бы за скруглённые углы.
  Widget _bodyCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.brd),
      ),
      clipBehavior: Clip.antiAlias,
      child: switch ((_error, _body)) {
        (final String e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(e, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
            ),
          ),
        // Пока тела нет, карточка пустая: индикатора загрузки на экране письма нет — лишних
        // индикаторов в приложении быть не должно, а пустая белая карточка честно показывает,
        // что письмо ещё едет.
        (_, null) => const SizedBox.shrink(),
        (_, final Map<String, dynamic> b) => MailBodyWeb(b['html'] as String? ?? ''),
      },
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
      // Низ формы — под системной навигацией Android: у формы нет нижней панели приложения,
      // а свой `padding` у списка выключает автоматический системный отступ.
      body: ListView(
        padding: EdgeInsets.fromLTRB(14, 14, 14, 14 + navBarInset(context)),
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
