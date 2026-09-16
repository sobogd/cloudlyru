import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Расширения, по которым корзина узнаёт тип записи.
///
/// `TrashItem` не несёт mime — сервер отдаёт его только в листинге папки, — а имя есть всегда,
/// поэтому единственный доступный признак типа это расширение. Таблица нужна лишь для выбора
/// значка, и она намеренно короткая: то, что человек реально видит в корзине. Незнакомое
/// расширение даёт общий значок файла — неверная иконка хуже нейтральной.
const _mimeByExt = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'bmp': 'image/bmp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  'aac': 'audio/aac',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'rar': 'application/x-rar-compressed',
  '7z': 'application/x-7z-compressed',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
};

/// Экран «Корзина»: всё, что удалено, — папки и файлы одним списком.
///
/// Данные — один запрос `trash`, снимок на момент открытия: список перечитывается самим
/// экраном после восстановления или очистки, а удалённое с другого устройства появится
/// только при следующем открытии вкладки. Восстановление и очистка — операции сервера,
/// клиент лишь показывает результат; файлы и папки отличаются иконкой (по расширению имени,
/// см. [_mimeByExt]) и размером.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

/// Состояние корзины: снимок содержимого, ошибка загрузки и признак «операция в полёте».
class _TrashScreenState extends ConsumerState<TrashScreen> {
  /// Содержимое корзины; `null` — ответа ещё не было (показывается спиннер).
  TrashView? _view;
  String? _error;
  /// Идёт операция (восстановление, очистка): пока она в полёте, кнопки выключены. Без этого
  /// двойное нажатие «Очистить корзину» отправило бы два необратимых запроса, а второе
  /// «восстановить» — вернуло бы запись, которой в корзине уже нет.
  bool _busy = false;

  @override
  /// Открытие корзины: сразу читаем её содержимое.
  void initState() {
    super.initState();
    _load();
  }

  /// Читает содержимое корзины.
  ///
  /// Побочно: перерисовка; ошибка идёт в `_error` и заменяет собой список — в корзине
  /// показывать наполовину устаревший список опаснее, чем сказать, что он не загрузился.
  Future<void> _load() async {
    try {
      final v = await ref.read(appStateProvider).api.trash();
      if (mounted) {
        setState(() {
          _view = v;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Возвращает запись из корзины на её прежнее место.
  ///
  /// `kind` — что восстанавливаем, `folder` или файл: сервер хранит их в разных таблицах,
  /// и одним запросом это не выражается. Побочно: перечитка корзины — восстановленного
  /// в списке быть уже не должно. Ошибку показываем подсказкой, список не трогая.
  Future<void> _restore(String kind, String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.restoreItem(kind, id);
      await _load();
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Очищает корзину целиком — безвозвратно, включая собранные превью.
  ///
  /// Диалог предупреждает именно об этом: отдельная запись удаляется с экрана файла и уходит
  /// в корзину, а здесь её уже не вернуть. Отмена — выход без запроса и без снятия `_busy`.
  /// Кнопка подписана «Очистить», а не «ОК»: действие необратимое, и подпись должна называть
  /// его прямо. Побочно: перечитка списка, чтобы пустая корзина сразу показалась пустой.
  Future<void> _purge() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await confirmDialog(
      context,
      'Очистить корзину?',
      'Удалённые файлы и превью будут стёрты безвозвратно.',
      danger: true,
      confirmLabel: 'Очистить',
    );
    if (!ok) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      await ref.read(appStateProvider).api.purgeTrash();
      await _load();
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Иконка записи: папка — папка, файл — значок по типу из расширения имени.
  ///
  /// Раньше здесь стоял `fileIcon(null)` для всего, что не папка, и все файлы в корзине
  /// выглядели одинаково серыми: по списку нельзя было понять, что именно удалено.
  IconData _icon(TrashItem t) {
    if (t.kind == 'folder') return Icons.folder_outlined;
    return fileIcon(_mimeByName(t.name));
  }

  /// Mime по расширению имени — только чтобы выбрать значок (см. [_mimeByExt]).
  ///
  /// Имя приходит с сервера, то есть может быть любым: точки в начале нет, расширение пустое
  /// или имя целиком — всё это даёт `null`, а `null` в [fileIcon] означает общий значок.
  String? _mimeByName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return _mimeByExt[name.substring(dot + 1).toLowerCase()];
  }

  /// Подпись строки: размер и дата удаления, каждая часть — если сервер её дал.
  ///
  /// Размер есть только у файлов (у папок сервер его не считает), дата может не разобраться
  /// как ISO-строка — тогда показываем её как есть, но не прячем. Пустые части пропускаем:
  /// голая точка-разделитель читалась бы как сбой.
  String _subtitle(TrashItem t) {
    final date = t.deletedAt == null ? null : (fmtLocal(t.deletedAt) ?? t.deletedAt);
    return [
      if (t.kind != 'folder' && t.size != null) fmt(t.size!),
      if (date != null && date.isNotEmpty) date,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    // Папки и файлы показываются одним списком: в корзине важно «что удалено и когда»,
    // а не иерархия — восстанавливается запись всё равно на своё прежнее место.
    final items = <TrashItem>[
      ...(_view?.folders ?? const <TrashItem>[]),
      ...(_view?.entries ?? const <TrashItem>[]),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Корзина', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Очистить корзину',
            onPressed: (items.isEmpty || _busy) ? null : _purge,
            icon: const Icon(Icons.delete_sweep_outlined, color: C.danger),
          ),
        ],
      ),
      body: _error != null
          ? _refreshable(
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: C.danger),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _load, child: const Text('Повторить')),
                  ],
                ),
              ),
            )
          : _view == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? _refreshable(
                      const Center(
                        child: Text('Корзина пуста', style: TextStyle(color: C.fg3)),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        // Список бывает короче экрана, а обновление жестом должно работать и там.
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final t = items[i];
                          final sub = _subtitle(t);
                          return ListTile(
                            leading: Icon(_icon(t), color: C.fg3),
                            title: Text(t.name, style: const TextStyle(color: C.fg)),
                            subtitle: sub.isEmpty
                                ? null
                                : Text(
                                    sub,
                                    style: const TextStyle(color: C.fg3, fontSize: 12),
                                  ),
                            trailing: TextButton(
                              onPressed: _busy ? null : () => _restore(t.kind, t.id),
                              child: const Text('восстановить'),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }

  /// Обёртка «потянуть вниз, чтобы обновить» для содержимого, которое не занимает экран:
  /// пустая корзина и состояние ошибки — как раз те случаи, когда обновление нужнее всего,
  /// а обычный [RefreshIndicator] на невысоком содержимом жест не поймает.
  Widget _refreshable(Widget child) => RefreshIndicator(
    onRefresh: _load,
    child: LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: child,
        ),
      ),
    ),
  );
}

/// Текст ошибки для человека.
///
/// [ApiException] уже несёт готовое сообщение: серверный текст или разбор сетевого сбоя
/// (см. `CloudlyApi._toException`), поэтому его `toString` и есть то, что нужно показать.
/// Всё остальное — ошибка разбора или наш баг, и её сырой `toString` (с типом исключения)
/// человеку ничего не объясняет: показываем общую формулировку.
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось выполнить операцию';
