import 'dart:async';
import 'dart:io';

import '../data/queue_store.dart';
import '../device/hasher.dart';
import '../device/media_rules.dart';
import '../net/sync_api.dart';
import 'queue_planner.dart';
import 'upload_plan.dart';
import 'uploader.dart';

/// Что происходит прямо сейчас: имя файла и сколько байт ушло.
class UploadProgress {
  const UploadProgress({
    required this.id,
    required this.name,
    required this.sent,
    required this.total,
  });

  /// `queue.id` выгружаемой строки: по нему экран находит строку в списке и показывает
  /// прогресс именно у неё.
  final int id;

  /// Имя файла из строки очереди: под ним он ляжет в облако (если имя не займут — тогда
  /// запись получит другое имя, а строка это не покажет).
  final String name;

  /// Сколько байт уже принято и сколько их всего. У «уже в облаке» байтов не бывает:
  /// в этом случае прогресс не приходит вовсе.
  final int sent;
  final int total;

  /// Процент для подписи в строке. Пока размер неизвестен (файл только начинают читать),
  /// показывает 0 — интерфейс такой случай подписывает «выгрузка…».
  int get percent => total > 0 ? (sent * 100) ~/ total : 0;
}

/// Выгрузка одного файла из очереди.
///
/// Запускается из ядра синхронизации (`SyncController`): кнопкой «поторопить» на строке и
/// автоматическим сливом ждущих — сторож раз в минуту забирает первое PENDING/FAILED.
/// Файлы идут строго по одному: [run] выстраивает вызовы в очередь (см. [_chain]), поэтому
/// ни сторож, ни кнопка на строке, ни проверка при входе в раздел не могут начать вторую
/// выгрузку параллельно — иначе канал и батарея делились бы на потоки, а раздел показывал бы
/// прогресс только одного файла.
///
/// Порядок работы:
///   1. не пора ли вообще пробовать (упавшая строка ждёт паузы, см. [QueuePlanner.retryReady]);
///   2. файл на месте? если исчез — строка помечается ошибкой и ждёт следующего прохода;
///   3. SHA-256 содержимого (из кэша, если файл не менялся) — им сервер отличает дубли;
///   4. что уже лежит в облаке по этому имени: тот же хэш → выгрузка не нужна вовсе,
///      другой → перезапись с проверкой версии (сервер откажет, если там уже чужое);
///   5. папка получателя — цель строки;
///   6. заливка частями прямо в хранилище, при его недоступности — через сервер;
///      прерванная выгрузка продолжается с принятой части (см. [QueueStore.uploadSession]).
///
/// Состояния между выгрузками нет: всё, что нужно помнить (что выгружено, состояние строки,
/// кэш хэша, незавершённая сессия), лежит в [QueueStore], поэтому незавершённая выгрузка
/// не теряет ничего, кроме ещё не переданных байтов.
class UploadRunner {
  /// [_api] — клиент синхронизации под device-токеном, [_store] — база очереди. Оба приходят
  /// снаружи и живут дольше выгрузки: своих соединений runner не заводит.
  UploadRunner(this._api, this._store);

  final SyncApi _api;
  final QueueStore _store;

  /// Хвост цепочки выгрузок: следующая начинается только после предыдущей.
  ///
  /// «Одна выгрузка за раз» нужна не только экрану: сторож, `checkAndResume` и кнопка на
  /// строке запускают проходы независимо друг от друга, и без цепочки два файла лились бы
  /// одновременно (а одну и ту же строку два прохода могли взять вдвоём).
  Future<void> _chain = Future<void>.value();

  /// Выгрузить одну строку очереди.
  ///
  /// [itemId] — `queue.id`; [onProgress] вызывается по байтам и может не вызваться ни разу
  /// (например, содержимое уже лежит в облаке). Его отсутствие означает автоматический запуск
  /// (слив ждущих): такие проходы пауза после ошибки придерживает, а запуск с прогрессом —
  /// это просьба человека, и она выполняется сразу (см. [_run]).
  ///
  /// Если выгрузка уже идёт, вызов встаёт в очередь за ней и начнётся после её конца: так
  /// «одна выгрузка за раз» держится в самом раннере, а не в согласии вызывающих.
  ///
  /// Пишет в SQLite: `RUNNING` перед сетью, дальше `DONE`/`SKIPPED`/`FAILED`, кэш хэша
  /// (`queue.sha256`), сессию незавершённой выгрузки (`queue_uploads`) и слепок выгруженного
  /// (`uploaded`). Читает файл с диска. Ходит в сеть: метаданные записи, заливка.
  ///
  /// Ошибку заливки не глотает: строка получает `FAILED` с текстом и увеличенным числом
  /// попыток, а исключение уходит вызывающему — он показывает его в заметке раздела.
  Future<void> run(int itemId, {void Function(UploadProgress)? onProgress}) {
    final next = _chain.then((_) => _run(itemId, onProgress: onProgress));
    // ошибку одной выгрузки цепочка не должна запоминать: иначе следующая упала бы, не начавшись
    _chain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Выгрузка одной строки: тело [run], которое уже никто не запустит параллельно.
  Future<void> _run(int itemId, {void Function(UploadProgress)? onProgress}) async {
    // строку могли снять уборкой или «очистить выполненные»: выгружать уже нечего
    final item = await _store.item(itemId);
    if (item == null) return;
    // Строка с ошибкой ждёт паузы, растущей с числом попыток: сторож сливает очередь раз
    // в минуту, и без паузы файл, который сервер принципиально не принимает, ходил бы в сеть
    // каждую минуту бесконечно.
    //
    // Пауза касается только автоматического слива. Прогресс у строки на экране запрашивает
    // ровно один вызывающий — экран очереди, то есть человек, нажавший «поторопить»,
    // а `SyncController._drainQueue` и `checkAndResume` прогресс не показывают. Явную просьбу
    // человека пауза не отменяет: молча ничего не сделать после нажатия кнопки нельзя.
    final automatic = onProgress == null;
    if (automatic &&
        !QueuePlanner.retryReady(
          state: item.state,
          attempts: item.attempts,
          failedAt: item.finishedAt,
          now: DateTime.now().millisecondsSinceEpoch,
        )) {
      return;
    }
    final file = File(item.path);
    if (!await file.exists()) {
      // пропажа файла — состояние телефона, а не сбой сети: попытку засчитываем, строку
      // оставляем на месте — снимет её следующий проход (см. QueuePlanner.obsolete)
      await _store.markFailed(itemId, 'файла больше нет на телефоне', item.attempts + 1);
      return;
    }

    // слепок снимаем до выгрузки: он же уйдёт в `uploaded`. Если файл допишется во время
    // заливки, размер и дата разойдутся с диском — и следующий проход честно поставит его
    // в очередь снова
    final size = await file.length();
    final mtime = (await file.stat()).modified.millisecondsSinceEpoch;
    // RUNNING ставим до сети: если процесс убьют посреди выгрузки, строку вернёт в ожидание
    // QueueStore.resetRunning при следующем старте
    await _store.markRunning(itemId);
    onProgress?.call(UploadProgress(id: itemId, name: item.name, sent: 0, total: size));

    try {
      final sha = await _shaOf(item, file, size, mtime);
      // Точечный запрос по паре «файл + цель»: полная карта выгруженного нужна наполнению
      // очереди, а здесь из неё берётся одна строка — читать десятки тысяч строк на каждый
      // файл незачем
      final alreadyUploaded = await _store.uploadedOne(item.path, item.target);
      // что лежит на сервере сейчас: этим же отличается «уже там» от «надо перезаписать»
      String? serverSha;
      // спрашиваем только когда запись известна: лишний запрос на каждый файл незачем
      if (alreadyUploaded != null) {
        try {
          serverSha = (await _api.entryMeta(alreadyUploaded.entryId)).sha256;
        } catch (_) {
          // запись могли удалить из веба: тогда файл уедет как новый
          serverSha = null;
        }
      }

      switch (UploadPlan.decide(sha, serverSha)) {
        case UploadAction.skip:
          // Решение «пропустить» приходит, только когда запись о выгрузке известна: без неё
          // хэш на сервере не спросить, и решением было бы create. Пустой id записи —
          // не «уже в облаке», а негодный ответ: записывать по нему нечего, и строка
          // осталась бы закрытой без записи, которую она описывает
          final entryId = alreadyUploaded?.entryId;
          if (entryId == null || entryId.isEmpty) {
            throw StateError('неизвестна запись в облаке для «${item.name}»');
          }
          // строка закрывается как «уже в облаке» (байты не передавались), а слепок обновляем:
          // иначе файл снова попал бы в план следующего прохода. Хэш передаём: содержимое
          // в облаке и на телефоне совпало — этот слепок и есть то, что лежит в облаке
          await _store.markSkipped(itemId, entryId);
          await _store.markUploaded(item.path, item.target, entryId, size, mtime, sha256: sha);
          await _store.dropUploadSession(item.path, item.target);
          return;
        case UploadAction.create:
        case UploadAction.replace:
          // перезаписываем, только если запись в облаке действительно есть: иначе сервер
          // завёл бы вторую запись с тем же именем вместо замены первой
          final replace = serverSha != null;
          final result = await _send(
            item: item,
            folderId: item.target,
            file: file,
            sha: sha,
            size: size,
            mtime: mtime,
            replace: replace,
            expectedSha256: replace ? serverSha : null,
            onProgress: onProgress,
          );
          // пустой id означает, что сервер не назвал запись: закрывать строку «выгружено»
          // по нему нельзя — по id потом ищут запись в облаке (метаданные, правки из веба),
          // а файл считался бы выгруженным навсегда
          if (result.entryId.isEmpty) {
            throw StateError('сервер не назвал запись в облаке для «${item.name}»');
          }
          // сервер мог опознать содержимое по хэшу уже во время заливки: тогда байты не
          // передавались, и состояние строки — «уже в облаке», а не «выгружен»
          if (result.deduped) {
            await _store.markSkipped(itemId, result.entryId);
          } else {
            await _store.markDone(itemId, result.entryId);
          }
          // Слепок берётся ДО выгрузки: в строке записано, что именно лежит в облаке.
          // Если файл дописался во время выгрузки, размер и дата разойдутся — и следующий
          // проход честно поставит его в очередь снова.
          await _store.markUploaded(
            item.path,
            item.target,
            result.entryId,
            size,
            mtime,
            sha256: sha,
          );
          // выгрузка закончена: продолжать больше нечего
          await _store.dropUploadSession(item.path, item.target);
      }
    } catch (e) {
      // Отказ авторизации — не вина строки: токен устройства отозван или истёк, и повторять
      // бессмысленно, пока контроллер не выпустит новый. Поэтому строку возвращаем в ожидание
      // без увеличения попыток и без текста ошибки: иначе весь файл-список ушёл бы в `FAILED`
      // с текстом про 401, а после нового токена ждал бы паузы повтора.
      if (e is SyncApiException && (e.status == 401 || e.status == 403)) {
        await _store.markPending(itemId);
        rethrow;
      }
      // попытку считаем по свежей строке: параллельный проход мог её уже увеличить
      final fresh = await _store.item(itemId);
      await _store.markFailed(itemId, '$e', (fresh?.attempts ?? 0) + 1);
      // не глотаем: вызывающий покажет текст ошибки в заметке раздела
      rethrow;
    }
  }

  /// Хэш содержимого: из кэша строки, если размер и дата не менялись с прошлой попытки.
  ///
  /// [item] — строка очереди, [file] — файл на диске, [size] и [mtime] — снятый до выгрузки
  /// слепок: именно с ним сравнивается слепок, записанный в строке.
  ///
  /// Возвращает хэш. Побочный эффект — запись посчитанного хэша в строку (`queue.sha256`),
  /// чтобы следующая попытка не перечитывала файл целиком. В сеть не ходит. Чтение файла
  /// целиком — самая дорогая часть прохода, и кэш заведён ровно ради неё.
  ///
  /// Пустой хэш — не «содержимое другое», а невозможность его посчитать (см. `Hasher`):
  /// с ним выгрузка сравнивала бы файл с облаком наугад, поэтому такой случай — ошибка.
  ///
  /// Ошибку чтения не глушит: без хэша выгрузка невозможна, исключение уходит в [run].
  Future<String> _shaOf(QueueItem item, File file, int size, int mtime) async {
    final cached = item.sha256;
    // кэш годится, только если совпали оба: по одному размеру или одной дате судить нельзя
    // (см. инвариант у QueueItem.size)
    if (cached != null && cached.isNotEmpty && item.size == size && item.mtime == mtime) {
      return cached;
    }
    final sha = await Hasher.sha256(file);
    if (sha.isEmpty) {
      throw StateError('не удалось посчитать хэш файла «${item.name}»');
    }
    await _store.setSha(item.id, sha);
    return sha;
  }

  /// Заливка с откатом на сервер: прямое подключение к хранилищу может не работать (DNS,
  /// блокировщик, VPN). Внятный ответ сервера (4xx) — не повод менять способ: режим запомнился
  /// бы навсегда и спрятал настоящую причину.
  ///
  /// [item] — строка очереди (из неё имя и цель), [folderId] — папка получателя,
  /// [file] — файл на диске, [sha] — его хэш, [size]/[mtime] — слепок файла на момент
  /// выгрузки (он же уйдёт в сессию), [replace] и [expectedSha256] — перезаписываем ли
  /// запись и какую версию считаем актуальной, [onProgress] — байты.
  ///
  /// Возвращает итог заливки. Возможные исходы ошибок: конфликт имени (сервер считает имя
  /// занятым) — файл уезжает под свободным именем; 4xx — исключение наружу; обрыв сети или
  /// недоступное хранилище — повтор, затем релей через сервер.
  ///
  /// Незавершённую выгрузку продолжает, а не начинает заново: сессию, начатую прошлой
  /// попыткой, хранит [QueueStore] (см. [QueueStore.uploadSession]), и она годится, только
  /// если совпали слепок файла, имя и предусловие попытки. Чужую сессию закрываем
  /// (`SyncApi.abort`), иначе она осталась бы висеть на сервере.
  Future<UploadResult> _send({
    required QueueItem item,
    required String folderId,
    required File file,
    required String sha,
    required int size,
    required int mtime,
    required bool replace,
    required String? expectedSha256,
    void Function(UploadProgress)? onProgress,
  }) async {
    // тип содержимого уходит в метаданные записи: по нему работают превью и выдача.
    // Определяется по расширению имени — читать начало файла ради этого не нужно
    final mime = MediaRules.mimeOf(item.name);
    void progress(int sent, int total) =>
        onProgress?.call(UploadProgress(id: item.id, name: item.name, sent: sent, total: total));

    /// Одна попытка заливки: [cloudName] — имя в облаке, [overwrite]/[expected] — предусловие
    /// попытки (под свободным именем его нет: перезаписывать там нечего), [viaRelay] — лить
    /// через сервер, не пробуя хранилище напрямую.
    ///
    /// Сессию незавершённой выгрузки записывает в базу, и дожидается этой записи: иначе она
    /// могла бы лечь уже после того, как выгрузка закончилась и сессию сняли.
    Future<UploadResult> attempt(
      String cloudName, {
      required bool overwrite,
      required String? expected,
      bool viaRelay = false,
    }) async {
      final writes = <Future<void>>[];
      try {
        return await Uploader(_api).upload(
          folderId: folderId,
          file: file,
          cloudName: cloudName,
          mime: mime,
          sha256: sha,
          replace: overwrite,
          expectedSha256: expected,
          // телефон — источник истины: имя, занятое записью из корзины, занимаем (так же
          // поступает зеркало). Иначе файл не уедет никогда: сервер отвечает 409 `in_trash`,
          // пока корзину не почистят руками, и очередь упиралась бы в него каждый проход
          replaceTrashed: true,
          onSession: (uploadId) => writes.add(
            _store.putUploadSession(
              QueueUploadSession(
                path: item.path,
                target: item.target,
                uploadId: uploadId,
                cloudName: cloudName,
                replace: overwrite,
                expectedSha256: expected,
                size: size,
                mtime: mtime,
                sha256: sha,
              ),
            ),
          ),
          onProgress: progress,
          forceRelay: viaRelay,
        );
      } finally {
        // Ошибку записи не подменяем ошибкой выгрузки — она важнее, а о сбое базы скажет run
        if (writes.isNotEmpty) {
          try {
            await Future.wait(writes);
          } catch (_) {}
        }
      }
    }

    // Продолжение прерванной выгрузки. Сверяется всё, с чем сессия начата: слепок файла,
    // имя и предусловие — иначе принятые сервером части относились бы к другому решению.
    //
    // Возвращает итог, если продолжение удалось; `null` — если сессии нет или она не годится
    // (тогда её закрываем на сервере и выгрузка начнётся с начала).
    Future<UploadResult?> continueSession() async {
      final session = await _store.uploadSession(item.path, item.target);
      if (session == null) return null;
      final fits = session.sha256 == sha &&
          session.size == size &&
          session.mtime == mtime &&
          session.cloudName == item.name &&
          session.replace == replace &&
          session.expectedSha256 == expectedSha256;
      if (fits) {
        try {
          final result = await Uploader(_api).resume(
            uploadId: session.uploadId,
            file: file,
            sha256: sha,
            onProgress: progress,
          );
          await _store.dropUploadSession(item.path, item.target);
          return result;
        } catch (_) {
          // Сессия могла истечь на сервере (в том числе после его перезапуска, см.
          // `upload_session_lost` у релея) или оборваться так, что продолжать нечем:
          // тогда только с начала
        }
      }
      // сессия не подходит или продолжать её не вышло: закрываем, чтобы не оставлять мусор
      await _api.abort(session.uploadId);
      await _store.dropUploadSession(item.path, item.target);
      return null;
    }

    // Сессия, оставшаяся от прошлой попытки или от прошлого запуска приложения: продолжаем
    // её, а не льём файл заново — на гигабайтном видео разница в часах
    final resumed = await continueSession();
    if (resumed != null) return resumed;

    try {
      return await attempt(item.name, overwrite: replace, expected: expectedSha256);
    } catch (first) {
      if (first is SyncApiException &&
          (first.code == 'conflict' || first.code == 'stale_version')) {
        // в облаке чужой файл с таким именем: не затираем, кладём рядом под свободным именем.
        // Список имён — подсказка, а не гарантия: если папку прочитать не удалось, набор пуст
        // и имя останется прежним; тогда решение всё равно за сервером.
        // Под свободным именем записи в облаке нет: перезапись и предусловие по версии
        // относились к прежнему имени, и сервер отверг бы такую попытку гарантированно —
        // `expectedSha256` требует существующей записи с этим именем
        var taken = <String>{};
        try {
          taken = (await _api.children(folderId)).entries.map((e) => e.name).toSet();
        } catch (_) {}
        final free = UploadPlan.freeName(item.name, taken);
        await _closeSession(item);
        return attempt(free, overwrite: false, expected: null);
      }
      // 4xx — это ответ по делу (нет прав, нет места, неверный запрос): повтор и релей его
      // не исправят, а релей ещё и спрячет настоящую причину. Ноль — другое: ответа не было
      // вовсе (нет сети, таймаут, DNS), и такой отказ повторяем
      if (first is SyncApiException && first.status >= 400 && first.status < 500) rethrow;
      // не наша ошибка и не обрыв ввода-вывода — пусть разбирается вызывающий
      if (first is! SyncApiException && first is! IOException) rethrow;

      // Разовый обрыв не повод считать хранилище мёртвым — и не повод лить файл заново:
      // сначала продолжаем прерванную попытку (принятые части уже на сервере)
      final again = await continueSession();
      if (again != null) return again;
      // продолжать не удалось: вторая попытка с начала стоит секунд
      try {
        return await attempt(item.name, overwrite: replace, expected: expectedSha256);
      } catch (_) {
        // и только теперь релей: байты пойдут через сервер — это дороже и для него, и для нас.
        // Сессию прямого пути закрываем: релей открывает свою
        await _closeSession(item);
        return attempt(
          item.name,
          overwrite: replace,
          expected: expectedSha256,
          viaRelay: true,
        );
      }
    }
  }

  /// Закрыть незавершённую сессию этой пары, если она есть: на сервере она больше не нужна,
  /// а в базе строка только путала бы следующую попытку.
  Future<void> _closeSession(QueueItem item) async {
    final session = await _store.uploadSession(item.path, item.target);
    if (session == null) return;
    await _api.abort(session.uploadId);
    await _store.dropUploadSession(item.path, item.target);
  }
}
