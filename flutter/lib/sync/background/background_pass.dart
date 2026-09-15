import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/mirror_store.dart';
import '../data/queue_store.dart';
import '../data/selection.dart';
import '../data/sync_prefs.dart';
import '../device/device_files.dart';
import '../device/native_fs.dart';
import '../mirror/mirror_engine.dart';
import '../net/device_token.dart';
import '../net/sync_api.dart';
import '../queue/queue_refresher.dart';
import 'background_bridge.dart';
import 'background_schedule.dart';

/// Сколько отведено зеркалу за одно задание.
///
/// Система даёт заданию около десяти минут, а движок по умолчанию берёт восемь: выгрузка
/// гигабайтов идёт часами, и незаконченный проход не беда — сверка идемпотентна, остаток
/// доедет следующим. Здесь чуть меньше, чтобы осталось время на очередь и на честный ответ
/// системе, а не на обрыв по её таймауту.
const int backgroundPassBudgetMs = 7 * 60 * 1000;

/// Дольше этого наполнять очередь в фоне не начинаем: не оставляем работу, которую система
/// всё равно прервёт на середине. Очередь — подготовка, её догонит приложение.
const int queueRefreshDeadlineMs = 6 * 60 * 1000;

/// Итог последнего фонового прохода: время и что вышло. Ключ свой, чтобы приложение могло
/// показать, что ночью что-то делалось, и чтобы это было видно без логов.
const String keyBackgroundReport = 'bg_last_report';

/// Один фоновый проход, целиком: от проверок до ответа системе.
///
/// Порядок тот же, что у нативного клиента (`MirrorJobService`): сначала выясняем, есть ли
/// вообще чем работать, и только потом берёмся за диск и сеть. Если автоматика выключена
/// пользователем или токена устройства нет, задание тихо ничего не делает — это не ошибка.
Future<void> runBackgroundPass(BackgroundChannel channel) async {
  var cancelled = false;
  channel.onCancel = () => cancelled = true;

  var ok = false;
  var note = '';
  try {
    // Остановку могли попросить, пока слушатель ещё не встал: у той стороны есть и флаг.
    cancelled = await channel.stopRequested();
    final result = await _pass(() => cancelled);
    ok = result.$1;
    note = result.$2;
  } catch (e) {
    note = 'фоновый проход упал: $e';
  }

  _log(note);
  try {
    await channel.finished(ok: ok, note: note);
  } catch (e) {
    // Приложение могло закрыться вместе с движком: тогда отвечать уже некому, и это не беда.
    _log('итог не доставлен: $e');
  }
}

Future<(bool, String)> _pass(bool Function() cancelled) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(BackgroundSync.keyEnabled) != true) {
    return (true, 'задание снято: ничего не делаю');
  }
  // Приложение на экране: там мгновенный режим, он замечает изменения за секунды, а наложенный
  // проход из фона спорил бы с ним за одни и те же базы (движок держит замок «один проход за
  // раз» только внутри своего изолята).
  if (await _appInForeground()) {
    return (true, 'приложение на экране: работает мгновенный режим');
  }

  final server = prefs.getString(BackgroundSync.keyServer) ?? '';
  final login = prefs.getString(BackgroundSync.keyLogin) ?? '';
  if (server.isEmpty || login.isEmpty) return (true, 'неизвестен аккаунт: ничего не делаю');

  final token = await DeviceTokenStore().read(server, login);
  if (token == null) return (true, 'нет токена устройства: ничего не делаю');
  final api = SyncApi(serverUrl: server, token: token.token);

  MirrorStore? mirrorStore;
  QueueStore? queueStore;
  final startedAt = DateTime.now().millisecondsSinceEpoch;
  try {
    mirrorStore = await MirrorStore.open();
    // Автоматика выключена пользователем: ручная сверка из настроек при этом работает,
    // а фон обязан молчать — иначе выключатель врал бы.
    if (await mirrorStore.meta(MirrorStore.keyPaused) == '1') {
      return (true, 'зеркало выключено: ничего не делаю');
    }
    queueStore = await QueueStore.open();

    final selection = Selection(prefs);
    final native = NativeFs();
    final engine = MirrorEngine(() => api, mirrorStore, selection, native: native);
    final report = await engine.pass(
      budgetMs: backgroundPassBudgetMs,
      isCancelled: cancelled,
      onProgress: _log,
    );

    // Очередь — только если время осталось: она подготовка, а не срочная работа.
    var queueNote = '';
    final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
    if (!cancelled() && elapsed < queueRefreshDeadlineMs) {
      queueNote = await _refreshQueue(api, prefs, selection, queueStore, native);
    }

    final note = [report.text(), queueNote].where((s) => s.isNotEmpty).join(' · ');
    await _remember(mirrorStore, '$note (${DateTime.now().toIso8601String()})');
    return (report.error == null, note);
  } finally {
    // Базы закрываем всегда: задание короткое, а незакрытые соединения остаются в процессе
    // приложения до самого его конца. Чужие соединения (в том числе приложения) это не трогает:
    // у каждого движка свой обработчик плагина.
    await _close(queueStore);
    await _closeMirror(mirrorStore);
  }
}

Future<bool> _appInForeground() async {
  try {
    return await BackgroundChannel().appInForeground();
  } catch (_) {
    // Канал недоступен: считаем, что приложения на экране нет — проход важнее догадки.
    return false;
  }
}

Future<String> _refreshQueue(
  SyncApi api,
  SharedPreferences prefs,
  Selection selection,
  QueueStore store,
  NativeFs native,
) async {
  try {
    final refresher = QueueRefresher(
      () => api,
      SyncPrefs(prefs),
      selection,
      store,
      DeviceFiles(native: native),
    );
    final result = await refresher.refresh(onProgress: _log);
    return result.text();
  } catch (e) {
    return 'очередь не обновлена: $e';
  }
}

Future<void> _remember(MirrorStore store, String value) async {
  try {
    await store.setMeta(keyBackgroundReport, value);
  } catch (_) {
    // Память о проходе — удобство, а не работа: не из-за неё ронять задание.
  }
}

Future<void> _close(QueueStore? store) async {
  try {
    await store?.close();
  } catch (_) {}
}

Future<void> _closeMirror(MirrorStore? store) async {
  try {
    await store?.close();
  } catch (_) {}
}

/// Журнал фонового прохода: уходит в logcat (`I/flutter`), другого экрана у задания нет.
void _log(String message) => debugPrint('cloudly-sync[фон]: $message');
