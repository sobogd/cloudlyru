import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../media/thumb_cache.dart';
import '../../theme.dart';

/// Плитка галереи: миниатюра кадра, а пока её нет — заглушка по типу файла.
///
/// Миниатюры лежат в хранилище приложения (`ThumbCache`), а не в кэше картинок Flutter, поэтому
/// плитка просит её сама и перерисовывается, когда файл появился на диске. Запрос уходит не в
/// `build`, а с паузой [_settle]: при пролистывании плитки создаются десятками и уезжают за
/// доли секунды, и качать для них миниатюры — значит занять канал тем, чего человек уже
/// не видит (именно из-за этого видимые клетки оставались серыми).
///
/// Скачанная миниатюра тоже показывается не сразу, и это важнее, чем кажется: показ картинки —
/// это декодирование и загрузка текстуры на каждый новый кадр прокрутки, а кэш картинок
/// ограничен, поэтому на быстром листании он превращается в конвейер «декодировать — вытеснить —
/// декодировать». Пока список едет ([scrolling]), клетка показывает заглушку; картинки
/// возвращаются через [_settle] после остановки — вместе с просьбой о тех, которых ещё нет.
/// Так прокрутка не платит ни за сеть, ни за декодирование, и движение не «клюёт» на клетках,
/// которые как раз собрались показать картинку.
///
/// Режим без превью ([previews] = `false`) — тот же случай, но выбранный человеком: плитка
/// не просит ничего вообще и рисует значок по типу файла.
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.item,
    required this.side,
    required this.thumbs,
    required this.scrolling,
    required this.previews,
    required this.onTap,
  });

  /// Кадр, который показывает плитка.
  final MediaItem item;

  /// Сторона клетки в логических пикселях (сетка квадратная).
  final double side;

  /// Очередь миниатюр; `null` — хранилище ещё открывается, показываем заглушку.
  final ThumbCache? thumbs;

  /// Идёт ли прокрутка: `true` — миниатюры не просятся (см. `GalleryController`).
  final ValueListenable<bool> scrolling;

  /// Показывать ли картинку: `false` — клетка рисует значок по типу файла и ничего не качает.
  final bool previews;

  /// Открыть кадр в просмотрщике.
  final VoidCallback onTap;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  /// Пауза после остановки списка, прежде чем показывать картинку и просить недостающие, мс.
  ///
  /// Секунда — не «оптимизация на глаз»: палец замирает на долю секунды между движениями,
  /// и работа, начатая сразу по остановке, приходится на кадр следующего движения. Секунда
  /// такой паузой быть не может, поэтому заминка не показывается человеку.
  static const Duration _settle = Duration(seconds: 1);

  /// Сколько ждать, если просить пока нельзя (хранилище миниатюр ещё открывается).
  static const Duration _retry = Duration(milliseconds: 250);

  Timer? _timer;

  /// Миниатюра уже запрошена — второй раз просить незачем: очередь дедуплицирует по хэшу,
  /// но помнить факт полезно, иначе каждый `build` слал бы запрос заново.
  bool _requested = false;

  /// Миниатюры на диске нет и не будет (сервер ответил 404): просить больше нечего.
  bool _missing = false;

  /// Список стоит и пауза [_settle] прошла: клетке можно показывать картинку.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    widget.scrolling.addListener(_onScrollingChanged);
    // Плитка появилась на стоящем списке (открытие раздела) — показывать можно сразу. Появилась
    // на ходу — до остановки и паузы она заглушка (см. [_onScrollingChanged]).
    if (widget.scrolling.value) {
      _arm(_settle);
    } else {
      _settled = true;
      _request();
    }
  }

  @override
  void didUpdateWidget(GalleryTile old) {
    super.didUpdateWidget(old);
    // Сменился режим показа: прежние «уже просил» и «нет превью» к новому режиму не относятся.
    // Вернули превью — просьбу надо поставить заново, иначе плитка осталась бы заглушкой,
    // пока её не пересоздаст прокрутка.
    if (old.previews != widget.previews) {
      _timer?.cancel();
      _requested = false;
      _missing = false;
      if (widget.previews) _arm(_settle);
      return;
    }
    // Плитку переиспользовали под другой кадр или у того же кадра сменилось состояние превью
    // (опрос `/media/status`): прежние «уже просил» и «нет превью» относятся к прошлому
    // содержимому. Второе важно не меньше первого — плитка, дождавшаяся готовности превью
    // уже после своего появления, без перезапуска просьбы осталась бы серой до перезахода.
    if (old.item.sha256 == widget.item.sha256 && old.item.previewState == widget.item.previewState) {
      return;
    }
    _timer?.cancel();
    _requested = false;
    _missing = false;
    _arm(_settle);
  }

  @override
  void dispose() {
    widget.scrolling.removeListener(_onScrollingChanged);
    _timer?.cancel();
    super.dispose();
  }

  /// Смена состояния прокрутки: поехали — убрать картинки и отменить просьбы, встали —
  /// вернуть их через [_settle].
  ///
  /// Просьба, пропущенная на ходу, сама не вернётся: `build` её не повторяет, а `didUpdateWidget`
  /// молчит, пока кадр тот же. Поэтому остановку слушаем здесь. Убранная картинка — то же самое:
  /// без перерисовки клетка осталась бы с прежним `Image.file` и декодировала бы его прямо
  /// в кадре прокрутки.
  void _onScrollingChanged() {
    if (widget.scrolling.value) {
      _timer?.cancel();
      _timer = null;
      if (_settled) setState(() => _settled = false);
      return;
    }
    _arm(_settle);
  }

  /// Поставить показ картинки и просьбу через [delay] — отменяемые и перезапускаемые.
  ///
  /// Пока срок не вышел, клетка заглушка: именно эта пауза отделяет движение пальца от работы
  /// с диском и декодированием.
  void _arm(Duration delay) {
    _timer?.cancel();
    if (_settled) setState(() => _settled = false);
    _timer = Timer(delay, () {
      _timer = null;
      if (!mounted) return;
      // Список снова поехал (долгая инерция длиннее паузы): срок не считается вышедшим —
      // клетка остаётся заглушкой, а картинку вернёт следующая остановка
      // (см. [_onScrollingChanged]).
      if (widget.scrolling.value) return;
      setState(() => _settled = true);
      _request();
    });
  }

  /// Попросить миниатюру у очереди, если просить можно.
  ///
  /// Побочно: ставит `_requested`, перерисовывает плитку по готовности файла и ставит новую
  /// попытку, если просить пока нельзя.
  void _request() {
    if (!mounted || _requested) return;
    // Режим без превью: картинка на экран не попадёт, и качать её не за чем.
    if (!widget.previews) return;
    // Список едет — не просим: просьбу повторит остановка (см. [_onScrollingChanged]).
    if (widget.scrolling.value) return;
    // Пауза после остановки ещё не прошла: картинка сейчас не показывается, и просить её
    // рано — срок выйдет, и просьбу поставит он же (см. [_arm]).
    if (!_settled) return;
    final sha = widget.item.sha256;
    // Кадр без собранного превью: качать нечего, ждём опроса состояния (`GalleryController`).
    if (sha == null || sha.isEmpty || widget.item.previewState != 'done') return;
    final cache = widget.thumbs;
    if (cache == null) {
      // Хранилище ещё открывается (первый кадр после запуска) — вернёмся к просьбе позже.
      _arm(_retry);
      return;
    }
    if (cache.isMissing(sha)) {
      // Сервер ответил 404: превью не собрано или собрать его нельзя. Повторять бессмысленно —
      // состояние на сервере меняется работой очереди, а не нашим запросом.
      if (!_missing) setState(() => _missing = true);
      return;
    }
    _requested = true;
    unawaited(cache.request(sha).then((_) {
      if (!mounted) return;
      setState(() => _missing = cache.isMissing(sha) && cache.file(sha) == null);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // Режим без превью — сразу значок. Список едет или пауза после остановки не прошла —
    // тоже значок: декодировать картинку в кадре прокрутки значит отбирать кадр у движения.
    if (!widget.previews || !_settled) return _placeholder(item);
    final sha = item.sha256;
    final thumbs = widget.thumbs;
    final file = (sha != null && thumbs != null && !_missing) ? thumbs.file(sha) : null;
    if (file == null) return _placeholder(item);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      onTap: widget.onTap,
      child: Image.file(
        file,
        width: widget.side,
        height: widget.side,
        fit: BoxFit.cover,
        // Кадр не мигает заглушкой при перерисовке окна и декодируется в размер клетки:
        // миниатюра 256×256 после кэша картинок занимала бы память под квадрат 256, хотя на
        // экране она 75 dp.
        //
        // Фильтрация — `low`, а не `medium`: миниатюра приходит квадратом 256 и ужимается в клетку
        // на считаные проценты, мипмапы тут ничего не улучшают, а строятся они на каждую картинку
        // заново — при пролистывании это десятки построений в секунду.
        gaplessPlayback: true,
        cacheWidth: (widget.side * dpr).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => _placeholder(item),
      ),
    );
  }

  /// Заглушка клетки: серый фон и значок по типу файла.
  ///
  /// Значок разный намеренно: «превью ещё собирается» и «превью не будет никогда» — разные
  /// вещи, и по одинаковой иконке человек не понимает, ждать ему или нет. В режиме без превью
  /// различать нечего — картинки не будет ни у кого, — поэтому значок показывается всегда:
  /// иначе клетка готового кадра осталась бы пустым серым квадратом и была бы неотличима
  /// от клетки, про которую ничего не известно.
  Widget _placeholder(MediaItem item) {
    final isVideo = item.mime.startsWith('video/');
    final impossible = item.previewState == 'impossible';
    final IconData? icon = !widget.previews
        ? (isVideo ? Icons.movie_outlined : Icons.image_outlined)
        : impossible
            ? (isVideo ? Icons.videocam_off_outlined : Icons.hide_image_outlined)
            : (item.previewState == 'done' ? null : (isVideo ? Icons.movie_outlined : Icons.image_outlined));
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: C.surface3,
        alignment: Alignment.center,
        child: icon == null ? null : Icon(icon, color: C.fg3, size: 20),
      ),
    );
  }
}
