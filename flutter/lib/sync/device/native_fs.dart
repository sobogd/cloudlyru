import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'media_rules.dart';
import 'ios_folders.dart';
import 'native_stat.dart';

/// Корень выбора: внутренняя память, домашняя папка или том.
///
/// Приходит из [NativeFs.storageRoots] и попадает в дерево выбора папок
/// (`folder_tree_screen.dart`); [path] — абсолютный путь, с которого начинается обход,
/// [name] — подпись для человека («Внутренняя память» или имя тома).
class RootFolder {
  const RootFolder(this.path, this.name);

  final String path;
  final String name;
}

/// Всё, чего нет в обычном Dart: корни для выбора папок, признак доступа к файлам, номер
/// файла в файловой системе и события файловой системы.
///
/// Всё остальное синхронизатор делает сам, обычными средствами Dart: обход дерева, чтение,
/// запись, хэш, сеть. Сюда вынесено ровно то, для чего нужен системный вызов, — иначе этот
/// слой разросся бы до второго приложения.
///
/// ## Нативного кода проекта здесь больше нет
///
/// Раньше это был мост к Kotlin по `MethodChannel`: `SyncBridge.kt` делал `Os.stat`, обходил
/// тома и ставил `FileObserver`. Теперь тот же системный вызов берётся из Dart — `stat(2)`
/// через FFI ([NativeStat]), тома и корни — обычным обходом каталогов, а наблюдение за
/// папками — средствами Dart. Kotlin в проекте не осталось, и приложение работает на Android
/// и на macOS одним и тем же кодом.
///
/// ## Чем платформа отличается
///
/// | | Android | macOS | iOS |
/// |---|---|---|---|
/// | корни | внутренняя память и съёмные тома из `/storage` | домашняя папка и тома из `/Volumes` | только папки, выбранные человеком в «Файлах» |
/// | доступ | «ко всем файлам» проверяется пробой каталога | такого разрешения нет: доступ решает TCC, а его отсутствие видно как нечитаемые папки | доступ даётся по папке при выборе (security scope), держит его нативная часть |
/// | наблюдение | опрос дат папок раз в [pollMs] | `Directory.watch(recursive: true)` на FSEvents: одно наблюдение на всё дерево | опрос дат папок, как на Android: фоновых событий система не даёт |
/// | имя устройства | `getprop` (производитель и модель) | `Platform.localHostname` | `Platform.localHostname` (`iPad`) |
///
/// Опрос на Android — плата за отказ от `FileObserver`: рекурсивного наблюдения там нет
/// (inotify в Dart не рекурсивный, а запись наблюдателя нужна на каждую папку отдельно, и
/// число таких записей в системе конечно). Поэтому даты папок спрашиваются раз в [pollMs]:
/// создание, удаление и переименование внутри дерева видно за десятки секунд, а правка
/// содержимого уже существующего файла дату папки не меняет — её ловит не событие, а
/// просьба пройти сверку раз в [nudgeMs] и обычные проходы (старт, открытие раздела).
///
/// На iOS к этому добавляется своё ограничение: система не даёт приложению работать в фоне,
/// поэтому синхронизация идёт, только пока приложение открыто, а окно закрытия — единственный
/// момент, когда всё останавливается до следующего запуска.
///
/// ## Чего здесь не бывает
///
/// Исключений. Любая осечка — недоступный `stat`, нечитаемая папка, отказ `Directory.watch` —
/// это «узнать не удалось»: методы возвращают «пусто», а проход продолжается. Мост только
/// ускоряет работу; без него не рушится ничего, кроме распознавания переименований и
/// мгновенного режима.
class NativeFs {
  NativeFs({NativeStat? stat}) : _stat = stat ?? NativeStat.instance;

  /// Чтение номеров файлов: своя раскладка `struct stat` на платформу (см. [NativeStat]).
  final NativeStat _stat;

  /// Как часто спрашивать даты папок на Android ([watch]).
  ///
  /// Пятнадцать секунд — компромисс: чаще означает обход дат по всему дереву на каждом тике,
  /// реже — «мгновенный режим», который замечает новое фото через минуту. У прохода по
  /// событию своя выдержка (`MirrorWatcher.debounceMs`), так что чаще и не нужно.
  static const int pollMs = 15000;

  /// Как часто просить проход, даже если даты папок не изменились.
  ///
  /// Правка содержимого файла дату его папки не меняет, а размер и дата самого файла — вопрос
  /// сверки, а не наблюдателя. Пять минут — это замена фоновому заданию системы, которое
  /// раньше будило проход не чаще чем раз в пятнадцать минут, и то лишь когда приложения нет
  /// на экране; здесь проход идёт, пока приложение открыто.
  static const int nudgeMs = 5 * 60 * 1000;

  /// Предел числа папок под наблюдением на Android.
  ///
  /// Столько же, сколько брал `FileObserver`: на дереве обычного телефона хватает с запасом,
  /// а остальное добирают проходы. Обход до предела идёт один раз при постановке наблюдения,
  /// а дальше на каждом тике читаются только даты уже собранных папок.
  static const int maxWatchedDirs = 4096;

  /// События файловой системы: любое изменение — повод попросить проход. Что именно
  /// поменялось, сверка увидит сама, поэтому имя события не передаётся.
  ///
  /// Поток широковещательный и один на объект: подписчиков может быть несколько
  /// (`MirrorWatcher` — единственный сегодня), а события без подписчиков просто теряются.
  /// Наблюдение ставит [watch], снимает [unwatch]; подписка на поток ничего не включает сама.
  Stream<dynamic> get fileChanges => _changes.stream;

  final StreamController<dynamic> _changes = StreamController<dynamic>.broadcast();

  /// Папки, взятые под наблюдение опросом (Android): их даты читаются на каждом тике.
  List<String> _watched = const [];

  /// Дата изменения каждой наблюдаемой папки на прошлом тике.
  Map<String, int> _stamps = const {};

  /// Тик опроса (Android) и подписки на системный наблюдатель (macOS).
  Timer? _poll;
  final List<StreamSubscription<FileSystemEvent>> _subs = [];

  /// Когда в последний раз просили проход без изменений (см. [nudgeMs]).
  int _lastNudgeAt = 0;

  /// Про корявую раскладку сказано один раз: дальше это просто «номеров нет».
  bool _layoutWarned = false;

  /// Кэш публичного корня внутренней памяти: он нужен и корням, и пробе доступа, а вывод
  /// его значения — обращение к системе.
  String? _publicRoot;

  /// Полный доступ ко всем файлам: без него не видно ни дерева папок, ни содержимого.
  ///
  /// На Android 11 и выше это `MANAGE_EXTERNAL_STORAGE`, и спрашивать о нём не у кого: в Dart
  /// нет `Environment.isExternalStorageManager`. Поэтому признак берётся пробой — читаем
  /// каталог `Android/data`, который система закрывает ровно тем приложениям, у которых этого
  /// разрешения нет. Проба может соврать на прошивке, которая такой каталог всё-таки
  /// показывает, но обратная ошибка («сказали, что доступа нет, хотя он есть») не случится.
  ///
  /// На macOS такого разрешения нет вовсе, и ответ всегда «да»: доступ к папкам решает TCC,
  /// а его отказ виден как нечитаемые папки (`DeviceFiles.subdirs` отдаёт `unreadable`).
  /// Соврать здесь «нет» значило бы запретить синхронизацию человеку, у которого всё в порядке.
  Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    final probe = p.join(await _androidPublicRoot(), 'Android', 'data');
    try {
      // Одного имени из каталога достаточно: листинг ленивый, весь каталог не читается
      Directory(probe).listSync(followLinks: false).take(1).toList();
      return true;
    } on FileSystemException catch (e) {
      // 13 — EACCES: система не пустила. Всё остальное (каталога нет, том не смонтирован)
      // о доступе ничего не говорит, и запрещать синхронизацию из-за этого нельзя
      return e.osError?.errorCode != 13;
    }
  }

  /// Попросить доступ: открывается карточка приложения, откуда два шага до «Доступ ко всем
  /// файлам».
  ///
  /// Прямого экрана «доступ ко всем файлам» из Dart не открыть — это `Intent` с действием
  /// `MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`, а своих `Intent`-ов у приложения больше нет.
  /// Поэтому просьба мягкая: `package:` разбирает системный `ACTION_VIEW`, и на части прошивок
  /// открывается карточка приложения, а на части — ничего. Ничего страшного: путь руками
  /// («Настройки → Приложения → Cloudly → Доступ ко всем файлам») написан в интерфейсе, где
  /// показывается подсказка о доступе.
  ///
  /// Ответа на запрос здесь нет и быть не может: разрешение выдаётся в системном диалоге,
  /// поэтому приложение узнаёт о нём, только вернувшись на экран, — доступ перепроверяет
  /// `SyncController.recheckAccess`.
  Future<void> openAllFilesSettings() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await PackageInfo.fromPlatform();
      await launchUrl(
        Uri.parse('package:${info.packageName}'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // экран не открылся: это тупик, из которого человек выйдет сам, а исключение здесь
      // сорвало бы обработку нажатия
    }
  }

  /// Корни выбора: внутренняя память и съёмные тома на Android, домашняя папка и тома на macOS,
  /// выбранные в «Файлах» папки на iOS.
  ///
  /// При сбое возвращает пустой список — дерево тогда показывает подсказку о доступе.
  Future<List<RootFolder>> storageRoots() async {
    if (Platform.isAndroid) return _androidRoots();
    if (Platform.isMacOS) return _macosRoots();
    if (Platform.isIOS) return _iosRoots();
    return const [];
  }

  /// Корни на iOS: только те папки, которые человек выбрал в системном «Файлах».
  ///
  /// Обойти здесь нечего — приложение не видит ничего за пределами своей песочницы, поэтому
  /// «корней» как таковых нет, а есть ровно выбранные папки. Право на доступ к ним держит
  /// нативная часть ([IosFolders]), и после перезапуска приложения она поднимает его сама.
  Future<List<RootFolder>> _iosRoots() async {
    final folders = await const IosFolders().roots();
    return [for (final folder in folders) RootFolder(folder.path, folder.name)];
  }

  /// Показать системный выбор папки и вернуть выбранную; `null` — не iOS или выбор закрыт.
  ///
  /// Единственный способ получить на iOS папку: браузер файловой системы там показать нечего,
  /// а системный диалог возвращает адрес вместе с правом на доступ к нему.
  Future<RootFolder?> pickFolder() async {
    final picked = await const IosFolders().pick();
    return picked == null ? null : RootFolder(picked.path, picked.name);
  }

  /// Забыть выбранную папку: доступ закрывается, закладка стирается (только iOS).
  Future<void> forgetFolder(String path) => const IosFolders().forget(path);

  /// Корни на Android: внутренняя память первой, дальше съёмные тома.
  ///
  /// Внутренняя память — это тот корень, который выбирают чаще всего, поэтому он первый.
  /// Имя тома взять не у кого (`StorageManager.getDescription` — Android API), поэтому том
  /// подписан своим именем: `1234-5678`. Это единственное, что потерялось по сравнению
  /// с прежним мостом.
  Future<List<RootFolder>> _androidRoots() async {
    final out = <RootFolder>[];
    final root = await _androidPublicRoot();
    if (Directory(root).existsSync()) out.add(RootFolder(root, 'Внутренняя память'));
    try {
      for (final e in Directory('/storage').listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        // `emulated` — это и есть внутренняя память (уже добавлена), `self` — ссылка на неё же
        if (name == 'emulated' || name == 'self' || name.startsWith('.')) continue;
        out.add(RootFolder(e.path, name));
      }
    } on FileSystemException {
      // томов не видно — остаётся внутренняя память
    }
    return out;
  }

  /// Публичный корень внутренней памяти на Android.
  ///
  /// `getExternalStorageDirectory` отдаёт не корень, а каталог самого приложения
  /// (`/storage/emulated/0/Android/data/<пакет>/files`), поэтому хвост до `/Android/`
  /// отрезается. Функция кэширует ответ: он нужен и корням, и пробе доступа, а спрашивать
  /// систему о том же самом на каждом тике сторожа незачем. Если вывод неожиданный, остаётся
  /// привычный путь внутренней памяти.
  Future<String> _androidPublicRoot() async {
    final cached = _publicRoot;
    if (cached != null) return cached;
    var root = '/storage/emulated/0';
    try {
      final dir = await getExternalStorageDirectory();
      final path = dir?.path;
      final cut = path == null ? -1 : path.indexOf('/Android/');
      if (path != null && cut > 0) root = path.substring(0, cut);
    } catch (_) {
      // каталог приложения недоступен: остаётся путь по умолчанию
    }
    _publicRoot = root;
    return root;
  }

  /// Корни на macOS: домашняя папка и подключённые тома.
  ///
  /// Системный диск в `/Volumes` виден символической ссылкой, а ссылки отбрасываются вместе
  /// с `followLinks: false`: без этого домашняя папка и весь диск оказались бы в списке
  /// дважды — как разные корни одного и того же.
  List<RootFolder> _macosRoots() {
    final out = <RootFolder>[];
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && Directory(home).existsSync()) {
      out.add(RootFolder(home, p.basename(home)));
    }
    try {
      for (final e in Directory('/Volumes').listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        out.add(RootFolder(e.path, name));
      }
    } on FileSystemException {
      // томов нет — остаётся домашняя папка
    }
    return out;
  }

  /// Ключ файла в файловой системе: том и номер в нём (см. [FileId]).
  ///
  /// [FileId.unknown] означает «не удалось узнать»: тогда переименование просто не распознаётся
  /// и файл уедет заново — это дороже, но не потеря данных.
  ///
  /// Зовётся по одному файлу там, где файл уже выбран (скачивание, разбор переименований);
  /// на массовом обходе — [ids].
  FileId id(String path) {
    final key = _stat.id(path);
    // Раскладка `struct stat` не сошлась (проверка внутри [NativeStat]): сказать об этом надо
    // один раз, иначе причина «переименования не распознаются» осталась бы невидимой
    if (!_layoutWarned && _stat.layoutOk == false) {
      _layoutWarned = true;
      debugPrint(
        'cloudly-sync: раскладка struct stat не сошлась — ключи файлов недоступны, '
        'переименования будут выглядеть как повторная выгрузка',
      );
    }
    return key;
  }

  /// Ключи файлов пачкой — в том же порядке, что [paths].
  List<FileId> ids(List<String> paths) => _stat.ids(paths);

  /// Как зовётся устройство: этим именем подписывается корень зеркала в облаке.
  ///
  /// На Android это «производитель + модель» из `getprop`, на macOS и iOS — сетевое имя
  /// устройства (на айпаде система отдаёт «iPad»: собственное имя владельца с iOS 16
  /// приложению не показывают).
  /// Имя уходит в выпуск device-токена (`ensureDeviceToken` в `net/device_token.dart`): корень
  /// зеркала сервер заводит по имени токена, и это имя человек видит в облаке как имя папки.
  /// Пустой строки не бывает: если спросить не удалось, возвращается имя системы.
  Future<String> deviceLabel() async {
    if (Platform.isAndroid) {
      try {
        final maker = await _getprop('ro.product.manufacturer');
        final model = await _getprop('ro.product.model');
        final label = '$maker $model'.trim();
        if (label.isNotEmpty) return label;
      } catch (_) {
        // getprop недоступен: подпишемся именем системы
      }
      return 'Android';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      final host = Platform.localHostname;
      return host.isEmpty ? (Platform.isIOS ? 'iPad' : 'Mac') : host;
    }
    return Platform.operatingSystem;
  }

  /// Значение свойства системы через `getprop` — так «производитель» и «модель» узнаются
  /// без нативного кода: `getprop` есть на любом Android и доступен приложению.
  Future<String> _getprop(String key) async {
    final result = await Process.run('getprop', [key]);
    return '${result.stdout}'.trim();
  }

  /// Взять под наблюдение дерево выбранных папок. Возвращает число наблюдаемых папок;
  /// 0 — наблюдать не за чем или система наблюдателя не дала.
  ///
  /// [paths] — корни наблюдения (уже развёрнутые из выбора разделов). Повторный вызов
  /// заменяет прежнее наблюдение, а не добавляет второе.
  ///
  /// Пользуется этим `MirrorWatcher`; он же обязан звать [unwatch], когда наблюдение больше
  /// не нужно (смена выбора папок, выход из аккаунта).
  Future<int> watch(List<String> paths) async {
    await unwatch();
    if (paths.isEmpty) return 0;
    return Platform.isMacOS ? _watchWithSystemWatcher(paths) : _watchWithPolling(paths);
  }

  /// Наблюдение на macOS: системные события файловой системы, рекурсивно на каждый корень.
  ///
  /// `Directory.watch` на macOS идёт через FSEvents и рекурсию поддерживает — одно наблюдение
  /// покрывает всё дерево, без предела на число папок и без обхода дат. Поэтому здесь
  /// и возвращается число корней, а не папок.
  int _watchWithSystemWatcher(List<String> roots) {
    var count = 0;
    for (final root in roots) {
      if (!Directory(root).existsSync()) continue;
      try {
        _subs.add(
          Directory(root).watch(recursive: true).listen(
            (_) => _emitChange(),
            // Ошибка наблюдения (каталог отобрали, том отключили) не должна ронять приложение:
            // про папки, которые перестали быть видны, скажет сверка, а не этот поток
            onError: (Object _) {},
          ),
        );
        count += 1;
      } catch (_) {
        // наблюдателя на этот корень не дали — остальные продолжают работать
      }
    }
    return count;
  }

  /// Наблюдение на Android: обход дерева один раз и опрос дат папок дальше.
  ///
  /// Обход ограничен [maxWatchedDirs] и идёт в ширину: важно взять как можно больше папок
  /// поближе к выбранным — именно там идёт работа человека, — а не уйти в одну ветку до дна.
  /// Служебные каталоги отбрасываются по тем же правилам, что и в обходе зеркала
  /// ([MediaRules.skipDir]), поэтому наблюдаемое дерево совпадает с синхронизируемым.
  int _watchWithPolling(List<String> roots) {
    final dirs = _collectDirs(roots);
    if (dirs.isEmpty) return 0;
    _watched = dirs;
    _stamps = {for (final dir in dirs) dir: _stampOf(dir)};
    _poll = Timer.periodic(const Duration(milliseconds: pollMs), (_) => _pollOnce());
    return dirs.length;
  }

  /// Собрать папки под наблюдение: обход в ширину до [maxWatchedDirs].
  List<String> _collectDirs(List<String> roots) {
    final out = <String>[];
    final queue = Queue<String>()..addAll(roots);
    while (queue.isNotEmpty && out.length < maxWatchedDirs) {
      final dir = queue.removeFirst();
      if (!Directory(dir).existsSync()) continue;
      out.add(dir);
      final parent = p.basename(dir);
      try {
        for (final e in Directory(dir).listSync(followLinks: false)) {
          if (e is! Directory) continue;
          final name = p.basename(e.path);
          if (MediaRules.skipDir(name, parent)) continue;
          queue.add(e.path);
        }
      } on FileSystemException {
        // Папку не прочитать (нет прав): наблюдаем за ней самой — по её дате будет видно,
        // что внутри что-то произошло, — но внутрь не идём
      }
    }
    return out;
  }

  /// Дата изменения папки; 0 — узнать не удалось (папки нет или нет прав).
  int _stampOf(String path) {
    try {
      return Directory(path).statSync().modified.millisecondsSinceEpoch;
    } on FileSystemException {
      return 0;
    }
  }

  /// Один тик опроса: сравнить даты папок и, если что-то изменилось, попросить проход.
  ///
  /// Кроме изменений есть ещё [nudgeMs]: правка содержимого файла дату его папки не меняет,
  /// поэтому раз в пять минут проход просится и без видимой причины — сверка сама увидит,
  /// изменилось ли что-нибудь на самом деле.
  void _pollOnce() {
    var changed = false;
    for (final dir in _watched) {
      final stamp = _stampOf(dir);
      if (_stamps[dir] != stamp) {
        _stamps[dir] = stamp;
        // Дата 0 — папки больше нет: удаление это тоже изменение, о котором надо сказать
        changed = true;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!changed && now - _lastNudgeAt < nudgeMs) return;
    _lastNudgeAt = now;
    _emitChange();
  }

  /// Сказать подписчикам, что в папках что-то произошло.
  void _emitChange() {
    if (_changes.isClosed) return;
    _changes.add('change');
  }

  /// Снять наблюдение со всех папок: зовётся при выходе из аккаунта и при смене выбора.
  /// Идемпотентен (снимать нечего — не ошибка), исключений не бросает.
  Future<void> unwatch() async {
    _poll?.cancel();
    _poll = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _watched = const [];
    _stamps = const {};
  }
}
