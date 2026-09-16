import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import '../data/queue_store.dart';
import '../device/media_rules.dart';
import '../mirror/mirror_status.dart';
import '../queue/upload_runner.dart';
import '../section.dart';
import '../sync_controller.dart';

/// Раздел «Очередь»: что нашлось в выбранных папках и ждёт выгрузки, плюс короткая сводка
/// о том, что синхронизатор делает прямо сейчас. Это единственный экран синхронизации.
///
/// Кнопок «включить» и «сверить» здесь нет намеренно: зеркало работает само — и пока
/// приложение открыто, и в фоне заданием системы. Ручным остаётся только запуск конкретного
/// файла из очереди («Фото» выгружается по кнопке, как и раньше) и предохранитель от
/// массового удаления: если движок его приостановил, подтверждение должно быть доступно.
///
/// Открывается из «Настроек» → «Синхронизация» (см. `features/settings/sync_panel.dart`).
/// Все данные берутся у [SyncController] и из базы очереди; своих копий экран не держит,
/// кроме того, что показывает прямо сейчас.
///
/// ## Где живёт состояние очереди (и почему это не одно место)
///
/// Источник правды — [SyncController]: он владеет базой очереди, наполняет её, выгружает
/// строки и знает состояние зеркала. Экран **читает** строки и счётчики прямо из `QueueStore`
/// (одним запросом на перерисовку) и подписан на состояние контроллера: перечитывание
/// запускают изменения `waiting` (сколько ждёт выгрузки), `activity` (работа началась или
/// закончилась) и предохранителя удалений. Прогресс ручной выгрузки — третий источник,
/// и он живёт на экране ([_progress]).
///
/// Из этого следует ограничение: строки, которые изменились, не тронув ни `waiting`,
/// ни `activity`, экран увидит только при следующем перечитывании. Правильное решение —
/// один владелец и поток изменений из стора, экран рисует то, что пришло; это правка
/// `sync_controller.dart` (владелец файла), сюда она не входит.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

/// Состояние экрана: строки очереди, счётчики по состояниям и текущая выгрузка.
///
/// Список перечитывается после каждой операции и по сигналу контроллера: очередь наполняется
/// в фоне, и держать её в памяти экрана значило бы показывать устаревшее.
class _QueueScreenState extends ConsumerState<QueueScreen> {
  /// Строки очереди: база отдаёт их не больше 2000 за раз и в порядке «сначала то, что
  /// выгружается, потом ожидающее, потом ошибки, потом всё остальное» (`QueueStore.items`).
  /// [total] — сколько строк в очереди всего: по нему видно, что список показан не целиком.
  List<QueueItem> _items = const [];
  Map<QueueState, int> _counts = const {};
  int _total = 0;

  /// Первое чтение ещё не закончилось / идёт проверка синхронизации по кнопке или при открытии.
  bool _loading = true;
  bool _checking = false;

  /// Выгрузка одного файла, запущенная вручную: пока она идёт, строка показывает проценты.
  /// `null` — ручной выгрузки нет.
  ///
  /// [ValueNotifier], а не поле состояния экрана: `onProgress` зовётся на каждый отправленный
  /// кусок, и `setState` на каждое такое сообщение перестраивал бы весь список ради одной
  /// строки. Слушает его только та строка, чей файл сейчас выгружается (см. [_row]).
  final ValueNotifier<UploadProgress?> _progress = ValueNotifier(null);

  /// Сколько удалений в облаке движок приостановил и почему. Живёт в базе зеркала, поэтому
  /// читается заново после каждого прохода, а не помнится с прошлого раза.
  (int, String)? _blocked;

  /// Контроллер синхронизации: у него — база очереди, состояние зеркала и все действия
  /// (проверка, выгрузка файла, подтверждение удалений).
  SyncController get _sync => ref.read(syncControllerProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    unawaited(_refreshBlocked());
    // При открытии раздела синхронизация проверяет себя сама: кнопок «сверить» и «включить»
    // больше нет, а встать она может без спроса — кончился бюджет времени, оборвалась сеть,
    // система прибила фоновое задание. Флаг ставим полем: первый кадр ещё не построен,
    // и setState здесь не нужен.
    _checking = true;
    unawaited(_check(initial: true));
  }

  @override
  void dispose() {
    // notifier живёт ровно столько же, сколько экран: без dispose он пережил бы его
    _progress.dispose();
    super.dispose();
  }

  /// Прочитать очередь из базы, если она уже открыта.
  ///
  /// База появляется только после входа в аккаунт: до него `queueStore` равен `null`, и экран
  /// просто перестаёт показывать загрузку — [_body] в этом случае показывает, что нужно войти.
  /// `mounted` проверяется после каждого `await`: чтение базы переживает закрытие экрана.
  Future<void> _reload() async {
    final store = _sync.queueStore;
    if (store == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final items = await store.items();
    final counts = await store.counts();
    if (!mounted) return;
    setState(() {
      _items = items;
      _counts = counts;
      // очередь показывается порциями: если строк больше, об усечении надо сказать,
      // иначе «в очереди 2000» выглядит как правда о всей очереди
      _total = counts.values.fold(0, (a, b) => a + b);
      _loading = false;
    });
  }

  /// Перечитать сведения о приостановленных удалениях: движок мог поставить предохранитель
  /// или снять его. Возвращает `null`, если удаления не приостановлены.
  Future<void> _refreshBlocked() async {
    final info = await _sync.blockedInfo();
    if (mounted) setState(() => _blocked = info);
  }

  /// «Проверить и догнать»: то же, что делает раздел при открытии, но по кнопке.
  ///
  /// Ядро само решает, что нужно: заново выпустить токен, обновить очередь, пересобрать
  /// наблюдение за папками, прогнать зеркало и выгрузить ждущие файлы. Здесь остаётся
  /// только показать, что проверка идёт, и перечитать список.
  ///
  /// У кнопки проход зеркала просят явно (`mirror: true`): нажатие значит «сделай сейчас»,
  /// и ждать, пока проход «устареет», человеку нечем. При открытии раздела проход идёт
  /// по обычным поводам — иначе каждый заход в раздел гонял бы обход диска зря.
  Future<void> _check({bool initial = false}) async {
    if (_checking && !initial) return;
    if (initial) {
      _checking = true;
    } else {
      setState(() => _checking = true);
    }
    try {
      await _sync.checkAndResume(mirror: !initial);
    } finally {
      if (mounted) setState(() => _checking = false);
      await _reload();
      await _refreshBlocked();
    }
  }

  /// Убрать из списка строки, которые уже не ждут выгрузки. Действие только над базой очереди:
  /// сами файлы и облако не трогаются.
  Future<void> _clearFinished() async {
    await _sync.queueStore?.clearFinished();
    await _reload();
  }

  /// Подтверждение — ровно один проход: после него предохранитель снова на месте,
  /// если файлы продолжают пропадать.
  Future<void> _confirmDeletes() async {
    await _sync.confirmDeletes();
    await _refreshBlocked();
  }

  /// Выгрузка одного файла. Пока она идёт, состояние строки показываем по байтам, а не
  /// «в очереди»: иначе непонятно, работает ли что-нибудь вообще.
  Future<void> _upload(int id, {bool retry = false}) async {
    if (_progress.value != null) return;
    if (retry) await _sync.queueStore?.markPending(id);
    await _reload();
    _progress.value = UploadProgress(id: id, name: '', sent: 0, total: 0);
    try {
      await _sync.uploadItem(
        id,
        onProgress: (p) => _progress.value = p,
      );
    } finally {
      _progress.value = null;
      await _reload();
    }
  }

  /// Сколько ждёт выгрузки: в очереди и с ошибкой. Оба состояния требуют внимания, а
  /// «выгружен» и «уже в облаке» — нет, поэтому в шапке считается только это.
  int get _waiting =>
      (_counts[QueueState.pending] ?? 0) + (_counts[QueueState.failed] ?? 0);

  @override
  Widget build(BuildContext context) {
    // очередь меняется сама: наполнение идёт в фоне, поэтому счётчик ожидающих —
    // единственный признак, по которому экран надо перечитать
    ref.listen(syncControllerProvider.select((c) => c.waiting), (prev, next) {
      if (prev != next) unawaited(_reload());
    });
    // Работа закончилась (`activity` стал пустым) — строки могли сменить состояние, не изменив
    // счётчик ожидающих: `running → done` его не двигает, и «грузится» осталось бы на экране
    // до перезахода. Пустой текст — единственный признак «ядро свободно», который у экрана есть
    ref.listen(syncControllerProvider.select((c) => c.activity), (prev, next) {
      if (prev != null && next == null) unawaited(_reload());
    });
    // предохранитель ставит движок по ходу прохода: экран узнаёт об этом из состояния, а не
    // из собственного опроса базы
    ref.listen(syncControllerProvider.select((c) => c.mirrorStatus.blocked), (
      prev,
      next,
    ) {
      if (prev != next) unawaited(_refreshBlocked());
    });
    final sync = ref.watch(syncControllerProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Очередь', style: TextStyle(color: C.fg, fontSize: 17)),
            Text(
              _countsLine(short: true),
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _items.isEmpty
                ? null
                : () => unawaited(_clearFinished()),
            child: const Text('Очистить готовые'),
          ),
          IconButton(
            tooltip: 'Проверить и догнать',
            onPressed: _checking ? null : () => unawaited(_check()),
            icon: const Icon(Icons.refresh, color: C.fg),
          ),
        ],
      ),
      body: _body(sync),
    );
  }

  /// Тело экрана: сводка, предохранитель, список строк и полоска проверки.
  ///
  /// Проверка идёт поверх списка (`Stack`), потому что она не должна сдвигать строки: список
  /// во время проверки остаётся читаемым, а полоска только говорит, что нажатие сработало.
  Widget _body(SyncController sync) {
    if (sync.queueStore == null) {
      return _centered('Синхронизация не запущена: войдите в аккаунт');
    }
    final status = sync.mirrorStatus;
    // Пока ядро что-то делает (проверка, догон, выгрузка ждущих), запускать файл руками
    // нечего: он уже в работе. Иначе две выгрузки одного файла пошли бы наперегонки.
    final busy = _checking || (sync.activity?.isNotEmpty ?? false);
    return Stack(
      children: [
        Column(
          children: [
            _statusHeader(sync, status),
            if (_counts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _countsLine(),
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ),
            if (_blocked != null) _blockedNotice(_blocked!),
            if (_total > _items.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'показаны первые ${_items.length} из $_total строк',
                    style: const TextStyle(color: C.fg3, fontSize: 11),
                  ),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_items.isEmpty
                        ? _empty()
                        : ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (context, i) => _row(_items[i], busy),
                          )),
            ),
          ],
        ),
        // Тонкая полоска только на время проверки: она длится секунды и без неё непонятно,
        // нажалась ли кнопка. У выгрузки признак свой — проценты в её строке.
        if (_checking)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  /// Шапка состояния: что происходит сейчас и чем закончился последний проход.
  /// Обе строки — текст: считать на экране нечего, зеркало делает это само.
  Widget _statusHeader(SyncController sync, MirrorStatus status) {
    final last = status.lastText.isEmpty ? 'ещё не сверялось' : status.lastText;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'сейчас: ${_now(sync, status)}',
            style: const TextStyle(color: C.fg, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'последний проход: $last',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.fg3, fontSize: 11),
          ),
          // Что вышло у последней проверки очереди: сколько файлов просмотрено, сколько строк
          // поставлено и — главное — не упёрся ли обход в предел (`DeviceFiles.hardMax`).
          // Без этой строки о пределе не было сказано нигде: файлы сверх него в очередь
          // не попадают никогда, а человек видел просто короткую очередь и не знал причины.
          if ((sync.queueNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'очередь: ${sync.queueNote}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
          const SizedBox(height: 4),
          const Text(
            'Выгружается само; play на строке — если хочешь поторопить.',
            style: TextStyle(color: C.fg3, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Что делает синхронизатор прямо сейчас. Прогресс — словами («— 45%»), а не полоской:
  /// одна строка отвечает на вопрос «идёт или нет» без отдельного индикатора.
  String _now(SyncController sync, MirrorStatus status) {
    final activity = sync.activity;
    if (activity != null && activity.isNotEmpty) return activity;
    // Проверку при открытии раздела ядро может делать молча — тогда говорим об этом мы
    if (_checking) return 'проверяю, не встала ли синхронизация…';
    final name = status.currentName;
    if (status.busy && name != null && name.isNotEmpty) {
      final percent = status.currentPercent;
      return '${_phaseText(status.phase)} «$name»'
          '${percent > 0 ? ' — $percent%' : ''}';
    }
    return _phaseText(status.phase);
  }

  /// Предохранитель: удаления в облаке приостановлены. Он должен быть виден и сниматься
  /// ровно по кнопке — молча удалять «слишком много пропавшего» движок не станет.
  Widget _blockedNotice((int, String) blocked) {
    final (count, reason) = blocked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.danger),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Удаления в облаке приостановлены: $count',
              style: const TextStyle(color: C.fg, fontSize: 13),
            ),
            if (reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(reason, style: const TextStyle(color: C.fg3, fontSize: 11)),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => unawaited(_confirmDeletes()),
              child: Text('Удалить эти $count в облаке'),
            ),
          ],
        ),
      ),
    );
  }

  /// Строка счётчиков: в шапке — коротко (очередь и зеркало), в теле — по состояниям.
  String _countsLine({bool short = false}) {
    if (short) {
      final mine = _waiting == 0
          ? 'нечего выгружать'
          : 'в очереди: $_waiting — выгружается само';
      final mirror = _sync.mirrorStatus.waitingFiles;
      return '$mine · зеркало: '
          '${mirror == 0 ? 'всё выгружено' : 'ждёт выгрузки: $mirror'}';
    }
    final parts = <String>[];
    for (final state in QueueState.values) {
      final n = _counts[state] ?? 0;
      if (n > 0) parts.add('${_stateText(state)}: $n');
    }
    return parts.join(' · ');
  }

  /// Строка списка: иконка по типу файла, имя, подпись (куда и сколько) и кнопки.
  ///
  /// Запустить файл вручную можно только у ждущего и у упавшего: у «выгружается» работа уже
  /// идёт, у «выгружен» — нечего делать. [busy] передаётся сверху и запрещает запуск, пока
  /// ядро занято чем-то своим: иначе две выгрузки одного файла пошли бы наперегонки.
  ///
  /// Подпись строки подписана на [_progress]: проценты меняются на каждый кусок, и перерисовка
  /// нужна только той строке, чей файл выгружается, — остальные от notifier не зависят.
  Widget _row(QueueItem item, bool busy) {
    return ValueListenableBuilder<UploadProgress?>(
      valueListenable: _progress,
      builder: (context, running, _) {
        final progress = running?.id == item.id ? running : null;
        final canStart =
            !busy &&
            running == null &&
            (item.state == QueueState.pending || item.state == QueueState.failed);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    MediaRules.isVideo(item.name)
                        ? Icons.movie_outlined
                        : (MediaRules.isImage(item.name)
                              ? Icons.image_outlined
                              : Icons.insert_drive_file_outlined),
                    color: C.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.fg, fontSize: 15),
                        ),
                        Text(
                          progress == null
                              ? _subtitle(item)
                              // размер известен не с первого байта: пока его нет, «0% из 0 Б»
                              // читалось бы как сломанный счётчик
                              : (progress.total <= 0
                                    ? 'выгрузка…'
                                    : 'выгрузка: ${progress.percent}% из ${fmt(progress.total)}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.fg3, fontSize: 11),
                        ),
                        if (item.state == QueueState.failed &&
                            (item.lastError ?? '').isNotEmpty)
                          Text(
                            item.lastError!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: C.danger, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                  // «повторить» отличается от «play» только тем, что снимает состояние ошибки:
                  // так видно, что попытка не первая
                  if (item.state == QueueState.failed)
                    IconButton(
                      tooltip: 'Повторить',
                      onPressed: canStart
                          ? () => unawaited(_upload(item.id, retry: true))
                          : null,
                      icon: const Icon(Icons.replay, color: C.fg3, size: 20),
                    ),
                  IconButton(
                    tooltip: 'Поторопить: выгрузить сейчас',
                    onPressed: canStart ? () => unawaited(_upload(item.id)) : null,
                    icon: const Icon(Icons.play_arrow, color: C.accent),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  /// Пустая очередь. Это не «ничего не происходит»: синхронизация работает сама, поэтому
  /// в тексте сказано и про это, а кнопка оставлена для случая, когда что-то всё же встало.
  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Пока нечего выгружать: всё, что нашлось в выбранных папках, уже в облаке',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Дальше синхронизация идёт сама: раздел при открытии проверяет, не встала ли она, '
            'и догоняет пропущенное.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.fg3, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _checking ? null : () => unawaited(_check()),
            child: const Text('Проверить сейчас'),
          ),
        ],
      ),
    );
  }

  /// Строка для случая, когда синхронизация ещё не запущена (не выполнен вход в аккаунт):
  /// показывать пустую очередь тут нельзя — это выглядело бы как «выгружать нечего».
  Widget _centered(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: const TextStyle(color: C.fg3, fontSize: 13)),
      ),
    );
  }

  /// Подпись строки: раздел, место в облаке, размер и состояние. `relDir` может быть пустым —
  /// это значит, что файл лежит прямо в выбранной папке, и вместо пустоты пишем «плоско».
  String _subtitle(QueueItem item) {
    final where = item.section == Section.photos ? 'Фото' : 'Файлы';
    final place = item.relDir.isEmpty ? 'плоско' : item.relDir;
    return '$where · $place · ${fmt(item.size)} · ${_stateText(item.state)}';
  }

  /// Состояние строки словами. `switch` без `default` намеренно: новое состояние в [QueueState]
  /// сломает сборку, а не покажется человеку пустой подписью.
  String _stateText(QueueState state) => switch (state) {
    QueueState.pending => 'в очереди',
    QueueState.running => 'грузится',
    QueueState.done => 'выгружен',
    QueueState.skipped => 'уже в облаке',
    QueueState.failed => 'ошибка',
  };

  /// Фаза прохода зеркала словами: этим отвечает строка «сейчас: …», когда ядро сообщает только
  /// фазу, без имени файла.
  String _phaseText(MirrorPhase phase) => switch (phase) {
    MirrorPhase.scan => 'обхожу папки',
    MirrorPhase.cloud => 'сверяюсь с облаком',
    MirrorPhase.upload => 'выгружаю',
    MirrorPhase.delete => 'убираю удалённое',
    MirrorPhase.idle => 'ждёт',
  };
}
