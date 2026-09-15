import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Проверка версии и обновление по кнопке — тот же флоу, что был у нативного клиента:
/// `/app/android` отдаёт последнюю сборку, приложение сравнивает versionCode со своим,
/// скачивает APK, сверяет размер и sha256 и открывает системный установщик.
class UpdaterPanel extends ConsumerStatefulWidget {
  const UpdaterPanel({super.key});

  @override
  ConsumerState<UpdaterPanel> createState() => _UpdaterPanelState();
}

class _UpdaterPanelState extends ConsumerState<UpdaterPanel> {
  int _currentCode = 0;
  String _currentName = '';
  AppRelease? _latest;
  String? _error;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _init();
    _check();
  }

  Future<void> _init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _currentCode = int.tryParse(info.buildNumber) ?? 0;
          _currentName = info.version;
        });
      }
    } catch (_) {}
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final latest = await ref.read(appStateProvider).api.latestApp();
      debugPrint('updater: current=$_currentCode latest=${latest.versionCode}');
      if (mounted) setState(() => _latest = latest);
    } catch (e) {
      debugPrint('updater error: $e');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool get _hasUpdate => _latest != null && _latest!.versionCode > _currentCode;

  Future<void> _update() async {
    final latest = _latest;
    if (latest == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/cloudly-update.apk';
      final dio = Dio();
      await dio.download(latest.url, path, onReceiveProgress: (r, t) {
        if (mounted && t > 0) setState(() => _progress = r / t);
      });
      final f = File(path);
      final size = await f.length();
      if (latest.size > 0 && size != latest.size) {
        throw Exception('размер не совпал: ${fmt(size)} вместо ${fmt(latest.size)}');
      }
      final sha = await ref.read(appStateProvider).api.hashFile(path);
      if (latest.sha256.isNotEmpty && sha.toLowerCase() != latest.sha256.toLowerCase()) {
        throw Exception('sha256 не совпал — сборка повреждена');
      }
      await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
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
              onPressed: _checking || _downloading ? null : _check,
              child: _checking ? const Text('…') : const Text('Проверить'),
            ),
          ]),
          Text('текущая версия: $_currentName (${_currentCode})',
              style: const TextStyle(color: C.fg3, fontSize: 13)),
          if (latest != null) ...[
            const SizedBox(height: 2),
            Text('на сервере: ${latest.versionName} (${latest.versionCode})',
                style: const TextStyle(color: C.fg3, fontSize: 13)),
            const SizedBox(height: 8),
            if (_downloading) ...[
              LinearProgressIndicator(value: _progress, minHeight: 4, color: C.accent),
              const SizedBox(height: 6),
              Text('скачиваю… ${(_progress * 100).round()}%',
                  style: const TextStyle(color: C.fg3, fontSize: 12)),
            ] else if (_hasUpdate)
              FilledButton(
                onPressed: _update,
                child: Text('Обновить до ${latest.versionName}'),
              )
            else
              const Text('у вас последняя версия', style: TextStyle(color: C.ok, fontSize: 13)),
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
