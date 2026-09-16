import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'macos_update.dart';

/// Проверка версии и обновление по кнопке — тот же флоу, что был у нативного клиента:
/// `/app/android` отдаёт последнюю сборку, приложение сравнивает versionCode со своим,
/// скачивает APK, сверяет размер и sha256 и открывает системный установщик.
///
/// На macOS ручка другая (`/app/macos`), а установщика нет вовсе: приложение подменяет свою
/// сборку само — скачивает архив, кладёт рядом скрипт-помощник и выходит, а помощник ставит
/// новую сборку и запускает её (см. `macos_update.dart`). Номер сборки у платформ общий:
/// `+N` из `pubspec.yaml` — это и `versionCode` на Android, и `CFBundleVersion` на маке.
///
/// Почему именно так, а не «просто открыть ссылку»: приложение ставится мимо магазина,
/// а значит обновление — это замена сборки поверх. Проверки размера и хеша нужны
/// потому, что файл едет по сети от того же сервера, что и файлы: битая или подменённая сборка
/// дошла бы до установки, и последствия были бы уже необратимы.
///
/// Панель сама себя не обновляет по таймеру: проверка версии — действие по кнопке, а не
/// фоновый процесс. При открытии настроек она проверяет версию один раз.
class UpdaterPanel extends ConsumerStatefulWidget {
  const UpdaterPanel({super.key});

  @override
  ConsumerState<UpdaterPanel> createState() => _UpdaterPanelState();
}

/// Состояние панели: своя версия, версия на сервере и ход скачивания.
class _UpdaterPanelState extends ConsumerState<UpdaterPanel> {
  /// versionCode текущей сборки (из манифеста, а не из имени версии): именно по нему
  /// сравниваются сборки.
  int _currentCode = 0;
  /// Человеческое имя текущей версии — только для показа.
  String _currentName = '';
  /// Последняя сборка с сервера; `null` — ещё не проверяли или описания сборки нет.
  AppRelease? _latest;
  String? _error;
  /// Сервер ответил `no_release`: APK в бакете лежит, но описания сборки (`latest.json`) рядом
  /// с ним нет, и версии у такой сборки тоже нет. Это не сбой и не «обновление» — про такое
  /// состояние панель говорит отдельной строкой.
  bool _noRelease = false;
  /// Идёт проверка версии: блокирует кнопку «Проверить».
  bool _checking = false;
  /// Идёт скачивание APK: блокирует и проверку, и повторное обновление.
  bool _downloading = false;
  /// Прогресс скачивания от 0 до 1 — для полосы под версиями.
  double _progress = 0;
  /// Отмена текущего скачивания: кнопка «Отмена» и `dispose` обрывают запрос этим токеном.
  CancelToken? _cancel;
  /// Скачивание отменил человек — об этом говорится строкой, иначе после нажатия «Отмена»
  /// экран просто замирал бы без объяснения.
  bool _cancelled = false;
  /// Своя версия прочитана (или попытка чтения провалилась).
  ///
  /// До этого сравнивать не с чем: `_currentCode` равен нулю, и актуальная сборка на сервере
  /// выглядела бы новее. Поэтому и кнопка «Проверить», и `_hasUpdate` ждут этот признак,
  /// а не только порядок вызовов в `_bootstrap`.
  bool _ready = false;

  @override
  /// Читаем свою версию и сразу проверяем, нет ли новой.
  void initState() {
    super.initState();
    // Не `await` в `initState` — поэтому отдельная задача: порядок внутри неё и есть смысл
    // (`_bootstrap`), а сам метод остаётся синхронным.
    unawaited(_bootstrap());
  }

  @override
  /// Панель закрыли: обрываем загрузку, которую уже некому показывать.
  void dispose() {
    // Без этого запрос продолжил бы писать APK во временный каталог, а его колбэки —
    // звать `setState` у уничтоженного состояния.
    _cancel?.cancel();
    super.dispose();
  }

  /// Читает свою версию, и только потом спрашивает сервер.
  ///
  /// Раньше `_init()` и `_check()` запускались параллельно, и проверка успевала пройти
  /// с `_currentCode == 0`: у актуальной сборки на миг появлялась кнопка «Обновить до …»,
  /// а потом исчезала. Сравнивать версии, не прочитав свою, нельзя — поэтому по очереди.
  Future<void> _bootstrap() async {
    await _init();
    if (!mounted) return;
    await _check();
  }

  /// Читает версию установленной сборки.
  ///
  /// `buildNumber` приходит строкой, поэтому парсится: у сборок без номера остаётся 0,
  /// и тогда любая сборка на сервере считается новее. Ошибку глотаем — версия нужна только
  /// для сравнения, и без неё панель всё равно работает.
  Future<void> _init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _currentCode = int.tryParse(info.buildNumber) ?? 0;
        _currentName = info.version;
      });
    } catch (_) {
      // Версия не прочиталась: номер останется нулём, и любая сборка на сервере окажется
      // новее. Это безопасная сторона ошибки — предложить обновление лучше, чем решить,
      // что обновления нет.
    } finally {
      // «Своя версия прочитана» — разовое событие, и до него проверять нечего: и кнопка,
      // и сравнение версий ждут именно его.
      if (mounted) setState(() => _ready = true);
    }
  }

  /// Спрашивает у сервера последнюю сборку — своей платформы.
  ///
  /// Побочно: `_latest`, `_noRelease`, `_error`, `_checking` — последний крутит многоточие
  /// на кнопке и не даёт нажать её дважды. Ошибку показываем строкой: без ответа сервера
  /// сказать «у вас последняя версия» было бы враньём.
  ///
  /// Отдельная ветка — `no_release`: файл сборки в бакете есть, а описания сборки рядом с ним
  /// нет, и сервер отвечает на это 404 с кодом `no_release`. Это не сбой проверки (сеть в
  /// порядке) и не битая сборка — обновляться просто не на что, и панель говорит именно это.
  /// На маке эта ветка обычна: настольную сборку публикуют отдельно от мобильной, и пока её
  /// не собирали, обновляться действительно не на что.
  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final api = ref.read(appStateProvider).api;
      final latest = Platform.isMacOS ? await api.latestAppMacos() : await api.latestApp();
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _noRelease = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'no_release') {
          // Сборки на сервере нет вовсе: прежний ответ (если он был) больше не про эту
          // сборку, а ошибки тут нет — есть «обновляться не на что».
          _latest = null;
          _noRelease = true;
          _error = null;
        } else {
          // Прочие отказы — это сбой проверки: показанную ранее версию не трогаем, она
          // от сети не изменилась, и рядом со строкой ошибки человек видит, что знал раньше.
          _noRelease = false;
          _error = e.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Есть ли что обновлять: сравниваются versionCode, а не имена версий.
  ///
  /// Имя версии — для человека, а порядок сборок задаёт числовой код: «1.10.0» против «1.9.0»
  /// по строкам сравнивается неверно, по числам — правильно. Пока сервер не ответил,
  /// обновлять нечего.
  ///
  /// `versionCode == 0` в модели означает «описания сборки нет». Эта ручка такого ответа
  /// больше не отдаёт (сборку без описания сервер закрывает кодом `no_release`), но проверка
  /// остаётся: с нулём сравнивать нечего, и обновлением он считаться не должен ни при каких
  /// условиях — иначе кнопка «Обновить» вела бы на сборку, у которой неизвестна версия.
  bool get _hasUpdate {
    final latest = _latest;
    // Пока своя версия не прочитана, сравнивать не с чем: `_currentCode` равен нулю, и
    // у актуальной сборки на миг появилась бы кнопка «Обновить до …».
    if (!_ready || latest == null) return false;
    return latest.versionCode > 0 && latest.versionCode > _currentCode;
  }

  /// Скачивает сборку, проверяет её и передаёт установке — своей для каждой платформы.
  ///
  /// Проверки идут по возрастанию строгости: сначала размер (быстро, ловит обрыв загрузки),
  /// потом sha256 (считает сервер, ловит подмену и порчу файла — размер при этом может
  /// совпасть). Только после обеих сборка идёт дальше: непроверенную ставить нельзя,
  /// откатить установку будет нечем. `size > 0` и непустой `sha256` в проверках — не
  /// формальность: у старых релизов этих полей в ответе нет, и сравнивать не с чем.
  ///
  /// Дальше платформы расходятся: на Android файл отдаётся системному установщику APK,
  /// на macOS приложение подменяет свою сборку и выходит (см. [installMacosUpdate]).
  ///
  /// Побочно: файл во временном каталоге (имя фиксировано, чтобы повторное скачивание затирало
  /// прежний), `_progress` на каждом принятом куске, `_downloading`, `_cancel`, `_error`.
  Future<void> _update() async {
    final latest = _latest;
    if (latest == null) return;
    final cancel = CancelToken();
    setState(() {
      _downloading = true;
      _cancelled = false;
      _progress = 0;
      _error = null;
      _cancel = cancel;
    });
    // Каталог и остаток прошлого скачивания — до загрузки: имя файла фиксировано, и
    // недокачанный файл иначе лежал бы во временном каталоге до переустановки приложения.
    // Файл объявлен снаружи `try`, чтобы `finally` мог его убрать, а сам разбор пути идёт
    // внутри: упасть он тоже может, и «идёт скачивание» не должно остаться на экране навсегда.
    File? file;
    // Файл отдан установке: только тогда его можно оставить на диске (см. `finally`).
    var handedOver = false;
    try {
      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/${Platform.isMacOS ? 'cloudly-update.zip' : 'cloudly-update.apk'}');
      await _delete(file);
      final dio = Dio();
      await dio.download(latest.url, file.path, cancelToken: cancel, onReceiveProgress: (r, t) {
        if (mounted && t > 0) setState(() => _progress = r / t);
      });
      final size = await file.length();
      // Размер проверяем первым: он уже есть у файла на диске, а сорвавшаяся загрузка
      // (обрыв сети, нехватка места) видна именно здесь и без вычисления хеша.
      if (latest.size > 0 && size != latest.size) {
        throw Exception('размер не совпал: ${fmt(size)} вместо ${fmt(latest.size)}');
      }
      final sha = await ref.read(appStateProvider).api.hashFile(file.path);
      // Хеш считает сервер по своей копии, клиент — по скачанной: расхождение означает порчу
      // или подмену файла, и такую сборку ставить нельзя. Регистр сравниваем сами: сервер может
      // отдать хеш в верхнем регистре.
      if (latest.sha256.isNotEmpty && sha.toLowerCase() != latest.sha256.toLowerCase()) {
        throw Exception('sha256 не совпал — сборка повреждена');
      }
      if (Platform.isMacOS) {
        // Дальше эта функция не возвращается: приложение выходит, а замену доводит помощник.
        // Файл ему нужен целым, поэтому `handedOver` выставляется до вызова — иначе `finally`
        // успел бы его удалить.
        handedOver = true;
        await installMacosUpdate(file);
      }
      await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      handedOver = true;
    } on DioException catch (e) {
      // Отмена — не ошибка: её запросил сам человек, и сообщать ему не о чем. Отменённый
      // запрос приходит именно `DioException`, поэтому проверка стоит в этой ветке.
      if (!CancelToken.isCancel(e) && mounted) {
        setState(() => _error = e.toString());
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      // Файл удаляем, если установщик его так и не получил: недокачанный или не прошедший
      // проверку APK во временном каталоге не нужен никому. Сразу после `OpenFilex.open`
      // удалять нельзя: система читает файл уже после старта активити, когда человек
      // подтвердит установку, и установка сорвалась бы — такой файл уберётся перед следующей
      // загрузкой.
      if (!handedOver) await _delete(file);
      if (mounted) {
        setState(() {
          _downloading = false;
          _cancel = null;
        });
      }
    }
  }

  /// Отменяет идущее скачивание: обрывает запрос, файл за собой убирает [_update].
  ///
  /// Побочно: `_cancelled` — по нему после отмены показывается строка «скачивание отменено».
  void _cancelDownload() {
    setState(() => _cancelled = true);
    _cancel?.cancel();
  }

  /// Удаляет файл, если он есть; `null` — файла и не было (путь не успели собрать).
  ///
  /// Ошибку глотаем: файла может не быть вовсе, а если он занят или каталог только для
  /// чтения — это не повод показывать человеку ошибку обновления.
  static Future<void> _delete(File? f) async {
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Обновление', style: TextStyle(color: C.fg, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              // Во время проверки или скачивания кнопка выключена: две параллельные загрузки
              // писали бы в один и тот же файл. До чтения своей версии — тоже: сравнивать
              // в этот момент нечего.
              onPressed: (_checking || _downloading || !_ready) ? null : _check,
              child: (_checking || !_ready) ? const Text('…') : const Text('Проверить'),
            ),
          ]),
          // Свою версию показываем всегда, версию с сервера — только когда она известна:
          // строка «на сервере: …» без ответа сервера смысла не имеет.
          Text('текущая версия: $_currentName ($_currentCode)',
              style: const TextStyle(color: C.fg3, fontSize: 13)),
          if (latest != null) ...[
            const SizedBox(height: 2),
            Text('на сервере: ${latest.versionName} (${latest.versionCode})',
                style: const TextStyle(color: C.fg3, fontSize: 13)),
            const SizedBox(height: 8),
            if (_downloading) ...[
              LinearProgressIndicator(value: _progress, minHeight: 4, color: C.accent),
              const SizedBox(height: 6),
              Row(children: [
                Text('скачиваю… ${(_progress * 100).round()}%',
                    style: const TextStyle(color: C.fg3, fontSize: 12)),
                const Spacer(),
                TextButton(onPressed: _cancelDownload, child: const Text('Отмена')),
              ]),
            ] else if (_hasUpdate) ...[
              FilledButton(
                onPressed: _update,
                child: Text('Обновить до ${latest.versionName}'),
              ),
              // На маке установщика нет: приложение подменяет свою сборку и перезапускается
              // само, и об этом стоит сказать до нажатия, а не после
              if (Platform.isMacOS) ...[
                const SizedBox(height: 4),
                const Text('приложение закроется, заменит сборку и откроется заново',
                    style: TextStyle(color: C.fg3, fontSize: 12)),
              ],
            ]
            // «Последняя версия» говорится только про сборку, у которой версия вообще есть:
            // у сборки без описания сравнивать нечего, и обещать тут нечего тоже.
            else if (latest.versionCode > 0)
              const Text('у вас последняя версия', style: TextStyle(color: C.ok, fontSize: 13)),
          ],
          if (_noRelease) ...[
            const SizedBox(height: 6),
            const Text('сборка ещё не опубликована — обновляться не на что',
                style: TextStyle(color: C.fg3, fontSize: 12)),
          ],
          if (_cancelled && !_downloading) ...[
            const SizedBox(height: 6),
            const Text('скачивание отменено', style: TextStyle(color: C.fg3, fontSize: 12)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(color: C.danger, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}
