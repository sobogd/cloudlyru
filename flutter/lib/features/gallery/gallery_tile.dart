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
/// Пока список едет, не просится вообще ничего ([scrolling]): серые клетки вместо картинок —
/// это и есть плата за гладкую прокрутку, а по остановке плитка просит миниатюру заново. Одна
/// пауза [_settle] этого не давала: медленное перетаскивание ползунка длится дольше её.
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.item,
    required this.side,
    required this.thumbs,
    required this.scrolling,
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

  /// Открыть кадр в просмотрщике.
  final VoidCallback onTap;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  /// Пауза перед просьбой о миниатюре: плитка, которая прожила меньше, ничего не просит.
  static const Duration _settle = Duration(milliseconds: 350);

  /// Сколько ждать, если просить пока нельзя (хранилище миниатюр ещё открывается).
  static const Duration _retry = Duration(milliseconds: 250);

  Timer? _timer;

  /// Миниатюра уже запрошена — второй раз просить незачем: очередь дедуплицирует по хэшу,
  /// но помнить факт полезно, иначе каждый `build` слал бы запрос заново.
  bool _requested = false;

  /// Миниатюры на диске нет и не будет (сервер ответил 404): просить больше нечего.
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    widget.scrolling.addListener(_onScrollingChanged);
    _arm(_settle);
  }

  @override
  void didUpdateWidget(GalleryTile old) {
    super.didUpdateWidget(old);
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

  /// Прокрутка кончилась: у плитки снова есть повод попросить миниатюру.
  ///
  /// Просьба, пропущенная на ходу, сама не вернётся: `build` её не повторяет, а `didUpdateWidget`
  /// молчит, пока кадр тот же. Поэтому остановку слушаем здесь.
  void _onScrollingChanged() {
    if (!widget.scrolling.value) _arm(_settle);
  }

  /// Поставить просьбу через [delay] — отменяемую и перезапускаемую.
  void _arm(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _request);
  }

  /// Попросить миниатюру у очереди, если просить можно.
  ///
  /// Побочно: ставит `_requested`, перерисовывает плитку по готовности файла и ставит новую
  /// попытку, если просить пока нельзя.
  void _request() {
    if (!mounted || _requested) return;
    // Список едет — не просим: просьбу повторит остановка (см. [_onScrollingChanged]).
    if (widget.scrolling.value) return;
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
  /// вещи, и по одинаковой иконке человек не понимает, ждать ему или нет.
  Widget _placeholder(MediaItem item) {
    final isVideo = item.mime.startsWith('video/');
    final impossible = item.previewState == 'impossible';
    final IconData? icon = impossible
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
