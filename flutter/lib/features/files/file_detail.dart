import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/download.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Высота заглушки превью, пока картинка или страница ещё едет: спиннер должен занимать
/// столько же места, сколько займёт результат, иначе список под ним прыгает.
const _imageBoxH = 180.0;
/// То же для страницы PDF: она ниже картинки, потому что под ней ещё строка с номером страницы.
const _pdfBoxH = 160.0;

/// Предел размера файла, который деталка показывает оригиналом (вторая стадия превью картинки).
///
/// Вторая стадия качает оригинал целиком в память, а `Image.memory` держит ещё и распакованный
/// кадр: RAW или панорама на 50–80 МБ роняют приложение по памяти. Выше предела показываем
/// «Превью не собрано» с кнопкой «Скачать» — системный просмотрщик читает файл по мере
/// надобности, а не целиком.
///
/// Ноль в `meta.size` означает «сервер размера не прислал» (см. `FileMeta.size`): тогда
/// ограничить нечем, и оригинал тянется как раньше — иначе пустой файл считался бы
/// гигантским и оставался бы вообще без превью.
const _maxOriginalPreviewBytes = 24 * 1024 * 1024;

/// Ширина, до которой ужимается превью при декодировании: примерно ширина экрана телефона
/// в физических пикселях. Больше не нужно — превью рисуется в ширину карточки, а распакованный
/// кадр занимает в памяти в разы больше, чем сжатые байты.
const _previewCacheWidth = 1080;

/// Скачивает файл и открывает его системным обработчиком, показывая неудачу подсказкой.
///
/// [downloadAndOpen] возвращает текст ошибки (или `null` при успехе) и сам отсекает повторное
/// нажатие «Скачать» по тому же файлу: раньше результат вызова никто не читал, и на неудачном
/// скачивании не было ни файла, ни сообщения — кнопка выглядела нерабочей. Показывать нечего
/// только при успехе: файл уже отдан системе, и человек видит его в открывшемся приложении.
Future<void> _download(BuildContext context, CloudlyApi api, FileMeta meta) async {
  final err = await downloadAndOpen(api, meta.id, meta.name);
  if (err != null && context.mounted) snack(context, err);
}

/// Текст ошибки для человека.
///
/// [ApiException] уже несёт готовое сообщение: серверный текст или разбор сетевого сбоя
/// (см. `CloudlyApi._toException`), поэтому его `toString` и есть то, что нужно показать.
/// Всё остальное — ошибка разбора или наш баг, и её сырой `toString` (с типом исключения)
/// человеку ничего не объясняет: показываем общую формулировку.
///
/// Общий маппер ошибок должен жить там же, где остальные общие виджеты (`util/widgets.dart`):
/// сейчас его нет, а экраны других владельцев показывают `toString` как есть — это отмечено
/// в отчёте как правка для владельца того файла.
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось выполнить операцию';

/// Цвет иконки play/pause поверх видео.
///
/// Белый с прозрачностью, а не `Colors.white`: иконка лежит на произвольном кадре, и полная
/// непрозрачность спорила бы с ним. Держим это константой, чтобы цвет не собирался из
/// литералов по месту. Такой же оверлей есть в «Медиа» и на карте — общая константа должна
/// жить в теме (`theme.dart`), это отмечено владельцу того файла.
const _overlayFg = Color(0xD9FFFFFF);

/// Деталка файла: метаданные, превью и операции над записью.
///
/// Данные — `fileMeta` по id записи; отдельно дочитываются два состояния, которых в метаданных
/// нет сразу: число страниц PDF (превью собирается на сервере асинхронно) и последняя задача
/// распаковки zip, если файл — архив. Превью зависит от mime: картинка, видео или страница PDF
/// (соответствующие виджеты ниже), для остальных типов превью не показывается.
///
/// Возврат вызывающему: `true` — файл переименовали или удалили, и список на экране «Файлы»
/// надо перечитать. Флаг живёт в состоянии ([_FileDetailScreenState._changed]), а не только
/// в `Navigator.pop` после удаления: переименование экран не закрывает, и результат уходит
/// наверх при выходе — в том числе системным «назад».
class FileDetailScreen extends ConsumerStatefulWidget {
  final String entryId;
  const FileDetailScreen({super.key, required this.entryId});

  @override
  ConsumerState<FileDetailScreen> createState() => _FileDetailScreenState();
}

/// Состояние деталки: метаданные, сообщения и два фоновых опроса (страницы PDF, задача распаковки).
class _FileDetailScreenState extends ConsumerState<FileDetailScreen> {
  FileMeta? _meta;
  String? _error;
  String? _notice;
  /// Задача распаковки: показывается панелью, пока сервер о ней что-то знает.
  UnzipJob? _job;
  /// Опрос задачи распаковки (её прогресс сервер отдаёт только по запросу).
  Timer? _unzipTimer;
  /// Опрос числа страниц PDF: до него превью страницы показать нельзя.
  Timer? _pagesTimer;
  /// Сколько раз уже переспрашивали метаданные в ожидании числа страниц PDF.
  int _pagesTries = 0;
  /// Было ли изменение, о котором надо сказать списку «Файлов» (переименование). Удаление
  /// экран закрывает сразу и отдаёт `true` напрямую, а переименование оставляет экран
  /// открытым — этот флаг уезжает вызывающему при выходе.
  bool _changed = false;

  /// Предел попыток опроса числа страниц PDF.
  ///
  /// Число страниц сервер узнаёт, разбирая файл, и у битого PDF оно не появится никогда:
  /// без предела опрос шёл бы всё время, пока открыт экран, — в том числе когда приложение
  /// свёрнуто. Десять попыток с растущей паузой (3, 6, 9 … с) — это примерно три минуты
  /// ожидания, после которых превью страницы так и не показывается.
  static const _pagesMaxTries = 10;

  @override
  /// Первая загрузка: метаданные файла и, если есть, задача распаковки.
  void initState() {
    super.initState();
    _load();
    _loadUnzip();
  }

  @override
  /// Экран закрывается — снимаем оба опроса, иначе они ходили бы на сервер и после этого.
  void dispose() {
    // Оба опроса живут ровно столько, сколько открыт экран: без отмены таймеры продолжили бы
    // ходить на сервер после закрытия деталки.
    _unzipTimer?.cancel();
    _pagesTimer?.cancel();
    super.dispose();
  }

  /// Читает метаданные файла и, если это PDF без числа страниц, ставит опрос до их появления.
  ///
  /// Побочно: перерисовка, возможный запуск опроса страниц и снятие прошлой ошибки. Число
  /// страниц сервер узнаёт, разбирая файл, поэтому у свежего PDF его ещё нет, а без него
  /// превью страницы не запросить.
  Future<void> _load() async {
    try {
      final m = await ref.read(appStateProvider).api.fileMeta(widget.entryId);
      if (!mounted) return;
      setState(() {
        _meta = m;
        _error = null;
      });
      // PDF без pageCount — превью ещё собирается. Переспрашиваем паузой с ростом и ограниченным
      // числом попыток: у PDF, который так и не разобрался, опрос остановится сам, а не будет
      // ходить на сервер, пока открыт экран (см. _pagesMaxTries).
      if (m.mime == 'application/pdf' && (m.pageCount ?? 0) == 0) {
        _pagesTries = 0;
        _schedulePagesCheck();
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Ставит следующую проверку числа страниц PDF на таймер с растущей паузой.
  ///
  /// Пауза растёт с каждой неудачной попыткой (3, 6, 9 … с): свежий PDF сервер разбирает
  /// секундами, а большой файл — минутами, и частые запросы разбор не ускоряют.
  void _schedulePagesCheck() {
    _pagesTimer?.cancel();
    _pagesTimer = Timer(Duration(seconds: 3 * (_pagesTries + 1)), _checkPages);
  }

  /// Одна попытка узнать число страниц PDF; при неудаче — следующая попытка по таймеру.
  ///
  /// Побочно: `_meta` с появившимся числом страниц (после него `PdfPreview` покажет первую) либо
  /// новый таймер. Сбой запроса опрос не прекращает — недоступный сервер и неразобранный PDF
  /// для экрана выглядят одинаково, и повторить стоит оба случая.
  Future<void> _checkPages() async {
    if (!mounted) return;
    try {
      final mm = await ref.read(appStateProvider).api.fileMeta(widget.entryId);
      if (!mounted) return;
      if ((mm.pageCount ?? 0) > 0) {
        setState(() => _meta = mm);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    if (++_pagesTries >= _pagesMaxTries) return;
    _schedulePagesCheck();
  }

  /// Подтягивает последнюю задачу распаковки этого файла, если она есть.
  ///
  /// Берём только живые состояния (ждёт, идёт, готово): проваленную или отменённую задачу
  /// показывать нечего — панель распаковки говорила бы о прошлом запуске, а не о текущем
  /// результате. Ошибку запроса глотаем: отсутствие задачи и недоступный сервер для экрана
  /// значат одно — панели нет.
  Future<void> _loadUnzip() async {
    try {
      final j = await ref.read(appStateProvider).api.latestUnzip(widget.entryId);
      if (mounted && j != null && (j.state == 'pending' || j.state == 'processing' || j.state == 'done')) {
        setState(() => _job = j);
        _pollUnzip();
      }
    } catch (_) {}
  }

  /// Опрашивает сервер о ходе распаковки раз в 2 секунды.
  ///
  /// У сервера нет push-канала, а сама распаковка идёт в фоне: процент, число файлов и байт
  /// приходят только ответом на `unzipStatus`, поэтому единственный способ показать прогресс —
  /// опрос. 2 с — компромисс: на глаз прогресс движется, а лишних запросов к серверу немного
  /// (архив распаковывается секундами и минутами, а не мгновенно).
  ///
  /// Опрос завершается на любом состоянии, кроме `pending`/`processing`, — в том числе на
  /// `cancelled`: отменённая задача больше не изменится, и продолжать спрашивать о ней незачем.
  void _pollUnzip() {
    _unzipTimer?.cancel();
    _unzipTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      // Задача читается на каждом тике, а не захвачена в замыкание: её подменяет `_startUnzip`,
      // и опрос должен спрашивать про актуальную.
      final j = _job;
      if (j == null) return;
      try {
        final s = await ref.read(appStateProvider).api.unzipStatus(j.id);
        if (mounted) {
          setState(() => _job = s);
          if (s.state != 'pending' && s.state != 'processing') _unzipTimer?.cancel();
        }
      } catch (_) {}
    });
  }

  /// Файл — архив: либо сервер так определил mime, либо имя кончается на `.zip` (у архивов,
  /// загруженных сторонним клиентом, mime может быть `application/octet-stream`). По этому
  /// признаку показывается кнопка «Разархивировать рядом с архивом».
  bool get _isZip {
    final m = _meta;
    if (m == null) return false;
    return m.mime == 'application/zip' || m.name.toLowerCase().endsWith('.zip');
  }

  /// Переименовывает файл, запросив новое имя диалогом.
  ///
  /// Пустое имя или то же самое — выход без запроса к серверу. Побочно: `_notice`, перечитка
  /// метаданных (имя приходит только от сервера, локально его не подставляем) и `_changed` —
  /// по нему список «Файлов» перечитает уровень, когда экран закроют: без этого флага в списке
  /// оставалось старое имя.
  Future<void> _rename() async {
    final m = _meta;
    if (m == null) return;
    final next = await promptDialog(context, 'Новое имя файла', initial: m.name);
    if (next == null || next.trim().isEmpty || next == m.name) return;
    try {
      await ref.read(appStateProvider).api.renameFile(m.id, next.trim());
      if (!mounted) return;
      // Перерисовка нужна ради строки «Имя изменено»; сам `_meta` остаётся прежним и
      // обновится из перечитки ниже.
      setState(() => _notice = 'Имя изменено');
      _changed = true;
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Кладёт файл в буфер обмена сервера: `copy` — копирование, `cut` — перенос.
  ///
  /// Сама запись тут не меняется, меняется только буфер у пользователя, поэтому после успеха
  /// показывается подсказка с дальнейшим шагом («откройте папку и нажмите “Вставить”») —
  /// из одной кнопки иначе не понять, что произошло.
  Future<void> _toClip(String mode) async {
    final m = _meta;
    if (m == null) return;
    try {
      await ref.read(appStateProvider).api.setClipboard('file', m.id, mode);
      if (mounted) {
        snack(context, mode == 'copy'
            ? 'Скопировано. Откройте папку и нажмите «Вставить».'
            : 'Вырезано. Откройте папку и нажмите «Вставить».');
      }
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    }
  }

  /// Удаляет файл — сервер отправляет запись в корзину, откуда её можно вернуть.
  ///
  /// Отмена в диалоге — выход без запроса. После успеха экран закрывается с `true`: файла
  /// в папке больше нет, и «Файлы» по этому флагу перечитывают уровень.
  Future<void> _delete() async {
    final m = _meta;
    if (m == null) return;
    final ok = await confirmDialog(context, 'Удалить «${m.name}»?', 'Файл уйдёт в корзину.', danger: true);
    if (!ok) return;
    try {
      await ref.read(appStateProvider).api.deleteFile(m.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    }
  }

  /// Ставит задачу распаковки архива рядом с ним и начинает следить за её ходом.
  ///
  /// Сервер отвечает на запуск только идентификатором задачи: прогресс пойдёт опросом
  /// (`_pollUnzip`). Кнопка запуска заблокирована, пока задача живёт, — повторный запуск
  /// распаковал бы тот же архив второй раз.
  Future<void> _startUnzip() async {
    try {
      final j = await ref.read(appStateProvider).api.startUnzip(widget.entryId);
      if (mounted) {
        setState(() => _job = j);
        _pollUnzip();
      }
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    }
  }

  /// Отменяет идущую распаковку. Сервер возвращает уже отменённую задачу, поэтому `_job`
  /// сразу показывает состояние «отменено»; опрос остановится сам на ближайшем тике — состояние
  /// больше не `pending`/`processing`. Уже распакованные файлы отмена не удаляет.
  Future<void> _cancelUnzip() async {
    final j = _job;
    if (j == null) return;
    try {
      final s = await ref.read(appStateProvider).api.cancelUnzip(j.id);
      if (mounted) setState(() => _job = s);
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    final api = ref.watch(appStateProvider).api;
    // Все теги считаются один раз: в раскрывающемся списке их нужно трижды — для проверки
    // «есть ли что показывать», для счётчика в заголовке и для самих строк.
    final media = m == null ? const <(String, String)>[] : _mediaRows(m.media?.raw);
    return PopScope(
      // Пока ничего не менялось, маршрут закрывается как обычно — в том числе свайпом на iOS,
      // которому `canPop: false` запретил бы жест. После переименования выход перехватывается:
      // системный «назад» на Android иначе закрыл бы маршрут без ответа, и список «Файлов»
      // остался бы со старым именем.
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: C.fg),
            onPressed: () => Navigator.pop(context, _changed),
          ),
          title: Text(m?.name ?? 'Файл', style: const TextStyle(color: C.fg, fontSize: 16)),
          actions: [
            if (m != null) ...[
              IconButton(tooltip: 'Переименовать', icon: const Icon(Icons.edit_outlined, color: C.fg), onPressed: _rename),
              IconButton(tooltip: 'Копировать', icon: const Icon(Icons.copy, color: C.fg), onPressed: () => _toClip('copy')),
              IconButton(tooltip: 'Вырезать', icon: const Icon(Icons.content_cut, color: C.fg), onPressed: () => _toClip('cut')),
              if (_isZip)
                IconButton(
                  tooltip: 'Разархивировать рядом с архивом',
                  icon: const Icon(Icons.inventory_2_outlined, color: C.fg),
                  onPressed: (_job?.state == 'pending' || _job?.state == 'processing') ? null : _startUnzip,
                ),
              IconButton(
                tooltip: 'Скачать',
                icon: const Icon(Icons.download, color: C.fg),
                onPressed: () => _download(context, api, m),
              ),
              IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.danger), onPressed: _delete),
            ],
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(14, 8, 14, 8 + navBarInset(context)),
          children: [
            if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
            if (_notice != null) Text(_notice!, style: const TextStyle(color: C.ok)),
            if (_job != null) _unzipPanel(),
            if (m == null && _error == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (m != null) ...[
              if (m.mail != null) _mailOriginPanel(m),
              Panel(child: Column(children: _metaRows(m))),
              const SizedBox(height: 8),
              if (_previewKind(m) != null) _preview(api, m),
              // Полный список тегов из файла: и EXIF фото, и ffprobe видео. В основных строках
              // выше показано только то, что нужно всем типам, а тут — всё, что нашлось.
              if (media.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Все теги из файла (${media.length})',
                      style: const TextStyle(color: C.fg3, fontSize: 13)),
                  children: media.map((r) => MetaRow(r.$1, r.$2)).toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Панель распаковки: состояние, прогресс в процентах и в файлах/байтах, текущий файл.
  ///
  /// Показывает и завершённые состояния — «готово», «отменено», ошибку: панель объясняет,
  /// чем кончился последний запуск, и исчезнет только вместе с перезагрузкой деталки.
  /// Крестик отмены показывается лишь у живой задачи: отменять готовую нечего.
  Widget _unzipPanel() {
    final j = _job!;
    final busy = j.state == 'pending' || j.state == 'processing';
    // `cancelled` отличается от `failed`: задачу остановил пользователь, а не сервер,
    // и показывать это ошибкой было бы неправдой.
    final statusText = j.state == 'done'
        ? 'готово'
        : j.state == 'failed'
            ? 'ошибка'
            : j.state == 'cancelled'
                ? 'отменено'
                : '${j.percent}%';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.inventory_2_outlined, color: C.fg3, size: 18),
            const SizedBox(width: 6),
            const Text('Распаковка', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(statusText, style: const TextStyle(color: C.fg3, fontSize: 13)),
            if (busy)
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: _cancelUnzip),
          ]),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (j.percent / 100).clamp(0, 1), minHeight: 4, color: j.state == 'done' ? C.ok : C.accent),
          const SizedBox(height: 4),
          Text('файлов: ${j.doneEntries} из ${j.totalEntries} · ${fmt(j.doneBytes)} из ${fmt(j.totalBytes)}',
              style: const TextStyle(color: C.fg3, fontSize: 12)),
          if (busy && j.currentName != null)
            Text('сейчас: ${j.currentName}', style: const TextStyle(color: C.fg3, fontSize: 12)),
          if (j.error != null) Text(j.error!, style: const TextStyle(color: C.danger, fontSize: 12)),
        ],
      ),
    );
  }

  /// Откуда файл пришёл в облако: тема, отправитель и дата письма.
  ///
  /// Вложения писем лежат в скрытой зоне («Почта») и в «Файлах» не видны, поэтому деталка —
  /// единственное место, где видно происхождение записи. Данные идут вместе с метаданными
  /// (`FileMeta.mail`), отдельного запроса нет.
  Widget _mailOriginPanel(FileMeta m) {
    final mail = m.mail!;
    // Склеиваем «отправитель · дата», пропуская то, чего нет: у части писем не бывает ни
    // имени, ни разобранной даты, а пустая строка между точками читалась бы как сбой.
    final from = [
      mail.fromName ?? mail.fromAddr,
      if (mail.sortAt != null) fmtLocal(mail.sortAt),
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return Panel(
      child: Row(children: [
        const Icon(Icons.mail_outline, color: C.fg3, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mail.subject ?? '(без темы)', style: const TextStyle(color: C.fg, fontSize: 14)),
            Text(from, style: const TextStyle(color: C.fg3, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  /// Основные строки метаданных: имя, тип, размер, путь, даты, камера, координаты, хеш.
  ///
  /// Строки с неизвестными полями не показываются вовсе — пустых «Камера: —» в списке нет,
  /// поэтому состав строк у фото, видео и обычного файла разный.
  List<Widget> _metaRows(FileMeta m) {
    return [
      MetaRow('Имя', m.name),
      MetaRow('Тип', m.ext != null ? '${m.ext!.toUpperCase()} — ${m.mime}' : m.mime),
      MetaRow('Размер', fmt(m.size)),
      MetaRow('Расположение', m.path),
      if (m.createdAt != null) MetaRow('Создан', fmtLocal(m.createdAt) ?? m.createdAt!),
      // Время последнего изменения записи в облаке: сервер отдаёт его вместе с метаданными,
      // а показывать было нечего — «Изменён» отличается от «Создан» у всего, что перезалили
      // или переименовали, и по одной дате создания этого не видно.
      if (m.updatedAt != null) MetaRow('Изменён', fmtLocal(m.updatedAt) ?? m.updatedAt!),
      if (m.media?.capturedAt != null)
        MetaRow('Дата съёмки', fmtExifDate(m.media!.capturedAt) ?? (fmtLocal(m.media!.capturedAt) ?? m.media!.capturedAt!)),
      if ((m.media?.make?.isNotEmpty ?? false) || (m.media?.model?.isNotEmpty ?? false))
        MetaRow('Камера', [m.media!.make, m.media!.model].where((s) => s != null && s.isNotEmpty).join(' ')),
      if ((m.media?.width != null) && (m.media?.height != null))
        MetaRow('Кадр', '${m.media!.width} × ${m.media!.height}'),
      if (m.media?.latitude != null && m.media?.longitude != null)
        MetaRow('Координаты', '${m.media!.latitude!.toStringAsFixed(6)}, ${m.media!.longitude!.toStringAsFixed(6)}'),
      MetaRow('SHA-256', m.sha256, mono: true),
    ];
  }

  /// Каким превью показать файл, или `null`, если показывать нечем.
  ///
  /// Смотрим на mime, а для PDF ещё и на расширение: браузеры и почтовые клиенты кладут
  /// `application/octet-stream`, и без второй проверки такой PDF остался бы без превью.
  String? _previewKind(FileMeta m) {
    if (m.mime.startsWith('image/')) return 'image';
    if (m.mime.startsWith('video/')) return 'video';
    if (m.mime == 'application/pdf' || m.name.toLowerCase().endsWith('.pdf')) return 'pdf';
    return null;
  }

  /// Разводит превью по типу файла: у каждого свой виджет, потому что и источник данных,
  /// и отказы у картинки, видео и PDF разные (см. классы превью ниже).
  Widget _preview(CloudlyApi api, FileMeta m) {
    switch (_previewKind(m)) {
      case 'image':
        return ImagePreview(api: api, meta: m);
      case 'video':
        return VideoPreview(api: api, meta: m);
      case 'pdf':
        return PdfPreview(api: api, meta: m);
      default:
        return const SizedBox.shrink();
    }
  }

  /// Разворачивает `MediaMeta.raw` в строки «подпись → значение» для раскрывающегося списка
  /// «Все теги из файла».
  ///
  /// `raw` — сырые теги: EXIF у фото и ffprobe у видео, наборы разные, поэтому ветки по `kind`.
  /// Локальный `push` отсеивает пустое и дубли по имени: в EXIF одни и те же сведения приходят
  /// из разных блоков, а в списке строка должна быть одна.
  List<(String, String)> _mediaRows(Map<String, dynamic>? raw) {
    final rows = <(String, String)>[];
    if (raw == null) return rows;
    void push(String k, Object? v) {
      if (v == null || v == '') return;
      // Тег, который уже показан раньше (например, «Кадр» из блока камеры и из ffprobe),
      // второй раз не добавляем.
      if (rows.any((r) => r.$1 == k)) return;
      rows.add((k, v.toString()));
    }

    if (raw['kind'] == 'image') {
      push('Дата съёмки', fmtExifDate(raw['dateTimeOriginal']));
      push('Создан (EXIF)', fmtExifDate(raw['createDate']));
      push('Изменён (EXIF)', fmtExifDate(raw['modifyDate']));
      push('Часовой пояс', raw['offsetTime']);
      push('Камера', [raw['make'], raw['model']].whereType<String>().where((s) => s.isNotEmpty).join(' '));
      push('Объектив', raw['lens']);
      push('Выдержка', raw['exposureTime']);
      if (raw['fNumber'] is num) push('Диафрагма', 'f/${trimNum(raw['fNumber'] as num, 1)}');
      push('ISO', raw['iso']);
      if (raw['focalLength'] is num) push('Фокусное', '${trimNum(raw['focalLength'] as num, 1)} мм');
      if (raw['focalLength35'] is num) push('Фокусное (35 мм)', '${raw['focalLength35']} мм');
      push('Описание', raw['description']);
      push('Автор', raw['artist']);
      push('Copyright', raw['copyright']);
      push('ПО', raw['software']);
      if (raw['width'] != null && raw['height'] != null) push('Кадр', '${raw['width']} × ${raw['height']}');
    } else if (raw['kind'] == 'video') {
      // `fmtDuration`: значение уже проверено на `num`, то есть прочерк для «нет
      // длительности» здесь не нужен — строку без числа просто не показываем.
      if (raw['durationSec'] is num) push('Длительность', fmtDuration((raw['durationSec'] as num).toInt()));
      push('Контейнер', raw['container']);
      push('Видеокодек', raw['videoCodec']);
      push('Аудиокодек', raw['audioCodec']);
      if (raw['width'] != null && raw['height'] != null) push('Кадр', '${raw['width']} × ${raw['height']}');
      if (raw['fps'] is num) push('Кадров/с', (raw['fps'] as num).toStringAsFixed(2));
      push('Создан', fmtLocal(raw['createdAt']));
    }
    return rows;
  }
}

// ---------- превью ----------

/// Клиент для байтовых ответов превью: один на приложение, с таймаутами.
///
/// Свой клиент, а не общий `CloudlyApi`: здесь нужен `ResponseType.bytes`, а общий на этом
/// ответе разбирает JSON. Раньше на каждый запрос создавался новый `Dio` — без таймаутов
/// (зависший запрос висел бы вечно) и без общей настройки; один объект решает и это, и лишние
/// подключения. Заголовки авторизации по-прежнему берутся у [CloudlyApi], чтобы права не
/// разъезжались.
final Dio _bytesDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
  ),
);

/// Забирает ответ целиком в память.
///
/// Побочный эффект в том, что ответ копится в памяти целиком: чем больше файл, тем больше
/// память, поэтому вызывающий обязан сам решать, можно ли тянуть этот файл (см.
/// `_ImagePreviewState._load` — там второй стадией как раз приходит оригинал, и по размеру
/// он ограничен). [cancelToken] отменяет запрос при уходе с экрана: без него ответ приезжал
/// бы уже после `dispose`, а соединение держалось бы до конца.
Future<Uint8List> _fetchBytes(
  CloudlyApi api,
  String url, {
  CancelToken? cancelToken,
}) async {
  final res = await _bytesDio.get<List<int>>(
    url,
    cancelToken: cancelToken,
    options: Options(headers: api.authHeaders, responseType: ResponseType.bytes),
  );
  final data = res.data;
  // Пустой ответ — не картинка: `Image.memory` на пустых байтах падает внутри декодера, и
  // вместо строки «Превью не собрано» человек увидел бы пустое место. Такой ответ считаем
  // неудачей стадии, как и любую ошибку запроса.
  if (data == null || data.isEmpty) {
    throw ApiException(0, '', 'сервер вернул пустой ответ');
  }
  return Uint8List.fromList(data);
}

/// Превью картинки в две стадии: уменьшенная копия с сервера (1080 px) и, если её нет,
/// сам файл целиком.
///
/// Стадии нужны из-за асинхронной сборки превью: у только что загруженного кадра уменьшенной
/// копии ещё нет, и показать его можно только оригиналом. Обе стадии тянут ответ целиком
/// в память (см. `_fetchBytes`), поэтому превью здесь идёт первым — на нём же экономится
/// и трафик, и память в самом частом случае. Вторая стадия работает только для файлов
/// разумного размера (см. [_maxOriginalPreviewBytes]).
class ImagePreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const ImagePreview({super.key, required this.api, required this.meta});
  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

/// Состояние превью: какая стадия грузится и что уже получено.
class _ImagePreviewState extends State<ImagePreview> {
  int _stage = 0; // 0 превью, 1 оригинал inline, 2 нечем
  /// Байты картинки для `Image.memory`; `null` — ещё грузим или не получилось.
  Uint8List? _bytes;
  /// Отмена запроса вместе с виджетом: без неё ответ на 80-мегабайтный оригинал продолжал бы
  /// качаться в память после ухода с экрана.
  final _cancel = CancelToken();

  @override
  /// Первая стадия грузится сразу: превью с сервера.
  void initState() {
    super.initState();
    _load();
  }

  @override
  /// Уход с экрана отменяет текущий запрос превью.
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  /// Грузит текущую стадию, а при неудаче переходит на следующую.
  ///
  /// Адрес зависит от стадии: 0 — `previewUrl` по sha256 (готовое превью шириной 1080), иначе —
  /// `fileInlineUrl` по id записи, то есть сам файл. Вторая стадия включается только если файл
  /// не больше [_maxOriginalPreviewBytes]: оригинал приходит в память целиком, и на RAW или
  /// панораме это OOM. Провал второй стадии останавливает попытки — тогда в `build`
  /// показывается «Превью не собрано».
  ///
  /// Побочно: `_bytes` и перерисовка. Запрос отменяется в `dispose`, поэтому ответ может
  /// прийти уже к мёртвому виджету — состояние трогаем только при `mounted`.
  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _bytes = null);
    final original = widget.meta.size <= _maxOriginalPreviewBytes;
    final url = _stage == 0
        ? widget.api.previewUrl(widget.meta.sha256, w: 1080)
        : widget.api.fileInlineUrl(widget.meta.id);
    if (_stage > 0 && !original) {
      // Оригинал слишком велик, чтобы тянуть его в память: дальше показывать нечего.
      setState(() => _stage = 2);
      return;
    }
    try {
      final b = await _fetchBytes(widget.api, url, cancelToken: _cancel);
      if (!mounted) return;
      setState(() => _bytes = b);
    } catch (_) {
      if (!mounted) return;
      if (_stage == 0) {
        setState(() => _stage = 1);
        await _load();
      } else {
        setState(() => _stage = 2);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // cacheWidth — ширина декодированного кадра: полноразмерный оригинал на телефоне
          // всё равно не показывается целиком, а распакованный кадр — это в разы больше
          // памяти, чем сжатые байты.
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            width: double.infinity,
            cacheWidth: _previewCacheWidth,
          ),
        ),
      );
    }
    if (_stage >= 2) return _note();
    return const SizedBox(
      height: _imageBoxH,
      child: Center(child: CircularProgressIndicator()),
    );
  }

  /// Заглушка вместо картинки: превью не собралось, а показать оригинал нечем — файла нет
  /// или он больше [_maxOriginalPreviewBytes].
  ///
  /// Текст в двух случаях разный: «слишком велик» — это не сбой сборки превью, а наше решение
  /// не тянуть файл в память, и читать про это надо другое. Кнопка «Скачать» здесь, а не только
  /// в AppBar: это единственное, что осталось сделать с файлом.
  Widget _note() {
    final text = widget.meta.size > _maxOriginalPreviewBytes
        ? 'Файл слишком велик для показа здесь — откройте его через «Скачать»'
        : 'Превью не собрано';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(child: Text(text, style: const TextStyle(color: C.fg3))),
        TextButton(
          onPressed: () => _download(context, widget.api, widget.meta),
          child: const Text('Скачать'),
        ),
      ]),
    );
  }
}

/// Проигрыватель видео в деталке: сначала серверное превью, потом сам файл.
///
/// Фолбэк на оригинал нужен не «на всякий случай»: у ассетов, пересобранных до перехода
/// на H.264, превью лежит в AV1, а iOS и старые Safari декодируют его далеко не всегда
/// (см. media.controller.videoPreview). Поэтому вторая стадия — это `?src=original`,
/// то есть отдача исходного файла как есть. Если не заиграло и оно, показываем строку
/// «Видео не проигрывается на этом устройстве» с кнопкой «Скачать» — снаружи файл откроет
/// системный плеер, у которого свои кодеки.
class VideoPreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const VideoPreview({super.key, required this.api, required this.meta});
  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

/// Состояние проигрывателя: контроллер, стадия и признак «не заиграло совсем».
class _VideoPreviewState extends State<VideoPreview> {
  /// 0 — превью с сервера, 1 — оригинал файла (`?src=original`).
  int _stage = 0;
  /// Контроллер текущей стадии; `null` — прежний уже уничтожен, новый ещё не создан.
  VideoPlayerController? _c;
  bool _failed = false;
  /// Номер запуска плеера: пока `initialize()` предыдущего ждёт, мог начаться следующий
  /// (фолбэк), и ответ устаревшего запуска не должен ни играть, ни ронять текущий.
  int _gen = 0;

  @override
  /// Сразу поднимаем плеер с серверным превью.
  void initState() {
    super.initState();
    _init();
  }

  @override
  /// Снимаем подписку и уничтожаем плеер вместе с виджетом.
  void dispose() {
    // Слушателя снимаем до dispose контроллера: иначе он успел бы дёрнуть `_fallback`
    // по уже уничтоженному плееру. Номер запуска растёт: завершение `initialize()` в полёте
    // больше ничего не тронет (см. `_init`).
    _gen++;
    _c?.removeListener(_onEvent);
    _c?.dispose();
    _c = null;
    super.dispose();
  }

  /// Создаёт контроллер для текущей стадии и запускает воспроизведение.
  ///
  /// Побочно: `_c`, подписка на события контроллера, автозапуск (`play`) после успешной
  /// инициализации и, при неудаче, `_fallback`. Автозапуск здесь уместен: пользователь пришёл
  /// посмотреть файл, а не в список — но именно он чаще всего и падает по кодекам, поэтому
  /// ошибки ловятся и отсюда, и из `_onEvent`. Свой номер запуска отсекает ответы прежних:
  /// два `_init` подряд (фолбэк поверх ещё не завершившейся инициализации) иначе подрались бы
  /// за один и тот же `_c`.
  Future<void> _init() async {
    if (!mounted) return;
    final gen = ++_gen;
    final url = _stage == 0
        ? widget.api.videoPreviewUrl(widget.meta.sha256)
        : widget.api.videoPreviewUrl(widget.meta.sha256, original: true);
    final c = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: widget.api.authHeaders);
    _c = c;
    c.addListener(_onEvent);
    try {
      await c.initialize();
      if (!mounted || gen != _gen) return;
      setState(() {});
      await c.play();
    } catch (_) {
      if (!mounted || gen != _gen) return;
      _fallback();
    }
  }

  /// Слушает контроллер на предмет ошибки.
  ///
  /// `initialize()` — не единственная точка отказа: поток может не открыться уже после неё
  /// (не тот кодек, обрыв), и тогда контроллер сам сообщает `hasError`. Без этого слушателя
  /// такой ролик навсегда остался бы на спиннере.
  void _onEvent() {
    if (!mounted) return;
    if (_c?.value.hasError ?? false) _fallback();
  }

  /// Откат к следующей стадии, а если их больше нет — к признаку «не проигрывается».
  ///
  /// Побочно: старый контроллер уничтожается (иначе он держал бы декодер и поток), при
  /// `_stage < 1` номер стадии растёт и `_init` пробует оригинал, иначе ставится `_failed`.
  /// Вызывается и из ответа, пришедшего после ухода с экрана (`initialize()` в полёте), поэтому
  /// первым делом проверяется `mounted`: без этого был бы `setState` после `dispose`, а
  /// контроллер уничтожался бы повторно.
  void _fallback() {
    if (!mounted) return;
    final c = _c;
    // Зануляем до dispose: слушатель и повторный вход увидят «контроллера нет», а не
    // уничтоженный объект.
    _c = null;
    c?.removeListener(_onEvent);
    c?.dispose();
    if (_stage < 1) {
      setState(() => _stage++);
      _init();
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Expanded(child: Text('Видео не проигрывается на этом устройстве', style: TextStyle(color: C.fg3))),
          TextButton(
            onPressed: () => _download(context, widget.api, widget.meta),
            child: const Text('Скачать'),
          ),
        ]),
      );
    }
    final c = _c;
    if (c != null && c.value.isInitialized) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio,
            child: Stack(alignment: Alignment.center, children: [
              VideoPlayer(c),
              _PlayPause(c),
            ]),
          ),
        ),
      );
    }
    return const SizedBox(height: _imageBoxH, child: Center(child: CircularProgressIndicator()));
  }
}

/// Кнопка play/pause поверх видео: своего набора элементов управления у `VideoPlayer` нет,
/// а без него ролик нельзя ни остановить, ни запустить заново.
class _PlayPause extends StatelessWidget {
  final VideoPlayerController c;
  const _PlayPause(this.c);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => c.value.isPlaying ? c.pause() : c.play(),
      child: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
          size: 48, color: _overlayFg),
    );
  }
}

/// Превью PDF постранично: сервер рендерит страницу в картинку, клиент показывает её
/// с переключателем страниц.
///
/// Число страниц приходит не сразу: сервер узнаёт его, разбирая файл, и родительская деталка
/// опрашивает метаданные (`_FileDetailScreenState._load`), передавая сюда новые `meta`.
/// Поэтому первая загрузка стартует не в `initState`, а в `didUpdateWidget` — в момент,
/// когда `pageCount` наконец появился.
class PdfPreview extends StatefulWidget {
  final CloudlyApi api;
  final FileMeta meta;
  const PdfPreview({super.key, required this.api, required this.meta});
  @override
  State<PdfPreview> createState() => _PdfPreviewState();
}

/// Состояние постраничного превью: текущая страница, её картинка и признак неудачи.
class _PdfPreviewState extends State<PdfPreview> {
  int _page = 1;
  Uint8List? _bytes;
  bool _failed = false;
  /// Отмена запроса страницы вместе с виджетом: иначе ответ продолжал бы ехать после ухода
  /// с экрана, а соединение держалось бы до конца.
  final _cancel = CancelToken();

  /// Число страниц из метаданных; 0 — сервер их ещё не посчитал (тогда превью не запросить).
  int get _pages => widget.meta.pageCount ?? 0;

  @override
  /// Первую страницу грузим только если сервер уже посчитал число страниц.
  void initState() {
    super.initState();
    // Загружаем сразу только если число страниц уже известно: иначе запрашивать нечего.
    if (_pages > 0) _load();
  }

  @override
  /// Уход с экрана отменяет запрос страницы.
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  @override
  /// Ловит момент, когда метаданные дозались и число страниц наконец появилось.
  void didUpdateWidget(covariant PdfPreview old) {
    super.didUpdateWidget(old);
    // Момент, когда метаданные дозагрузились: было 0 страниц, стало больше — самое время
    // показать первую. Повторные перерисовки с тем же pageCount загрузку не запускают.
    if ((old.meta.pageCount ?? 0) == 0 && _pages > 0) _load();
  }

  /// Загружает картинку текущей страницы (сервер рендерит её по sha256 и номеру страницы).
  ///
  /// Побочно: сбрасывает прошлую картинку и признак неудачи, затем перерисовывает; при ошибке
  /// ставит `_failed` — вместо картинки покажется строка «Превью страницы не собралось».
  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _bytes = null;
      _failed = false;
    });
    try {
      final b = await _fetchBytes(
        widget.api,
        widget.api.pdfPageUrl(widget.meta.sha256, _page),
        cancelToken: _cancel,
      );
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pages == 0) {
      return const SizedBox(height: _pdfBoxH, child: Center(child: CircularProgressIndicator()));
    }
    return Column(children: [
      if (_bytes != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
            width: double.infinity,
            cacheWidth: _previewCacheWidth,
          ),
        )
      else if (_failed)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const Expanded(child: Text('Превью страницы не собралось', style: TextStyle(color: C.fg3))),
            TextButton(
              onPressed: () => _download(context, widget.api, widget.meta),
              child: const Text('Скачать'),
            ),
          ]),
        )
      else
        const SizedBox(height: _pdfBoxH, child: Center(child: CircularProgressIndicator())),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        // Номер страницы меняется в состоянии, а картинка запрашивается отдельно: `_load`
        // сначала сбрасывает прошлую, поэтому промежуточный кадр не мелькает.
        IconButton(
          icon: const Icon(Icons.chevron_left, color: C.fg),
          onPressed: _page <= 1 ? null : () { setState(() => _page--); _load(); },
        ),
        Text('$_page / $_pages', style: const TextStyle(color: C.fg3)),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: C.fg),
          onPressed: _page >= _pages ? null : () { setState(() => _page++); _load(); },
        ),
      ]),
    ]);
  }
}
