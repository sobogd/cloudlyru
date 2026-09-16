import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/data/sync_links.dart';
import '../../sync/sync_controller.dart';
import '../../sync/ui/cloud_folder_picker_screen.dart';
import '../../sync/ui/folder_tree_screen.dart';
import '../../theme.dart';

/// Связки раздела «Файлы»: что с чем синхронизировать.
///
/// Каждая связка — пара «папка на устройстве ↔ папка в облаке», и обе стороны человек выбирает
/// из существующего: ни папок на телефоне, ни папок в облаке здесь не заводится. Раньше пары
/// складывались сами (сервер заводил устройству папку `‹Имя устройства› - Файлы`), и это
/// убрано: связку задаёт человек, а не приложение.
///
/// Удаление связки ничего не удаляет в облаке: синхронизация по этой паре прекращается,
/// а папка и файлы остаются как есть. Вернуть связку можно той же парой — выгружать заново
/// не придётся.
///
/// Открывается из «Настроек» → «Синхронизация» → «Папки для файлов».
class SyncLinksScreen extends ConsumerStatefulWidget {
  const SyncLinksScreen({super.key});

  @override
  ConsumerState<SyncLinksScreen> createState() => _SyncLinksScreenState();
}

/// Состояние экрана: список связок, признак работы и текст отказа.
///
/// Своего списка экран не держит: связки читаются из настроек через [SyncController] —
/// так экран показывает то же, по чему работает зеркало, и не может разойтись с ним.
class _SyncLinksScreenState extends ConsumerState<SyncLinksScreen> {
  /// Идёт добавление или удаление: кнопки на это время выключены (второй заход переписал бы
  /// тот же список).
  bool _busy = false;

  /// Текст отказа: показывается над списком, снимается следующей удачной правкой.
  String? _error;

  SyncController get _sync => ref.read(syncControllerProvider);

  /// Связки в порядке путей на телефоне.
  List<SyncLink> get _links => _sync.links?.all() ?? const <SyncLink>[];

  /// Добавить связку: сначала папка на устройстве, потом папка в облаке.
  ///
  /// Порядок именно такой: папку телефона видно всегда, а облачную выбирают в дереве сервера,
  /// и человеку проще сначала назвать свою сторону. Отказ на любом шаге — просто выход,
  /// ничего не записывается.
  ///
  /// Побочные эффекты: два вложенных экрана, запись связки в настройки, перестановка
  /// наблюдения за папками и запуск прохода зеркала (см. [SyncController.onLinksChanged]).
  Future<void> _add() async {
    // Клиент сессии берётся у состояния приложения: по нему читается дерево папок облака.
    // Сессия к этому экрану уже есть — настройки открываются только внутри аккаунта
    final api = ref.read(appStateProvider).api;
    // Связки живут в настройках синхронизатора: пока он не поднялся (не открылись настройки),
    // записывать их некуда, и об этом честнее сказать, чем упасть на пустом хранилище
    final store = _sync.links;
    if (store == null) {
      setState(() => _error = 'синхронизация ещё не готова — попробуйте через минуту');
      return;
    }
    final localPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const FolderTreeScreen.pick()),
    );
    if (!mounted || localPath == null) return;

    final links = _links;
    // Занятые папки облака подсвечиваем в выборе, а «Фото» не показываем вовсе: её содержимое
    // ведёт раздел «Фото», и связка залила бы туда вторую копию
    final photoId = ref.read(appStateProvider).user?.photoFolderId;
    final picked = await Navigator.of(context).push<({String id, String path})>(
      MaterialPageRoute(
        builder: (_) => CloudFolderPickerScreen(
          api: api,
          hiddenIds: {?photoId},
          takenIds: {for (final l in links) l.cloudId},
        ),
      ),
    );
    if (!mounted || picked == null) return;

    final candidate = SyncLink(
      localPath: localPath,
      cloudId: picked.id,
      cloudPath: picked.path.isEmpty ? 'корень облака' : picked.path,
    );
    // Связку проверяем до записи: пара «одна папка облака на две папки телефона» или две
    // вложенные связки сломали бы зеркало, а не просто выглядели бы странно
    final conflict = SyncLinkRules.conflict(links, candidate);
    if (conflict != null) {
      setState(() => _error = conflict);
      return;
    }
    await _save(() => store.put(candidate));
  }

  /// Убрать связку. В облаке не удаляется ничего: это только прекращение синхронизации.
  Future<void> _remove(SyncLink link) async {
    final store = _sync.links;
    if (store == null) return;
    await _save(() => store.remove(link.localPath));
  }

  /// Записать правку связок и переставить работу синхронизации.
  ///
  /// [change] — что записать в настройки. Побочные эффекты: запись настроек, наблюдение
  /// за папками, возможно проход зеркала и перерисовка экрана.
  Future<void> _save(Future<void> Function() change) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await change();
      await _sync.onLinksChanged();
    } catch (e) {
      if (mounted) setState(() => _error = 'связки не сохранены: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // подписка на контроллер: список связок меняется и с других экранов (удаление здесь же,
    // создание в диалоге добавления), и рисовать его по устаревшему снимку нельзя
    ref.watch(syncControllerProvider);
    final links = _links;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Папки для файлов',
              style: TextStyle(color: C.fg, fontSize: 17),
            ),
            Text(
              links.isEmpty ? 'связок нет' : 'связок: ${links.length}',
              style: const TextStyle(color: C.fg3, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => unawaited(_add()),
            child: const Text('Добавить'),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Text(
              'Связка — это пара папок: папка на устройстве и папка в облаке. Их содержимое '
              'совпадает в обе стороны. Папки выбираются из существующих: новых в облаке '
              'не заводится.',
              style: TextStyle(color: C.fg3, fontSize: 11),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(
                _error!,
                style: const TextStyle(color: C.danger, fontSize: 12),
              ),
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: links.isEmpty ? _empty() : _list(links),
          ),
        ],
      ),
    );
  }

  /// Список связок: папка на телефоне, под ней папка в облаке.
  Widget _list(List<SyncLink> links) {
    return ListView.builder(
      itemCount: links.length,
      itemBuilder: (context, i) {
        final link = links[i];
        return ListTile(
          leading: const Icon(Icons.sync_alt, color: C.accent),
          title: Text(
            link.localPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.fg, fontSize: 14),
          ),
          subtitle: Text(
            link.cloudPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.fg3, fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: 'Убрать связку (в облаке ничего не удаляется)',
            icon: const Icon(Icons.close, color: C.fg3),
            onPressed: _busy ? null : () => unawaited(_remove(link)),
          ),
        );
      },
    );
  }

  /// Пустой список: объясняем, что будет после первой связки — иначе экран читается как
  /// «синхронизация сломана».
  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Связок нет',
              style: TextStyle(color: C.fg, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Пока связки нет, раздел «Файлы» не синхронизируется: выбирать нечего. '
              'Добавьте связку — и содержимое папки устройства поедет в выбранную папку облака.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.fg3, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_add()),
              child: const Text('Добавить связку'),
            ),
          ],
        ),
      ),
    );
  }
}
