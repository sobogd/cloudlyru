import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/mirror_store.dart';
import '../device/hasher.dart';
import '../device/media_rules.dart';
import '../device/native_fs.dart';
import '../net/sync_api.dart';
import 'failure_streak.dart';
import 'mirror_folders.dart';
import 'mirror_models.dart';
import 'mirror_rules.dart';

/// Облачная сторона зеркала: то, что изменилось в облаке, доезжает до телефона.
///
/// Два источника, и оба нужны:
///   • журнал изменений (`GET /sync/changes`) — обычный путь, курсор по `seq`;
///   • полный проход по содержимому папок — когда курсора ещё нет (зеркало только включили)
///     или когда сервер ответил `resetRequired` (журнал подрезан, догнать по нему нельзя).
///
/// Свои же правки пропускаются: в строке журнала есть `deviceId`, и строка, сделанная этим
/// устройством, локально уже учтена — иначе собственная выгрузка приезжала бы назад и догон
/// зацикливался бы.
///
/// Удаления из облака применяются к телефону потому, что это явное указание сервера, а не
/// догадка по неполному снимку (так же ведёт себя Google Drive). Предохранители всё же есть,
/// и все — на стороне телефона: удаляется только то, что знает зеркало (по своей строке),
/// только внутри выбранных сейчас папок и только если файл на месте не менялся — изменённый
/// уходит конфликтной копией, а не под нож. Страховка сверху — корзина на сервере: 30 дней
/// и восстановление.
///
/// Инвариант хранилища, на котором держится вся сверка: строка `files` — единственная связь
/// пути на телефоне с облачной записью (ключ таблицы — путь), поэтому `entry_id` обязан
/// встречаться в ней ровно один раз. Две строки с одной записью облака означают, что один
/// из путей опишет несуществующий файл, и выгрузка унесёт живую запись в корзину.
///
/// Создаётся движком на каждый проход — своя копия на [MirrorEngine.pass] (там же считается
/// облако → телефон) и своя на [MirrorEngine.catchUpCloud] (только журнал, без диска).
/// Счётчики обнуляются вместе с ней: читать их нужно сразу после прохода.
class MirrorPull {
  /// @param _deviceId номер этого устройства из `/auth/me` (может быть `null`); @param _onProgress
  ///        получатель строк о ходе работы; @param native мост к Android — подменяется в тестах.
  MirrorPull(
    this._api,
    this._store,
    this._deviceId,
    this._onProgress, {
    NativeFs? native,
  }) : _native = native ?? NativeFs();

  final SyncApi _api;
  final MirrorStore _store;

  /// Номер устройства из `/auth/me`: по нему отсеиваются правки, сделанные этим же телефоном.
  /// `null` — сервер не сказал, и тогда отсеивать нечего: строки применяются все.
  final String? _deviceId;

  /// Куда писать ход работы: строки уходят в отчёт о проходе, а не в интерфейс напрямую.
  final void Function(String) _onProgress;

  /// Мост к Android: нужен за номером файла для скачанного файла.
  final NativeFs _native;

  /// Потолок страниц журнала за один проход: 200 страниц по 200 строк — это 40 000 изменений.
  /// Остаток доедет следующим проходом, и обрыв здесь безопасен: курсор двигается постранично
  /// (см. [catchUp]), а применение строки идемпотентно.
  static const int _maxPages = 200;

  /// Потолок глубины обхода облака: защита от петли в дереве.
  ///
  /// Совпадает с серверным `MAX_PATH_SEGMENTS` (64) не случайно: клиент не должен показывать
  /// пользователю дерево глубже, чем сервер согласен хранить.
  static const int _maxDepth = 64;

  /// Сколько имён неудавшихся записей попадает в отчёт: по счётчику «ошибок: N» нельзя понять,
  /// что именно не доехало, а весь список на большой папке раздул бы отчёт.
  static const int _maxProblems = 5;

  /// Ключ счётчика «строка журнала не применяется который проход подряд».
  ///
  /// Лежит в базе зеркала, потому что [MirrorPull] заводится на каждый проход, а решение
  /// принимается по нескольким. Ключ свой, а не из `MirrorStore`: это состояние разбора
  /// журнала, а не хранилища файлов. Значение — «seq|сколько раз».
  static const String _stuckKey = 'changes_stuck';

  /// После стольких неудачных попыток строку журнала пропускаем: иначе одна запись с именем,
  /// которое не примет файловая система, навсегда закрыла бы собой весь журнал.
  static const int _stuckLimit = 3;

  int downloaded = 0;
  int deletedLocal = 0;
  int conflicts = 0;
  int failed = 0;
  int renamedLocal = 0;

  /// Проход прерван по времени или по отмене: остаток доедет следующим заходом.
  bool stopped = false;

  /// Отказ авторизации устройства (401/403): токен отозван или истёк, нужен новый.
  bool authFailed = false;

  /// Первые имена того, что не доехало: их забирает отчёт о проходе.
  final List<String> problems = <String>[];

  /// Ошибка, после которой проход дальше не имеет смысла (нет сети, отозван токен).
  ///
  /// Пока она не пуста, обход прекращается: движок увидит её через [MirrorEngine._fill] и
  /// закончит проход с этой ошибкой, не переходя к выгрузке.
  String? fatal;

  /// Сбои скачивания подряд: без счётчика проход ждал бы таймаута на каждом файле.
  final FailureStreak _downloads = FailureStreak();

  /// Сбои листинга облачных папок подряд: та же причина, что у скачивания, но другой запрос.
  final FailureStreak _cloud = FailureStreak();

  /// Полный проход по папкам зеркала: состояние облака переносится на телефон.
  ///
  /// @param isCancelled опрос отмены и @param deadlineMs метка конца бюджета прохода: облачная
  ///        часть идёт до диска и сети так же долго, как выгрузка, и без них её обрывала бы
  ///        система, а не сам проход. Обрыв безопасен: сделанное записано, остальное доедет
  ///        следующим проходом, а полный обход от этого не «застревает» — он просто начнётся
  ///        заново, потому что состояние обхода нигде не хранится.
  ///
  /// Идёт по парам «папка облака ↔ путь на телефоне» из базы, поэтому папкам вне зеркала
  /// ничего не грозит. Недоступность сети помечается [fatal] (дальше проход не имеет смысла),
  /// сбой отдельной папки — только [failed]: остальные папки всё равно проверяются.
  Future<void> fullPull({
    bool Function()? isCancelled,
    int? deadlineMs,
  }) async {
    final cancelled = isCancelled ?? () => false;
    for (final root in (await _store.roots()).values) {
      if (fatal != null || stopped) return;
      if (cancelled() || _outOfTime(deadlineMs)) {
        stopped = true;
        return;
      }
      _onProgress('облако: ${root.cloudPath}');
      try {
        await _pullFolder(
          root.cloudId,
          root.localPath,
          0,
          isCancelled: isCancelled,
          deadlineMs: deadlineMs,
        );
      } catch (e) {
        // Сеть отвалилась — дальше нет смысла. Ошибку файловой системы сюда же относить
        // нельзя: имя могло не подойти тому, кончилось место, папка занята — облако при этом
        // в порядке, и останавливать из-за неё весь проход (вместе с выгрузкой) нельзя
        if (_isNetwork(e)) {
          _networkFatal(e);
          return;
        }
        failed += 1;
        _problem('${p.basename(root.localPath)}: $e');
      }
    }
  }

  /// Догнать облако. Первый раз — полный проход и курсор на текущей голове журнала: сначала
  /// голова, потом содержимое. Изменения, случившиеся во время полного прохода, приедут
  /// журналом и применятся повторно — применение идемпотентно, а потеряться ничего не может.
  ///
  /// @param isCancelled опрос отмены и @param deadlineMs метка конца бюджета прохода — те же,
  ///        что у [fullPull] и по той же причине.
  ///
  /// Побочные эффекты: сеть (журнал, папки, скачивание), файловая система телефона и запись
  /// в базу зеркала (курсор, строки файлов и папок). Ошибки наружу не выбрасываются: сбой
  /// страницы журнала оставляет [failed], отказ авторизации и недоступность журнала —
  /// [fatal], а 429 и 5xx просто завершают догон, не двигая курсор.
  Future<void> catchUp({bool Function()? isCancelled, int? deadlineMs}) async {
    final cancelled = isCancelled ?? () => false;
    final cursor = await _store.cursor();
    if (cursor == null) {
      // Голову снимаем ДО полного прохода: правки, случившиеся во время прохода, приедут
      // журналом с этой головы. Наоборот нельзя — курсор перепрыгнул бы их.
      // Голову не удалось спросить — курсора не будет, и следующий проход снова пойдёт полным
      int? head;
      try {
        head = await _api.syncHead();
      } catch (_) {}
      await fullPull(isCancelled: isCancelled, deadlineMs: deadlineMs);
      // курсор не пишем, если проход сломался: иначе он перепрыгнул бы неприменённые изменения
      if (fatal == null && head != null) await _store.setCursor(head);
      return;
    }
    var since = cursor;
    for (var guard = 0; guard < _maxPages; guard++) {
      if (fatal != null || stopped) return;
      if (cancelled() || _outOfTime(deadlineMs)) {
        stopped = true;
        return;
      }
      ChangesPage page;
      try {
        page = await _api.changes(since);
      } on SyncApiException catch (e) {
        // Сервер ограничивает частоту: это «повтори позже», а не поломка. Курсор не двигаем —
        // следующий заход продолжит с того же места.
        if (e.status == 429 || e.status >= 500) return;
        _networkFatal(e, what: 'журнал изменений');
        return;
      } catch (e) {
        _networkFatal(e, what: 'журнал изменений');
        return;
      }
      if (page.resetRequired) {
        // по этому курсору часть изменений уже не восстановить: только полный проход.
        // Курсор ставим ровно в голову, снятую до прохода: иначе признак «нужен рескан» не гас бы
        // никогда, и полный проход шёл бы на каждом событии.
        int? head;
        try {
          head = await _api.syncHead();
        } catch (_) {}
        await fullPull(isCancelled: isCancelled, deadlineMs: deadlineMs);
        if (fatal == null && head != null) await _store.setCursor(head);
        return;
      }
      // Курсор двигается только за применённые строки. Строка, на которой проход сломался,
      // остаётся позади курсора: у журнала нет повторных попыток, и «проехать» её значило бы
      // потерять изменение навсегда.
      var applied = since;
      int? failedSeq;
      var failedName = '';
      for (final change in page.changes) {
        // смертельная ошибка обрывает применение: продолжать по строкам незачем
        if (fatal != null) return;
        if (cancelled() || _outOfTime(deadlineMs)) {
          stopped = true;
          await _store.setCursor(applied);
          return;
        }
        try {
          await _apply(change);
          applied = change.seq;
        } catch (e) {
          // одна негодная строка не должна останавливать догон: считаем её сбоем и идём дальше
          failed += 1;
          failedSeq = change.seq;
          failedName = change.name;
          _problem('$failedName: $e');
          break;
        }
      }
      if (failedSeq != null) {
        await _store.setCursor(applied);
        if (!await _stuck(failedSeq)) return;
        // Строка не поддаётся третий проход подряд (например, имя недопустимо для файловой
        // системы): пропускаем её, иначе она навсегда закрыла бы собой весь журнал.
        // Имя остаётся в отчёте — человеку видно, что именно не доехало.
        _problem('пропущено после $_stuckLimit попыток: $failedName');
        applied = failedSeq;
        await _store.setCursor(applied);
        if (!page.hasMore) return;
        since = applied;
        continue;
      }
      since = page.nextSeq;
      await _store.setCursor(since);
      if (!page.hasMore) return;
    }
  }

  /// Папка облака целиком: подпапки, затем записи.
  ///
  /// @param depth глубина от корня: за [._maxDepth] не идём, чтобы петля в дереве не съела
  ///        проход. Побочные эффекты: создаёт папки на телефоне, пишет пары в базу, скачивает
  ///        файлы. Ошибки дочерних записей считаются сбоями и не мешают остальным.
  Future<void> _pullFolder(
    String folderId,
    String localPath,
    int depth, {
    bool Function()? isCancelled,
    int? deadlineMs,
  }) async {
    final cancelled = isCancelled ?? () => false;
    if (depth > _maxDepth || fatal != null || stopped) return;
    if (cancelled() || _outOfTime(deadlineMs)) {
      stopped = true;
      return;
    }
    await ensureLocalDir(localPath);
    await _store.registerDir(folderId, localPath);
    final FolderChildren children;
    try {
      children = await _api.children(folderId);
    } catch (e) {
      // Один недоступный каталог не обрывает проход, но серия подряд — признак отвалившейся
      // сети: счётчик тот же, что у скачивания (см. FailureStreak)
      failed += 1;
      _problem('${p.basename(localPath)}: $e');
      if (_cloud.failure(e)) {
        fatal = _cloud.reason;
        authFailed = _cloud.authFailed;
      }
      return;
    }
    final parentName = p.basename(localPath);
    for (final entry in children.folderIds.entries) {
      if (fatal != null || stopped) return;
      if (cancelled() || _outOfTime(deadlineMs)) {
        stopped = true;
        return;
      }
      // То же правило имён, что у обхода телефона: папку, которую сканер не показывает,
      // не заводим и здесь — иначе она появлялась бы на телефоне, не попадала в снимок
      // и удалялась в облаке на том же проходе («появилась — исчезла»), а её содержимое
      // не выгружалось бы вовсе
      if (MirrorRules.ignored(entry.key) ||
          MediaRules.skipDir(entry.key, parentName)) {
        continue;
      }
      final childPath = p.join(localPath, entry.key);
      final known = await _store.dirPath(entry.value);
      var actual = childPath;
      if (known == null) {
        // папку завели не мы (в вебе или на другом устройстве): заводим её и здесь
        await ensureLocalDir(childPath);
        await _store.registerDir(entry.value, childPath);
      } else if (known != childPath) {
        // папку переименовали или перенесли в облаке: повторяем на телефоне.
        // Переставить не удалось (занято, нет прав, источник пропал) — пару не трогаем
        // и идём по прежнему пути: завести каталог заново по новому имени значило бы
        // наплодить на телефоне дубли структуры, а строки перевести на несуществующие пути
        if (await _moveLocalDir(known, childPath)) {
          await _store.moveDir(entry.value, childPath);
        } else {
          actual = known;
        }
      }
      await _pullFolder(
        entry.value,
        actual,
        depth + 1,
        isCancelled: isCancelled,
        deadlineMs: deadlineMs,
      );
    }
    for (final entry in children.entries) {
      if (fatal != null || stopped) return;
      if (cancelled() || _outOfTime(deadlineMs)) {
        stopped = true;
        return;
      }
      try {
        await _reconcile(
          folderId: folderId,
          name: entry.name,
          entryId: entry.id,
          sha256: entry.sha256,
          size: entry.size,
          clientMtime: entry.clientMtime,
          localDir: localPath,
        );
      } catch (e) {
        // одна запись не должна ронять папку: имя могло не подойти файловой системе,
        // файл мог быть занят — следующий проход попробует снова
        failed += 1;
        _problem('${entry.name}: $e');
      }
    }
  }

  /// Одно изменение журнала.
  ///
  /// Папка и запись разбираются по-разному: у папки в журнале одно событие на всё поддерево,
  /// у записи — своё. Побочные эффекты наследуются от обработчиков.
  Future<void> _apply(CloudChange change) async {
    // своя же правка: локально она уже сделана тем проходом, который её отправил
    if (_deviceId != null &&
        change.deviceId != null &&
        change.deviceId == _deviceId) {
      return;
    }
    if (change.target == 'folder') {
      await _applyFolder(change);
    } else {
      await _applyEntry(change);
    }
  }

  /// Папка: создание, переименование, перенос или удаление.
  ///
  /// Пары «папка облака ↔ путь на телефоне» незнакомой папке нет — тогда событие молча
  /// пропускается: путь в файловой системе из одного имени не собрать, а угадывать нельзя.
  Future<void> _applyFolder(CloudChange change) async {
    final known = await _store.dirPath(change.targetId);
    if (change.op == 'delete') {
      if (known == null) return;
      final roots = (await _store.roots()).keys;
      // Папку сняли с выбора — её файлы трогать нельзя: удаление в облаке относится
      // к облачной копии, а не к тому, что лежит на телефоне вне зеркала
      if (!MirrorRules.underRoots(known, roots)) return;
      // Корень зеркала — это выбранная человеком папка, и снести её целиком нельзя ни при
      // каком событии журнала. Раньше это держалось только защитой на сервере; проверка
      // обязана быть и здесь, потому что журнал — источник истины для удалений
      if (!MirrorRules.insideRoots(known, roots)) {
        _problem('корень зеркала не удаляю: $known');
        return;
      }
      // в журнале на папку одно событие: поддерево удалено целиком
      await _deleteKnownSubtree(known);
      return;
    }
    // create | update | move | restore: папка должна существовать на телефоне
    // имя, которое обход не показывает, не заводим и здесь: см. _pullFolder
    if (MirrorRules.ignored(change.name)) return;
    final parentId = change.folderId;
    if (parentId == null) return;
    final parent = await _store.dirPath(parentId);
    if (parent == null) return;
    // Пара могла устареть: папку переименовали или унесли в файловом менеджере. Заводить её
    // заново по старому имени нельзя — на телефоне получился бы дубль структуры (старое
    // и новое имя), и следующий проход считал бы восстановленную папку живой. Пары приведёт
    // в порядок ближайший проход: обход заводит их по текущему снимку (`relDir`)
    if (!await Directory(parent).exists()) {
      failed += 1;
      _problem('папка на телефоне переехала: $parent');
      return;
    }
    final path = p.join(parent, change.name);
    if (known != null && known != path) {
      if (await _moveLocalDir(known, path)) {
        await _store.moveDir(change.targetId, path);
        renamedLocal += 1;
      }
      return;
    }
    if (known == null) {
      await ensureLocalDir(path);
      await _store.registerDir(change.targetId, path);
    }
  }

  /// Запись: удаление или приведение к состоянию облака.
  ///
  /// Путь собирается из пары родительской папки и имени: если родителя в парах нет, событие
  /// пропускается — так отсекаются правки в папках вне зеркала.
  Future<void> _applyEntry(CloudChange change) async {
    final parentId = change.folderId;
    if (parentId == null) return;
    final parent = await _store.dirPath(parentId);
    if (parent == null) return;
    if (change.op == 'delete') {
      final row = await _store.fileByEntry(change.targetId);
      if (row == null) return;
      // путь мог остаться от снятой с выбора папки: такие файлы наше зеркало не ведёт
      if (!await _underRoots(row.path)) return;
      await _deleteLocalFile(row);
      return;
    }
    // устаревшая пара: папки по этому пути на телефоне нет. Скачивание создало бы её заново
    // по старому имени (см. _applyFolder) — вместо этого событие пропускаем: ближайший проход
    // заведёт пару по текущему снимку, а файл приедет следующим догоном
    if (!await Directory(parent).exists()) {
      failed += 1;
      _problem('папка на телефоне переехала: $parent');
      return;
    }
    await _reconcile(
      folderId: change.folderId,
      name: change.name,
      entryId: change.targetId,
      sha256: change.sha256,
      size: change.size,
      clientMtime: change.clientMtime,
      localDir: parent,
    );
  }

  /// Решение по одной записи облака: скачать, перенести или не трогать.
  ///
  /// Запись, содержимое которой совпадает с уже выгруженным (по хэшу), не скачивается: это
  /// либо наша собственная выгрузка, либо файл, который уже лежит на телефоне. Если же
  /// на телефоне содержимое своё и отличается — оно не затирается: локальная версия уходит
  /// в конфликтную копию, каноническое имя занимает версия облака (так же поступает Drive).
  ///
  /// Само решение принимает [MirrorRules.decideMove] и [MirrorRules.decideRecord] — чистые
  /// функции, покрытые тестами: здесь остаётся файловая система, сеть и база.
  ///
  /// Порядок решений (он же порядок приоритетов):
  ///   1. переезд записи в облаке — файл переносится (или строка забывается, если файла
  ///      по старому пути нет) до всякого сравнения содержимого;
  ///   2. «содержимое облака уже наше» — по хэшу строки: скачивать нечего;
  ///   3. «файла нет» — скачиваем, кроме служебных и скрытых имён;
  ///   4. «это тот же файл» — заводим строку без скачивания (бывает только после падения
  ///      между скачиванием и записью строки: размер и дата совпали с датой источника,
  ///      поэтому хэш всё равно считается по файлу);
  ///   5. иначе — конфликт: локальная версия уходит копией, по основному имени скачивается
  ///      версия облака. Этот последний случай — единственный, где локальный файл вообще
  ///      может быть заменён.
  ///
  /// @param sha256/size/clientMtime — снимок содержимого из журнала или листинга: размер и дата
  ///        берутся от устройства-источника; @param localDir папка на телефоне, в которой
  ///        запись должна лежать.
  /// Побочные эффекты: переименование файла на телефоне, скачивание, запись строк в базу.
  /// Ошибки наружу не выбрасываются — [failed] и [conflicts] копятся здесь же.
  ///
  /// «Файл уже у нас» проверяется по размеру, дате и номеру файла, без чтения содержимого:
  /// совпали все три — считаем, что это тот же файл. Номер файла ловит подмену содержимого
  /// с сохранением размера и даты (`cp -p`, распаковка архива с датами); его отсутствие
  /// (мост не ответил) оставляет ту же слепую зону, что была у пары «размер + дата».
  Future<void> _reconcile({
    required String? folderId,
    required String name,
    required String entryId,
    required String? sha256,
    required int size,
    required int? clientMtime,
    required String localDir,
  }) async {
    final path = p.join(localDir, name);
    final caseInsensitive = MirrorRules.caseInsensitive(localDir);
    var row = await _store.fileByEntry(entryId);
    final file = File(path);

    // запись переименована или перенесена в облаке: повторяем это на телефоне
    if (row != null && row.path != path) {
      final from = File(row.path);
      final samePathOnVolume = MirrorRules.samePath(
        row.path,
        path,
        caseInsensitive: caseInsensitive,
      );
      final action = MirrorRules.decideMove(
        pathDiffers: true,
        samePathOnVolume: samePathOnVolume,
        fileAtOldPath: await from.exists(),
        fileAtNewPath: await file.exists(),
      );
      switch (action) {
        case MirrorMoveAction.rename:
          // на карте памяти `A.txt` и `a.txt` — один файл: переставлять нечего, но строку
          // надо привести к написанию облака, иначе расхождение повторится в каждом проходе
          if (!samePathOnVolume) {
            if (!await _renameLocal(from, path)) {
              // файл занят или его унесли: строку не трогаем, следующий проход разберётся
              failed += 1;
              _problem('не удалось переименовать ${p.basename(row.path)}');
              return;
            }
          }
          final moved = row.copyWith(
            path: path,
            cloudFolderId: folderId ?? row.cloudFolderId,
          );
          await _store.moveFile(row.path, moved);
          row = moved;
          renamedLocal += 1;
          break;
        case MirrorMoveAction.forget:
          // Файла по старому пути нет — строку снимаем до скачивания. Иначе в таблице
          // остались бы две строки с одной записью облака (у `files` ключ — путь), а фаза
          // «телефон → облако» в этом же проходе увидела бы старый путь как «файла нет»
          // и унесла бы только что скачанную запись в корзину
          await _store.dropFile(row.path);
          row = null;
          break;
        case MirrorMoveAction.none:
          break;
      }
    }

    final exists = await file.exists();
    final stat = exists ? await file.stat() : null;
    final localSize = stat?.size ?? 0;
    final localMtime = stat?.modified.millisecondsSinceEpoch ?? 0;
    final localInode = exists ? _native.inode(path) : 0;
    final cloudSha = sha256?.toLowerCase();
    final rowSha = row?.sha256?.toLowerCase();

    final contentMatches = cloudSha != null && rowSha == cloudSha;
    // строка описывает ровно этот файл: размер, дата и номер совпали (номер — когда известен)
    final rowMatchesLocal =
        row != null &&
        exists &&
        row.size == localSize &&
        row.mtime == localMtime &&
        (row.inode <= 0 || localInode <= 0 || row.inode == localInode);
    // строки нет, но файл — тот самый, что в облаке: совпали размер и дата источника
    final looksLikeSource =
        row == null &&
        exists &&
        clientMtime != null &&
        clientMtime > 0 &&
        localSize == size &&
        localMtime == clientMtime;

    final action = MirrorRules.decideRecord(
      known: row != null,
      contentMatches: contentMatches,
      localExists: exists,
      excludedName: MirrorRules.ignored(name),
      rowMatchesLocal: rowMatchesLocal,
      looksLikeSource: looksLikeSource,
    );
    switch (action) {
      case MirrorRecordAction.keep:
        return;
      case MirrorRecordAction.download:
        await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
        return;
      case MirrorRecordAction.adopt:
        // Файл уже тот самый: вместо скачивания заводим строку, чтобы следующий проход
        // не счёл его новым и не выгрузил обратно. Совпали только размер и дата, поэтому
        // хэш считается по файлу: облачный слепок в строку писать нельзя — он бы навсегда
        // закрепил ложное «содержимое совпадает»
        final localSha = await Hasher.sha256(file);
        if (cloudSha != null && localSha.toLowerCase() != cloudSha) {
          // размер и дата совпали, а содержимое — нет: это разные файлы. Локальную версию
          // не выбрасываем: она уходит конфликтной копией, по основному имени — версия облака
          if (!await _saveConflictCopy(file)) {
            failed += 1;
            _problem('не удалось отодвинуть $name — конфликт не разрешён');
            return;
          }
          conflicts += 1;
          await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
          return;
        }
        await _store.putFile(
          MirrorRow(
            path: path,
            cloudFolderId: folderId ?? '',
            entryId: entryId,
            inode: localInode,
            size: localSize,
            mtime: localMtime,
            sha256: localSha,
          ),
        );
        return;
      case MirrorRecordAction.conflict:
        // менялось и там, и тут: никто не затирается молча
        if (!await _saveConflictCopy(file)) {
          // отодвинуть не удалось (папка не читается, файл занят): облачную версию поверх
          // локальной правки не кладём — пусть разберётся следующий проход
          failed += 1;
          _problem('не удалось отодвинуть $name — конфликт не разрешён');
          return;
        }
        conflicts += 1;
        // строку снимаем: конфликтную копию выгрузит следующий проход как новый файл
        if (row != null) await _store.dropFile(row.path);
        await downloadInto(entryId, folderId, path, sha256, size, clientMtime);
        return;
    }
  }

  /// Путь лежит внутри папки, которая выбрана сейчас: только такие удаления применяем.
  ///
  /// Список корней читается из базы на каждый вызов: пары могли измениться, пока проход
  /// разбирал журнал.
  Future<bool> _underRoots(String path) async =>
      MirrorRules.underRoots(path, (await _store.roots()).keys);

  /// Удаление папки, пришедшее из облака. Убираем ровно то, что знает зеркало: файлы — по
  /// своим строкам, папки — только пустые. Сносить каталог целиком нельзя: там могут лежать
  /// только что скопированные файлы, служебные имена и то, что не смогло уехать, —
  /// восстанавливать их было бы нечем.
  ///
  /// Пары из базы снимаются в любом случае, даже если каталог остался: обход перечисляет все
  /// папки выбранного дерева, поэтому следующий проход заведёт пару заново — а файлы, которых
  /// сверка не знает, останутся на месте и уедут в облако как новые.
  Future<void> _deleteKnownSubtree(String localPath) async {
    // Строки берутся из базы по префиксу пути, а поддерево там ищется через `LIKE`, где `_`
    // и `%` — метасимволы: у папки `my_photos` в выборку попадает и `myXphotos`. Поэтому
    // каждый путь перепроверяется здесь: под удаление не должно попасть ничего из соседней
    // папки, отличающейся одной буквой.
    for (final row in await _store.filesUnder(localPath)) {
      if (!MirrorRules.inside(row.path, localPath)) continue;
      await _deleteLocalFile(row);
    }
    // от длинных путей к коротким: дети уходят раньше родителей
    final dirs = await _store.dirsUnder(localPath);
    dirs.sort((a, b) => b.$2.length.compareTo(a.$2.length));
    for (final (id, path) in dirs) {
      if (path != localPath && !MirrorRules.inside(path, localPath)) continue;
      final dir = Directory(path);
      // непустой каталог не трогаем: в нём что-то есть, и это «что-то» сверка не ведёт
      if (await dir.exists() && await _isEmpty(dir)) {
        try {
          await dir.delete();
        } catch (_) {}
      }
      // пару снимаем в любом случае: строка без каталога безопаснее, чем каталог без строки
      await _store.dropDir(id);
    }
    final dir = Directory(localPath);
    // папка уходит только если действительно опустела: незнакомые файлы остаются,
    // и тогда она вернётся в облако следующим проходом
    if (await dir.exists() && await _isEmpty(dir)) {
      try {
        await dir.delete();
      } catch (_) {}
    }
  }

  /// Файл из облака удаляют: локальную правку, которая ещё не уехала, сохраняем копией.
  ///
  /// Дата и размер сравниваются со строкой зеркала — по этой паре и видно, что файл меняли
  /// после выгрузки; содержимое не читается. Строка снимается в любом случае, даже если файл
  /// удалить не удалось: иначе он навсегда останется «известным» без записи в облаке.
  Future<void> _deleteLocalFile(MirrorRow row) async {
    final file = File(row.path);
    if (await file.exists()) {
      final stat = await file.stat();
      final edited =
          stat.size != row.size ||
          stat.modified.millisecondsSinceEpoch != row.mtime;
      if (edited) {
        // на телефоне правка, которой в облаке уже нет: отодвигаем её копией,
        // а не удаляем вместе с облачной записью
        if (await _saveConflictCopy(file)) conflicts += 1;
      } else {
        try {
          await file.delete();
          deletedLocal += 1;
        } catch (_) {}
      }
    }
    await _store.dropFile(row.path);
  }

  /// Отодвинуть файл под свободным именем с пометкой конфликта: ничего не теряем.
  ///
  /// Имя выбирается по занятым именам папки и с учётом регистра тома: на карте памяти
  /// `Фото.JPG` и `фото.jpg` — один и тот же файл, и «свободное» имя по сравнению с учётом
  /// регистра затёрло бы его. Пометка дописывается к базовому имени, которое при
  /// необходимости обрезается по байтам (см. [MirrorRules.conflictName]).
  ///
  /// @return `false`, если папку не удалось прочитать или файл не переименовался, —
  ///         вызывающий в этом случае ничего не удаляет. Побочный эффект — переименование
  ///         в файловой системе; содержимое файла не читается и не меняется.
  Future<bool> _saveConflictCopy(File file) async {
    final dir = file.parent;
    Set<String> taken;
    try {
      taken = (await dir.list().toList())
          .map((e) => p.basename(e.path))
          .toSet();
    } catch (_) {
      return false;
    }
    final name = MirrorRules.uniqueName(
      MirrorRules.conflictName(
        p.basename(file.path),
        DateTime.now().millisecondsSinceEpoch,
      ),
      taken,
      caseInsensitive: MirrorRules.caseInsensitive(file.path),
    );
    try {
      await file.rename(p.join(dir.path, name));
      return true;
    } catch (_) {
      // Первая причина отказа — имя (предел длины, символы тома). Вторая попытка с коротким
      // именем: содержимое важнее красивого названия, а без копии запись осталась бы
      // несогласованной до изменения файла — облачная версия не скачивалась бы вовсе
      final ext = _extensionOf(p.basename(file.path));
      final fallback = MirrorRules.fitBytes(
        'конфликт-${DateTime.now().millisecondsSinceEpoch}$ext',
        MirrorRules.maxNameBytes,
      );
      try {
        await file.rename(p.join(dir.path, fallback));
        _onProgress('конфликтная копия сохранена как «$fallback»');
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Расширение имени вместе с точкой: у имени без расширения (или начинающегося с точки) —
  /// пустая строка.
  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot) : '';
  }

  /// Переставить файл на телефоне, создав при необходимости родительские папки.
  /// @return `false`, если файловая система отказала: строку в этом случае трогать нельзя.
  Future<bool> _renameLocal(File from, String toPath) async {
    try {
      await File(toPath).parent.create(recursive: true);
      await from.rename(toPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Скачать запись в путь на телефоне и запомнить её как выгруженную.
  ///
  /// Зовётся и при разборе журнала, и движком при разрешении конфликта.
  ///
  /// @param sha256 ожидаемый слепок содержимого: скачивание сверяет с ним файл и не оставляет
  ///        огрызок, если содержимое не сошлось; @param clientMtime дата с устройства-источника,
  ///        @param size размер записи в облаке.
  /// Побочные эффекты: файл на телефоне (временный файл и бэкап прежней версии внутри
  /// `SyncApi.downloadToFile`, затем строка в базе), счётчики и [fatal] при сбое сети или
  /// отозванном токене. Возвращает `false`, если файл не скачался: вызывающий считает это
  /// сбоем, но проход из-за одного файла не прекращается.
  Future<bool> downloadInto(
    String entryId,
    String? folderId,
    String path,
    String? sha256,
    int size,
    int? clientMtime,
  ) async {
    final dest = File(path);
    await dest.parent.create(recursive: true);
    try {
      await _api.downloadToFile(entryId, dest, expectedSha256: sha256);
      // дата файла берётся с устройства-источника: иначе следующий проход счёл бы только что
      // скачанный файл изменённым на телефоне и выгрузил бы его назад
      if (clientMtime != null && clientMtime > 0) {
        try {
          await dest.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(clientMtime),
          );
        } catch (_) {}
      }
      // в строку пишем то, что реально лежит на диске: размер и дата уже после скачивания,
      // поэтому следующий проход не увидит расхождения
      final stat = await dest.stat();
      await _store.putFile(
        MirrorRow(
          path: dest.path,
          cloudFolderId: folderId ?? '',
          entryId: entryId,
          inode: _native.inode(dest.path),
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          // хэш — из журнала: содержимое скачанного файла повторно не хэшируется
          sha256: sha256,
        ),
      );
      downloaded += 1;
      _downloads.success();
      _onProgress('скачано: ${p.basename(dest.path)}');
      return true;
    } catch (e) {
      failed += 1;
      // Ошибка файловой системы — это про конкретный файл (имя не подошло тому, кончилось
      // место, папка занята), а не про связь: в счётчик «сеть легла» она не идёт, иначе
      // пять таких подряд останавливали бы весь проход с диагнозом «облако недоступно»
      if (!_isLocalFs(e) && _downloads.failure(e)) {
        fatal = _downloads.reason;
        authFailed = _downloads.authFailed;
        return false;
      }
      // Самая частая причина отказа файловой системы — имя: сервер разрешает символы и длину,
      // которых на телефоне не бывает. Про карту памяти говорим только тогда, когда том
      // и правда съёмный, — иначе человек получил бы неверный диагноз и пошёл переименовывать
      // файл в облаке
      final name = p.basename(dest.path);
      final removable = MirrorRules.removableVolume(path);
      final problem = MirrorRules.nameProblem(name, removable: removable);
      _onProgress(
        problem != null
            ? 'не скачалось «$name»: $problem — переименуйте в облаке'
            : 'не скачалось $name: $e',
      );
      return false;
    }
  }

  /// Переименование или перенос папки на телефоне вместе со всем, что под ней.
  ///
  /// Каталог переносится, только если он есть и целевого пути ещё нет. Строки в базе
  /// переводятся на новый путь **только вслед за подтверждённым переносом**: если файловая
  /// система отказала (имя занято, файл открыт, каталог недоступен), строки описывали бы
  /// несуществующие пути, а файлы остались бы по старым — и выгрузка пошла бы кругами.
  ///
  /// @return `true`, если содержимое оказалось по новому пути (перенос сделан или оно там уже),
  ///         `false` — если ни источника, ни цели нет и трогать пары нельзя.
  Future<bool> _moveLocalDir(String fromPath, String toPath) async {
    final from = Directory(fromPath);
    final to = Directory(toPath);
    await to.parent.create(recursive: true);
    final fromExists = await from.exists();
    final toExists = await to.exists();
    if (fromExists && !toExists) {
      try {
        await from.rename(toPath);
      } catch (e) {
        _onProgress('не удалось переименовать ${p.basename(fromPath)}: $e');
        return false;
      }
    } else if (!toExists) {
      // ни старого каталога, ни нового: папку унесли или она на другом томе.
      // Строки не переводим — они описывали бы пути, которых нет
      return false;
    }
    // Строки поддерева берутся по префиксу, а `LIKE` в хранилище не экранирует `_` и `%`:
    // у папки `my_photos` в выборку попадает и `myXphotos`. Путь перепроверяется здесь,
    // иначе чужие строки переехали бы вместе с ней
    for (final row in await _store.filesUnder(fromPath)) {
      if (!MirrorRules.inside(row.path, fromPath)) continue;
      final path = toPath + row.path.substring(fromPath.length);
      await _store.moveFile(row.path, row.copyWith(path: path));
      // Незавершённая выгрузка привязана к прежнему пути: по нему файла уже нет, и сессия
      // осталась бы в таблице навсегда (следующий проход ищет её по новому пути). Пустая
      // строка — обычное дело: удаление без совпадения ничего не стоит
      await _store.dropUploadSession(row.path);
    }
    for (final (id, path) in await _store.dirsUnder(fromPath)) {
      // сам переносимый каталог уже переписан выше, в цикле он тоже есть
      if (path == fromPath) continue;
      if (!MirrorRules.inside(path, fromPath)) continue;
      await _store.moveDir(id, toPath + path.substring(fromPath.length));
    }
    return true;
  }

  /// Папка пуста? Отказ чтения — это «не знаю», поэтому отвечаем `false`: на таком ответе
  /// папка остаётся на месте, а удалить её успеется в следующий раз.
  Future<bool> _isEmpty(Directory dir) async {
    try {
      return await dir.list().isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Ошибка файловой системы телефона: к связи отношения не имеет.
  static bool _isLocalFs(Object e) => e is FileSystemException;

  /// Сбой связи или отказ сервера: продолжать проход бессмысленно.
  static bool _isNetwork(Object e) {
    if (_isLocalFs(e)) return false;
    if (e is SyncApiException) {
      return e.status == 0 ||
          e.status == 401 ||
          e.status == 403 ||
          e.status == 429 ||
          e.status >= 500;
    }
    // IOException в dart:io — это SocketException, HttpException и прочий обрыв связи
    return e is IOException;
  }

  /// Записать смертельную ошибку связи: отказ авторизации отмечается отдельно, чтобы
  /// вызывающий перевыпустил токен, а не читал русский текст ошибки.
  ///
  /// [what] — что именно было недоступно: подпись попадает в отчёт, и «журнал изменений
  /// недоступен» полезнее, чем «облако недоступно», когда в облаке всё в порядке.
  void _networkFatal(Object e, {String what = 'облако'}) {
    if (e is SyncApiException && (e.status == 401 || e.status == 403)) {
      fatal = 'токен отозван — войдите заново';
      authFailed = true;
      return;
    }
    fatal = '$what недоступно: $e';
  }

  /// Запомнить имя того, что не доехало: в отчёте нужны имена, а не только счётчик.
  void _problem(String text) {
    if (problems.length < _maxProblems) problems.add(text);
  }

  /// Строка журнала не применяется который проход подряд?
  ///
  /// Счётчик живёт в базе (см. [_stuckKey]): [MirrorPull] заводится на каждый проход, а решение
  /// «пропустить» принимается по нескольким. Возвращает `true`, когда попыток стало слишком
  /// много — тогда строку пропускаем, а счётчик обнуляем.
  Future<bool> _stuck(int seq) async {
    final raw = await _store.meta(_stuckKey) ?? '';
    final parts = raw.split('|');
    final was = int.tryParse(parts.first) ?? 0;
    final count = was == seq
        ? (int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0) + 1
        : 1;
    await _store.setMeta(_stuckKey, '$seq|$count');
    if (count < _stuckLimit) return false;
    await _store.clearMeta(_stuckKey);
    return true;
  }

  /// Время облачной части вышло? [deadlineMs] — метка конца бюджета прохода; `null` — без
  /// предела (мгновенный догон журнала бюджетом не ограничен).
  bool _outOfTime(int? deadlineMs) =>
      deadlineMs != null && DateTime.now().millisecondsSinceEpoch > deadlineMs;
}
