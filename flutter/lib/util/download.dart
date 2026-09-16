import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/cloudly_api.dart';

/// Сколько скачанное живёт во временном каталоге. Каталог общий на всё приложение и ничем не
/// ограничен, а скачивают из него в основном для того, чтобы один раз открыть: держать файлы
/// дольше смысла нет, а место они занимают настоящее.
const _keepFor = Duration(days: 1);

/// Идентификаторы записей, которые качаются прямо сейчас.
///
/// По этому набору отсекается повторное нажатие «Скачать» на том же файле: два `dio.download`
/// в один и тот же путь писали бы в один файл наперегонки, и открылся бы мусор.
final Set<String> _inFlight = {};

/// Качает файл из облака во временную папку и открывает его системным обработчиком.
///
/// [api] нужен дважды: адрес содержимого ([CloudlyApi.fileUrl]) и Cookie веб-сессии
/// ([CloudlyApi.authHeaders]) — ручка `/files/:id/content` закрыта авторизацией. Скачиваем
/// отдельным [Dio]: Dio самого клиента ходит относительными путями от `/api/v1`, а здесь нужен
/// готовый абсолютный URL и запись сразу в файл. [name] — имя из списка файлов; от расширения
/// зависит, какое приложение выберет система, поэтому имя не подменяем.
///
/// [url] — готовый адрес, если содержимое лежит не на файловой ручке. Так качается исходное
/// письмо (`.eml`): у него свой адрес `/mail/messages/:id/raw`, а `/files/<id письма>/content`
/// отвечает 404, потому что id письма — не запись файлового дерева.
///
/// [entryId] при этом остаётся ключом отсечки повторных нажатий, поэтому для нештатных адресов
/// его надо передавать уникальным (`mail:<id>`), иначе две разные ручки с одним id считались бы
/// одной загрузкой.
///
/// Возвращает `null`, если файл скачан и отдан системе, иначе — короткий текст для человека:
/// его показывают экраны через `snack`. Исключения не выбрасываются: вызовы идут из
/// обработчиков нажатия без `await`, и упавший фьюч иначе пропал бы без следа — ни файла,
/// ни сообщения.
///
/// Побочные эффекты: файл оказывается во временной папке приложения под своим именем
/// (одноимённый перезаписывается), отдаётся наружу через open_filex, а из временного каталога
/// перед скачиванием убирается всё старше [_keepFor].
Future<String?> downloadAndOpen(
  CloudlyApi api,
  String entryId,
  String name, {
  String? url,
}) async {
  if (!_inFlight.add(entryId)) return 'этот файл уже скачивается';
  try {
    final dir = await getTemporaryDirectory();
    await _cleanOld(dir);
    final path = '${dir.path}/${_safeName(name, entryId)}';
    try {
      final dio = Dio();
      await dio.download(
        url ?? api.fileUrl(entryId),
        path,
        options: Options(headers: api.authHeaders),
      );
    } catch (e) {
      // Недокачанный файл оставлять нельзя: следующий раз он откроется как целый
      await _delete(path);
      return 'не удалось скачать: $e';
    }
    final failure = await _open(path);
    if (failure != null) return failure;
    return null;
  } catch (e) {
    return 'не удалось скачать или открыть файл: $e';
  } finally {
    _inFlight.remove(entryId);
  }
}

/// Открыть скачанный файл системным способом: `null` — получилось, иначе текст ошибки.
///
/// Платформы расходятся: на Android это `open_filex` (передаёт файл приложению через
/// `FileProvider` и умеет сказать, что открывать нечем), на macOS — `open` из системы, который
/// и есть «открыть файл как из Finder»: `open_filex` настольную сборку не поддерживает вовсе.
Future<String?> _open(String path) async {
  if (!Platform.isMacOS) {
    final result = await OpenFilex.open(path);
    if (result.type == ResultType.done) return null;
    if (result.type == ResultType.noAppToOpen) {
      return 'на устройстве нечем открыть этот файл';
    }
    return 'не удалось открыть файл: ${result.message}';
  }
  try {
    final result = await Process.run('open', [path]);
    if (result.exitCode == 0) return null;
    final reason = '${result.stderr}'.trim();
    return 'не удалось открыть файл: $reason';
  } catch (e) {
    return 'не удалось открыть файл: $e';
  }
}

/// Имя файла для временного каталога.
///
/// Имя пришло с сервера, то есть управлять им может и чужой человек: разделители пути в нём
/// увели бы запись из каталога загрузок, а `.`/`..` — в родительский каталог. Пустое имя
/// дало бы путь, оканчивающийся на `/`, поэтому его (как и небезопасное) заменяем на id записи.
String _safeName(String name, String entryId) {
  final cleaned = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return entryId;
  return cleaned;
}

/// Убирает из временного каталога файлы старше [_keepFor].
///
/// Ошибки глушим: не убранный старый файл — не повод не скачать нужный.
Future<void> _cleanOld(Directory dir) async {
  try {
    final deadline = DateTime.now().subtract(_keepFor);
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final st = await e.stat();
      if (st.modified.isBefore(deadline)) await _delete(e.path);
    }
  } catch (_) {}
}

/// Удаляет файл, если он есть. Ошибку удаления глушим — файла может уже не быть,
/// а сообщать о неудачной уборке временного каталога нечего.
Future<void> _delete(String path) async {
  try {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}
