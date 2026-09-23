import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

// Просмотрщик кадра — общий для галереи и карты. Живёт отдельным файлом, а не внутри экрана
// галереи: у галереи своя, куда более объёмная жизнь (окно кадров, шкала, прокрутка),
// а просмотрщик — самостоятельный экран, который галерея лишь открывает и снабжает кадрами.

/// Высота полосы метаданных в просмотрщике: одна строка значков и подписей.
const double _footerH = 46.0;

/// Прозрачность подложки футера поверх кадра.
const double _footerAlpha = 0.6;

/// Полноэкранный просмотрщик кадра — общий для галереи и карты.
///
/// Кадров у него нет: он листает по индексам и спрашивает их у вызывающего экрана через
/// `getItem`, а догрузку просит через `ensure`. Такая развязка нужна потому, что источники
/// разные: у галереи кадры лежат в окне вокруг якоря и подгружаются страницами
/// (`GalleryController`), у карты — приезжают по одному уже после открытия просмотрщика.
///
/// Контракт по удалению (и главная тонкость класса): `total` — не снимок, а общий с владельцем
/// кадров `ValueListenable`. Он задаёт `itemCount` и границы листания, и его же владелец
/// уменьшает в своём `onDelete`; просмотрщик перестраивается на новое число сам, поэтому
/// лишней страницы-спиннера после удаления не остаётся. Значит удаление переживает не
/// просмотрщик, а вызвавший его экран: он сдвигает свои индексы (`onDelete`) и уменьшает своё
/// число кадров, а просмотрщик только переставляет указатель на новый текущий кадр.
class MediaViewer extends StatefulWidget {
  final CloudlyApi api;
  /// Число кадров у владельца: тот же счётчик, что показывает список. См. контракт в описании
  /// класса — значение живое, а не зафиксированное на момент открытия.
  final ValueListenable<int> total;
  /// С какого кадра открылись: он же стартовая страница `PageView`.
  final int initialIndex;
  /// Кадр по индексу или `null`, если он ещё не загружен (тогда показывается спиннер).
  final MediaItem? Function(int) getItem;
  /// Просьба подгрузить кадры в диапазоне индексов. Вызывается на каждой отрисовке слайда,
  /// поэтому реализация обязана быть дешёвой и сама решать, что именно грузить.
  final void Function(int start, int end) ensure;
  /// Сообщение вызывающему экрану, что кадр удалён: индекс в его нумерации. Сдвиг индексов
  /// и пересчёт числа кадров — забота вызывающего (см. контракт класса).
  final void Function(int index) onDelete;

  /// Родитель дёргает этот Listenable, когда его кэш кадров пополнился: без этого
  /// просмотрщик оставался бы со спиннером (у карты кадры приходят уже после открытия).
  ///
  /// Кто инкрементит: владелец кэша (`GalleryController` после каждой страницы ленты,
  /// `MapScreen` после догрузки одного кадра). Кто слушает: этот виджет — подписка ставится
  /// в `initState` и снимается в `dispose`, поэтому сигнал не переживает просмотрщик.
  final Listenable? revision;

  const MediaViewer({
    super.key,
    required this.api,
    required this.total,
    required this.initialIndex,
    required this.getItem,
    required this.ensure,
    required this.onDelete,
    this.revision,
  });

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

/// Состояние просмотрщика: текущая страница и метаданные кадра для футера.
class _MediaViewerState extends State<MediaViewer> {
  /// Контроллер листания; создаётся на стартовом кадре и живёт до закрытия просмотрщика.
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  /// Номер текущего кадра. Держится отдельно от контроллера, потому что нужен там, где
  /// страница не менялась: удаление, обновление метаданных, футер.
  late int _idx = widget.initialIndex;
  /// Метаданные текущего кадра для футера; `null` — ещё грузятся (или кадра нет).
  MediaInfo? _info;
  /// Номер запроса метаданных: ответ применяется, только если он всё ещё последний.
  ///
  /// Без этого футер показывал бы EXIF прошлого кадра: при быстром листании запросы уходят
  /// на каждый кадр, а отвечают не по порядку — медленный ответ на кадр №3 перетирал бы
  /// метаданные уже открытого №4.
  int _infoGen = 0;

  @override
  /// Подписка на сигнал родителя и метаданные кадра, с которого открылись.
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRevision);
    _loadInfo(_idx);
  }

  /// Реакция на сигнал «в кэше родителя появились кадры».
  ///
  /// Кадр мог подгрузиться уже после открытия просмотрщика (это обычный случай для карты),
  /// поэтому по сигналу достаточно перерисоваться — `build` сам перечитает кадр через
  /// `getItem`. Метаданные футера при этом дотягиваются отдельно: за них отвечает другое
  /// поле, и без повторного запроса футер остался бы пустым.
  void _onRevision() {
    if (!mounted) return;
    setState(() {});
    // Кадр подгрузился уже после открытия — метаданные футера тоже надо дотянуть.
    if (_info == null) _loadInfo(_idx);
  }

  @override
  /// Отписка от сигнала и уничтожение контроллера листания.
  void dispose() {
    widget.revision?.removeListener(_onRevision);
    _pc.dispose();
    super.dispose();
  }

  /// Читает метаданные кадра для футера (параметры съёмки, размер, координаты).
  ///
  /// Кадр берётся у родителя: если он ещё не загружен, запрашивать нечего — выход без запроса,
  /// метаданные подтянутся по сигналу `_onRevision`. Пока идёт запрос, `_info` сбрасывается,
  /// чтобы футер не показывал данные прошлого кадра. Ошибку глотаем: без футера просмотр
  /// кадра не ломается.
  ///
  /// Ответ применяется только если за время запроса не ушёл следующий (`_infoGen`): иначе
  /// футер показывал бы EXIF того кадра, который уже пролистали.
  /// Побочно: `_info` (сначала пусто, потом метаданные кадра), `_infoGen`.
  Future<void> _loadInfo(int i) async {
    final gen = ++_infoGen;
    final item = widget.getItem(i);
    if (item == null) return;
    if (mounted) setState(() => _info = null);
    try {
      final info = await widget.api.mediaInfo(item.entryId);
      if (mounted && gen == _infoGen) setState(() => _info = info);
    } catch (_) {}
  }

  /// Удаляет текущий кадр: файл уходит в корзину на сервере, кэш и счётчик сдвигает родитель.
  ///
  /// Арифметика перехода опирается на число кадров **до** удаления, — и это не ошибка:
  /// удалённый кадр в этом числе ещё есть. Если удалили последний кадр, встаём на
  /// предпоследний (после сдвига он стал последним), иначе остаёмся на своём номере —
  /// на него въехал следующий кадр. `clamp` не даёт выйти за границы. Если кадр был
  /// единственным, просмотрщик закрывается: показывать нечего.
  ///
  /// Число кадров после удаления берётся из общего с родителем счётчика (`widget.total`),
  /// который тот уменьшает внутри `onDelete`. Поэтому `itemCount` у `PageView` схлопывается
  /// сразу, а контроллер переставляется на новый номер вручную — иначе листание осталось бы
  /// на странице, которой в новом списке уже нет.
  ///
  /// Побочно: `widget.onDelete(_idx)` — родитель сдвигает индексы и уменьшает счётчик;
  /// `_idx` и метаданные футера пересчитываются под новый кадр.
  Future<void> _delete() async {
    final item = widget.getItem(_idx);
    if (item == null) return;
    final ok = await confirmDialog(context, 'Удалить «${item.name}»?', 'Файл уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await widget.api.deleteFile(item.entryId);
      if (!mounted) return;
      // Родитель сдвигает свои индексы и уменьшает общий счётчик — из него и берётся число
      // кадров после удаления.
      widget.onDelete(_idx);
      final after = widget.total.value;
      if (after <= 0) {
        Navigator.pop(context);
        return;
      }
      // Удалили последний кадр — встаём на предыдущий; иначе номер тот же: на него въехал
      // следующий кадр.
      setState(() => _idx = (_idx >= after ? after - 1 : _idx).clamp(0, after - 1));
      // Список страниц уже укоротился, но `PageView` мог остаться на прежнем номере:
      // переставляем контроллер на кадр, который показываем.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pc.hasClients) _pc.jumpToPage(_idx);
      });
      _loadInfo(_idx);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    // `itemCount` и границы листания живут в счётчике родителя: удаление кадра меняет их
    // на месте, и просмотрщик перестраивается без переоткрытия (см. контракт класса).
    return ValueListenableBuilder<int>(
      valueListenable: widget.total,
      builder: (context, total, _) => _body(total),
    );
  }

  /// Тело просмотрщика для текущего числа кадров `total`.
  Widget _body(int total) {
    final item = widget.getItem(_idx);
    final geo = (_info?.latitude != null && _info?.longitude != null) ? _info : null;
    // В шапке — дата съёмки, а если её нет, имя файла. Пояс снимка сервер отдаёт отдельным
    // полем (`tzOffsetMin` у кадра): `capturedAt` — уже пересчитанный UTC-момент, поэтому без
    // поправки цифры ISO-строки врут на пояс съёмки. Если пояса в тегах не было, `tzOffsetMin`
    // пуст и подпись выходит в UTC — сервер в этом случае не знает, где снимали.
    final date = fmtMediaDate(item?.capturedAt, tzOffsetMin: item?.tzOffsetMin);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pc,
          itemCount: total,
          onPageChanged: (i) {
            setState(() => _idx = i);
            _loadInfo(i);
          },
          itemBuilder: (context, i) {
            // Просим кадр и соседей: соседние слайды PageView строит заранее, и без этой
            // просьбы они оставались бы спиннерами до следующего движения пальцем.
            widget.ensure(math.max(0, i - 1), math.min(total - 1, i + 1));
            return _slide(widget.getItem(i));
          },
        ),
        SafeArea(
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 4),
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              Expanded(
                child: Text(
                  date.isNotEmpty ? date : (item?.name ?? ''),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (geo != null)
                IconButton(
                  icon: const Icon(Icons.map_outlined, color: Colors.white),
                  onPressed: () => _openOsm(geo),
                ),
              IconButton(
                icon: const Icon(Icons.download, color: Colors.white),
                onPressed: item == null ? null : () => _download(item),
              ),
              IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white), onPressed: item == null ? null : _delete),
            ]),
            const Spacer(),
            if (_info != null) _footer(),
          ]),
        ),
      ]),
    );
  }

  /// Один слайд: фото, видео или спиннер, пока кадр не доехал.
  ///
  /// Спиннер вместо пустоты — потому что кадры приходят по индексам, и «нет данных» здесь
  /// штатная ситуация, а не ошибка: `ensure` уже попросил их у родителя.
  Widget _slide(MediaItem? item) {
    if (item == null) return const Center(child: CircularProgressIndicator());
    final isVideo = item.mime.startsWith('video/');
    if (isVideo) return _video(item);
    return _image(item);
  }

  /// Фото: превью 1080 px в `InteractiveViewer`, чтобы можно было приблизить пальцами.
  ///
  /// Именно превью, а не оригинал: в ленте кадры листают десятками, и тянуть полноразмерные
  /// файлы ради просмотра на телефоне смысла нет. Оригинал доступен кнопкой «Скачать».
  /// Если sha256 у кадра нет, кадр брать неоткуда — про это честно сообщаем.
  Widget _image(MediaItem item) {
    final sha = item.sha256;
    if (sha == null || sha.isEmpty) {
      return const Center(child: Text('Превью не открылось', style: TextStyle(color: Colors.white70)));
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 8,
      alignment: Alignment.center,
      child: CachedNetworkImage(
        imageUrl: widget.api.previewUrl(sha, w: 1080),
        httpHeaders: widget.api.authHeaders,
        fit: BoxFit.contain,
        placeholder: (_, _) => const CircularProgressIndicator(color: Colors.white),
        errorWidget: (_, _, _) => const Center(child: Text('Превью не открылось — файл мог быть удалён', style: TextStyle(color: Colors.white70))),
      ),
    );
  }

  /// Видео: серверное превью в отдельном виджете `_Vid` со своим контроллером.
  ///
  /// Превью — не единственный источник: часть старых роликов собрана в AV1, который
  /// декодируют не все устройства (Safari/iOS < 17), поэтому `_Vid` при отказе сам переходит
  /// на оригинал (`?src=original`) — так же, как это сделано в деталке файла.
  Widget _video(MediaItem item) {
    final sha = item.sha256;
    if (sha == null || sha.isEmpty) return const SizedBox();
    return Center(child: _Vid(api: widget.api, sha: sha));
  }

  /// Футер с параметрами кадра: размер, кадр, камера, объектив, выдержка, ISO, координаты.
  ///
  /// Данные — из метаданных кадра (`_info`), а размер берётся из ленты, когда кадр под рукой:
  /// он там уже есть и не требует отдельного поля. Строки показываются по наличию значения,
  /// поэтому у фото и видео набор разный. Футер горизонтально прокручивается: параметров
  /// много, а место занимает одну строку.
  Widget _footer() {
    final info = _info!;
    final item = widget.getItem(_idx);
    final metas = <(IconData, String, String)>[
      (Icons.sd_storage_outlined, 'Размер', fmt(item?.size ?? info.size)),
      if (info.width != null && info.height != null) (Icons.aspect_ratio, 'Кадр', '${info.width} × ${info.height}'),
      if ((info.make?.isNotEmpty ?? false) || (info.model?.isNotEmpty ?? false))
        (Icons.camera_alt_outlined, 'Камера', [info.make, info.model].where((s) => s != null && s.isNotEmpty).join(' ')),
      if (info.lens != null) (Icons.center_focus_strong, 'Объектив', info.lens!),
      if (info.fNumber != null) (Icons.camera, 'Диафрагма', 'f/${trimNum(info.fNumber!, 1)}'),
      if (info.exposureTime != null) (Icons.timer_outlined, 'Выдержка', info.exposureTime!),
      if (info.iso != null) (Icons.speed, 'ISO', '${info.iso}'),
      if (info.focalLength != null) (Icons.straighten, 'Фокусное', '${trimNum(info.focalLength!, 1)} мм'),
      if (info.durationSec != null) (Icons.schedule, 'Длительность', fmtDuration(info.durationSec!)),
      if (info.fps != null) (Icons.speed, 'Кадров/с', '${trimNum(info.fps!, 2)} к/с'),
      if (info.videoCodec != null) (Icons.videocam_outlined, 'Кодек', info.videoCodec!),
      if (item != null) (Icons.notes, 'Тип', item.mime),
      if (info.latitude != null && info.longitude != null)
        (Icons.place_outlined, 'Координаты', '${info.latitude!.toStringAsFixed(6)}, ${info.longitude!.toStringAsFixed(6)}'),
    ];
    return Container(
      color: Colors.black.withValues(alpha: _footerAlpha),
      height: _footerH,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: metas
            .map((m) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Icon(m.$1, color: Colors.white70, size: 15),
                    const SizedBox(width: 4),
                    Text(m.$3, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  /// Открывает точку съёмки на OpenStreetMap в браузере.
  ///
  /// Ссылка ведёт не на просмотрщик карты, а на osm.org: полноценной карты внутри приложения
  /// для одного кадра не нужно, а браузер даёт зум, слои и поиск. `#map=16` — уровень зума,
  /// на котором видно квартал.
  void _openOsm(MediaInfo geo) {
    launchUrl(Uri.parse(
        'https://www.openstreetmap.org/?mlat=${geo.latitude}&mlon=${geo.longitude}#map=16/${geo.latitude}/${geo.longitude}'));
  }

  /// Скачивает оригинал кадра и открывает его системным просмотрщиком (`downloadAndOpen`).
  void _download(MediaItem item) {
    downloadAndOpen(widget.api, item.entryId, item.name);
  }
}

/// Проигрыватель видео для просмотрщика: свой контроллер на слайд.
///
/// Отдельный виджет, а не код внутри `MediaViewer`, чтобы контроллер жил ровно столько,
/// сколько слайд на экране: `PageView` уничтожает ушедшие страницы, и вместе с ними
/// освобождается декодер. Иначе при листании десятков роликов они копились бы в памяти.
///
/// Адреса строятся здесь, а не приходят готовой строкой: их два — превью и оригинал, и
/// выбираются они по ходу (см. `_stage`).
class _Vid extends StatefulWidget {
  final CloudlyApi api;
  /// sha256 кадра: из него собираются и превью, и оригинал.
  final String sha;
  const _Vid({required this.api, required this.sha});
  @override
  State<_Vid> createState() => _VidState();
}

/// Состояние плеера: контроллер, стадия и признак «не заиграло совсем».
class _VidState extends State<_Vid> {
  /// 0 — серверное превью, 1 — оригинал кадра (`?src=original`), 2 — пробовать больше нечего.
  int _stage = 0;
  VideoPlayerController? _c;
  bool _err = false;

  @override
  /// Сразу поднимаем плеер для этого слайда.
  void initState() {
    super.initState();
    _init();
  }

  @override
  /// Слайд ушёл с экрана — снимаем подписку и освобождаем декодер.
  void dispose() {
    _c?.removeListener(_onEvent);
    _c?.dispose();
    super.dispose();
  }

  /// Создаёт контроллер текущей стадии и инициализирует поток.
  ///
  /// Автовоспроизведения нет (в отличие от деталки файла): в ленте может открыться страница
  /// с видео, которое пользователь не просил включать, — ролик запускает кнопка поверх кадра
  /// (см. `build`). Ошибка ловится и из `initialize`,
  /// и из событий контроллера — поток может не открыться уже после успешной инициализации.
  /// Побочно: `_c`, подписка на события, перерисовка; при неудаче — `_fallback`.
  Future<void> _init() async {
    final url = _stage == 0
        ? widget.api.videoPreviewUrl(widget.sha)
        : widget.api.videoPreviewUrl(widget.sha, original: true);
    final c = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: widget.api.authHeaders);
    _c = c;
    c.addListener(_onEvent);
    try {
      await c.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      _fallback();
    }
  }

  /// Ловит ошибку, пришедшую уже после `initialize`.
  void _onEvent() {
    if (_c?.value.hasError ?? false) _fallback();
  }

  /// Откат к следующей стадии, а если их больше нет — к надписи «Видео не проигрывается».
  ///
  /// Первая стадия — превью 1080: часть старых роликов сервер собрал в AV1, и на устройствах
  /// без его декодера (Safari/iOS < 17) такое превью не играет вовсе, хотя сам файл
  /// проигрывается. Вторая стадия — оригинал (`?src=original`): он отдаётся в исходном
  /// формате, который эти устройства понимают. Тянуть оригинал всегда нельзя (гигабайты
  /// ради листания), поэтому он только запасной вариант — как в деталке файла.
  ///
  /// Побочно: старый контроллер уничтожается (иначе он держал бы декодер и поток), при
  /// `_stage < 1` стадия растёт и `_init` пробует оригинал, иначе ставится `_err`.
  void _fallback() {
    if (!mounted) return;
    _c?.removeListener(_onEvent);
    _c?.dispose();
    _c = null;
    if (_stage < 1) {
      setState(() => _stage++);
      _init();
    } else {
      setState(() => _err = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err) {
      return const Center(child: Text('Видео не проигрывается', style: TextStyle(color: Colors.white70)));
    }
    final c = _c;
    if (c != null && c.value.isInitialized) {
      return AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: Stack(alignment: Alignment.center, children: [
          VideoPlayer(c),
          // Кнопка запуска поверх ролика: своих элементов управления у `VideoPlayer` нет,
          // а автозапуска здесь нет намеренно (см. `_init`) — без этой кнопки ролик так и
          // оставался бы кадром-заставкой, и запустить его было бы нечем.
          //
          // Подписка на сам контроллер, а не на состояние виджета: значок обязан смениться
          // в тот же кадр, в котором ролик начал или перестал играть, — перерисовок по другим
          // поводам у слайда может не быть вовсе.
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (context, v, _) => GestureDetector(
              onTap: () => v.isPlaying ? c.pause() : c.play(),
              child: Icon(
                v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                size: 56,
                color: Colors.white70,
              ),
            ),
          ),
        ]),
      );
    }
    return const CircularProgressIndicator(color: Colors.white);
  }
}
