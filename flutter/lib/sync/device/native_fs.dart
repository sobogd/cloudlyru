import 'dart:async';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Корень выбора: внутренняя память или карта памяти.
///
/// Приходит из Android ([NativeFs.storageRoots]) и попадает в дерево выбора папок
/// (`folder_tree_screen.dart`); [path] — абсолютный путь, с которого начинается обход,
/// [name] — подпись для человека («Внутренняя память» или описание тома от системы).
class RootFolder {
  const RootFolder(this.path, this.name);

  final String path;
  final String name;
}

/// Мост к Android API, которого нет в Dart: доступ ко всем файлам, тома памяти, номер файла
/// в файловой системе и события файловой системы.
///
/// Всё остальное синхронизатор делает сам, обычными средствами Dart. Сюда вынесено ровно то,
/// для чего нужен системный вызов, — иначе мост разросся бы до второго приложения.
///
/// ## Контракт с нативным Kotlin
///
/// MethodChannel `ru.cloudly.sync/native`, обработчик — `flutter/android/app/src/main/kotlin/
/// ru/cloudly/cloudly_flutter/SyncBridge.kt`:
///
/// | метод | аргументы | ответ Kotlin | что значит «пусто» |
/// |---|---|---|---|
/// | `hasAllFilesAccess` | нет | `Boolean` | `false` — доступа нет или мост недоступен |
/// | `openAllFilesSettings` | нет | `true` (значение не используется) | экран не открылся: ошибки интента глушатся, а на Android 10 вместо экрана показывается системный запрос разрешений |
/// | `storageRoots` | нет | `List<Map<String,String>>` с ключами `path`, `name` | пустой список — томов не видно: внешнее хранилище недоступно или мост не ответил |
/// | `inode` | `{'path': String}` | `Long` | `0` — номер узнать не удалось |
/// | `inodes` | `{'paths': List<String>}` | `List<Long>` той же длины | `0` в позиции — номер неизвестен |
/// | `deviceLabel` | нет | `String` | пустой строки не бывает: Kotlin сам подставляет `Android` |
/// | `watch` | `{'paths': List<String>}` | `Int` — сколько папок взято | `0` — наблюдать не за чем или система не дала |
/// | `unwatch` | нет | `true` (значение не используется) | — |
///
/// Ошибка нативной стороны (в том числе сбой в рабочем потоке моста) приходит сюда
/// `PlatformException`, и её глушат все методы ниже: сбой моста — это «узнать не удалось»,
/// проход из-за него не рушится.
///
/// Числа Kotlin `Long`/`Int` приходят в Dart как `int` (на телефоне он 64-битный), поэтому
/// номер файла в Dart остаётся точным. Неизвестный метод мост отвечает `notImplemented()`,
/// и Dart получает `MissingPluginException` — его глушат все методы ниже.
///
/// EventChannel `ru.cloudly.sync/fileEvents` шлёт строку `change` на изменение в наблюдаемых
/// папках; имя события Dart не разбирает (см. [fileChanges]). Всплеск событий Kotlin склеивает
/// сам, поэтому «одно событие» здесь означает «в папках что-то произошло», а не «изменился
/// один файл».
///
/// ## Где мост есть, а где нет
///
/// Канал ставится один раз на движок Flutter: в приложении — из `MainActivity`, в фоновом
/// задании — из `SyncJobService.startEngine`. Поэтому вызовы работают и из фонового изолята;
/// если движок поднят без моста (или канала ещё нет), любой вызов просто вернёт «пусто», как
/// в таблице выше, и проход продолжится — мост только ускоряет работу, без него не рушится
/// ничего, кроме распознавания переименований и мгновенного режима.
class NativeFs {
  /// [method] и [events] — каналы к Android. По умолчанию это настоящие `ru.cloudly.sync/native`
  /// и `ru.cloudly.sync/fileEvents`; параметры нужны, чтобы подставить свои каналы, не заводя
  /// второй такой же класс.
  NativeFs({MethodChannel? method, EventChannel? events})
      : _method = method ?? const MethodChannel(_methodChannel),
        _events = events ?? const EventChannel(_eventChannel);

  static const String _methodChannel = 'ru.cloudly.sync/native';
  static const String _eventChannel = 'ru.cloudly.sync/fileEvents';

  final MethodChannel _method;
  final EventChannel _events;

  /// Полный доступ ко всем файлам: без него не видно ни дерева папок, ни содержимого.
  ///
  /// Ответ «нет» при любой осечке моста: спрашивать разрешение впустую хуже, чем показать
  /// подсказку, — а мост может быть не зарегистрирован (движок поднят без обработчика канала
  /// или код выполняется не на Android).
  ///
  /// В Android это `Environment.isExternalStorageManager()` на 11 и выше. На Android 10 такого
  /// разрешения не существует вовсе, и там проверяются обычные разрешения на хранилище
  /// (`READ_EXTERNAL_STORAGE` и `WRITE_EXTERNAL_STORAGE`): «да» здесь означает, что доступ
  /// действительно выдан, а не «версия системы старая». Значением пользуется
  /// `sync_controller.dart`, чтобы решить, звать ли человека в системные настройки.
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _method.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Попросить доступ: на Android 11 и выше открывается системный экран «доступ ко всем
  /// файлам», на Android 10 — обычный системный запрос разрешений (открыть экран настроек).
  ///
  /// Аргументов не передаёт и ничего не возвращает; ошибки моста глушит: не открывшийся экран
  /// настроек — это тупик, из которого человек выйдет сам, а исключение здесь сорвало бы
  /// обработку нажатия. Ответа на запрос здесь нет и быть не может: разрешение выдаётся
  /// в системном диалоге, поэтому приложение узнаёт о нём, только вернувшись на экран, —
  /// доступ перепроверяет `SyncController.recheckAccess`.
  Future<void> openAllFilesSettings() async {
    try {
      await _method.invokeMethod<void>('openAllFilesSettings');
    } catch (_) {}
  }

  /// Корни выбора: внутренняя память и карты памяти.
  ///
  /// Ответ Android — список карт `{path, name}`; корни без пути отбрасываются, потому что
  /// обходить папку по пустому пути нельзя, а показывать её в дереве бессмысленно. Отсутствие
  /// ключа и пустое значение значат одно и то же: разбирается через [_sOrNull], иначе
  /// `'${m['path']}'` превратил бы отсутствующий ключ в строку `null` и она прошла бы фильтр.
  /// При сбое моста возвращает пустой список — дерево тогда покажет подсказку о доступе.
  Future<List<RootFolder>> storageRoots() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('storageRoots');
      final out = <RootFolder>[];
      for (final m in (raw ?? const []).whereType<Map>()) {
        final path = _sOrNull(m['path']);
        if (path == null) continue;
        out.add(RootFolder(path, _sOrNull(m['name']) ?? p.basename(path)));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Номер файла в файловой системе. Ноль означает «не удалось узнать»: тогда переименование
  /// просто не распознаётся и файл уедет заново — это дороже, но не потеря данных, поэтому
  /// сбой моста здесь не роняет обход.
  ///
  /// В Android это `st_ino` из `Os.stat`: Dart `FileStat` его не отдаёт, а без номера перенос
  /// папки с видео выглядел бы как удаление и повторная выгрузка. Зовётся по одному файлу там,
  /// где файл уже выбран (скачивание, разбор переименований); на массовом обходе — [inodes].
  Future<int> inode(String path) async {
    try {
      return await _method.invokeMethod<int>('inode', {'path': path}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Номера файлов пачкой: на обходе десятков тысяч файлов один вызов моста вместо каждого —
  /// это разница между «проход идёт» и «проход ползёт». Порядок ответа соответствует порядку
  /// запроса; на сбой отвечаем нулями (см. [inode]).
  ///
  /// Пустой [paths] не гоняем через мост вовсе. Если Android вернул список другой длины (мост
  /// перепутал соответствие), ответ не принимается: перепутанные номера хуже неизвестных, они
  /// заставили бы зеркало считать чужие файлы своими.
  Future<List<int>> inodes(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('inodes', {'paths': paths});
      if (raw == null || raw.length != paths.length) return List<int>.filled(paths.length, 0);
      return [for (final v in raw) v is int ? v : 0];
    } catch (_) {
      return List<int>.filled(paths.length, 0);
    }
  }

  /// Как зовётся устройство: этим именем подписывается корень зеркала в облаке.
  ///
  /// В Android это «производитель + модель»; если получилась пустая строка (или мост ответил
  /// ошибкой), возвращается `Android`. Имя уходит в выпуск device-токена
  /// (`ensureDeviceToken` в `net/device_token.dart`): корень зеркала сервер заводит по имени
  /// токена, и это имя человек видит в облаке как имя папки.
  Future<String> deviceLabel() async {
    try {
      return await _method.invokeMethod<String>('deviceLabel') ?? 'Android';
    } catch (_) {
      return 'Android';
    }
  }

  /// Взять под наблюдение дерево выбранных папок. Возвращает число наблюдаемых папок;
  /// 0 — наблюдать не за чем или система не дала (тогда остаётся периодический проход).
  ///
  /// [paths] — корни наблюдения (уже развёрнутые из выбора разделов). Android обходит их
  /// в ширину и берёт не больше 4096 папок: у `FileObserver` одна запись на папку, а их число
  /// в системе конечно; глубже предела изменения поймает периодический проход. Обход идёт
  /// в рабочем потоке моста, поэтому дерево на тысячи папок не морозит интерфейс. Повторный
  /// вызов заменяет прежнее наблюдение, а не добавляет второе.
  ///
  /// Пользуется этим `MirrorWatcher`; он же обязан звать [unwatch], когда наблюдение больше
  /// не нужно (смена выбора папок, выход из аккаунта): подписка на события наблюдение
  /// не снимает — она только снимает его вместе с собой (см. [fileChanges]).
  Future<int> watch(List<String> paths) async {
    try {
      return await _method.invokeMethod<int>('watch', {'paths': paths}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Снять наблюдение со всех папок: зовётся при выходе из аккаунта и при смене выбора.
  /// Идемпотентен (снимать нечего — не ошибка), исключений не бросает.
  ///
  /// Снимать обязательно тому, кто ставил: пока наблюдение стоит, система держит до 4096
  /// записей inotify, а события уходят в никуда. Единственное исключение — отмена подписки
  /// на поток событий ([fileChanges]): тогда наблюдение снимает сам Android (в `onCancel`
  /// канала), потому что подписчик уже ушёл и позвать [unwatch] ему некому.
  Future<void> unwatch() async {
    try {
      await _method.invokeMethod<void>('unwatch');
    } catch (_) {}
  }

  /// События файловой системы: любое изменение — повод попросить проход. Что именно
  /// поменялось, сверка увидит сама, поэтому имя события не передаётся.
  ///
  /// Поток broadcast и один на объект: подписка на платформенный канал одна, сколько бы
  /// слушателей ни было. Ошибки канала приходят ошибками этого же потока — своего обработчика
  /// здесь нет, их видит подписчик (`MirrorWatcher`).
  ///
  /// Когда последний слушатель отписывается, подписка на канал закрывается — а вместе с ней
  /// Android снимает наблюдение за папками (см. `SyncBridge.onCancel`). Следующая подписка
  /// поднимает подписку на канал заново: поток тот же, «мёртвым» после отмены он не остаётся,
  /// и держать в объекте ссылку на закрытую подписку не приходится.
  Stream<dynamic> get fileChanges => _changeStream ??= _openChanges();

  Stream<dynamic>? _changeStream;

  Stream<dynamic> _openChanges() {
    StreamSubscription<dynamic>? sub;
    late final StreamController<dynamic> controller;
    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        sub = _events.receiveBroadcastStream().listen(
          controller.add,
          onError: controller.addError,
        );
      },
      onCancel: () {
        // Ссылку обнуляем синхронно: подписка на канал уже не нужна, а ждать её закрытия
        // здесь нечего — событий после отмены всё равно не будет
        final current = sub;
        sub = null;
        unawaited(current?.cancel());
      },
    );
    return controller.stream;
  }

  /// Чтение строки из ответа моста, где `null` и пустая строка значат одно и то же —
  /// «значения нет». Своя копия `SyncApi._sOrNull`: слой сети не должен быть нужен мосту,
  /// а `'${m['path']}'` превращает отсутствующий ключ в строку `null`.
  static String? _sOrNull(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty || s == 'null' ? null : s;
  }
}
