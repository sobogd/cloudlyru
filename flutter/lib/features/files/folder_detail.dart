import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../providers.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Чем закончилось открытие «Инфо о папке» — для экрана, который её открыл.
///
/// `null` в ответе `Navigator.pop` означает «ничего не менялось»: перечитывать уровень
/// незачем. [deleted] — папки в дереве больше нет, и шаг стека снимается; иначе в [name]
/// лежит имя после переименования — его и показывают заголовок и хлебные крошки «Файлов».
/// Одного флага «что-то изменилось» здесь мало: по нему нельзя понять, оставлять ли шаг стека.
typedef FolderMetaResult = ({bool deleted, String name});

/// Экран «Инфо о папке»: имя, путь, счётчики вложенного и даты.
///
/// Данные — одноразовый запрос `folderMeta`, снимок на момент открытия: экран не следит
/// за изменениями и не кэширует, поэтому перечитывает метаданные сам после каждой операции.
/// Здесь же три действия над папкой: переименовать, «вырезать» (папка уходит в буфер обмена
/// сервера, вставка — на экране «Файлы») и удалить в корзину.
///
/// Возврат вызывающему: [FolderMetaResult] — папку изменили или удалили, значит «Файлы»
/// должны перечитать уровень (и, если папки больше нет, снять шаг стека).
class FolderDetailScreen extends ConsumerStatefulWidget {
  final String folderId;
  const FolderDetailScreen({super.key, required this.folderId});

  @override
  ConsumerState<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

/// Состояние деталки: снимок метаданных и сообщения о последней операции.
class _FolderDetailScreenState extends ConsumerState<FolderDetailScreen> {
  /// Метаданные папки. `null` — либо ещё не загружены, либо не загрузились (тогда есть `_error`).
  FolderMeta? _meta;
  /// Ошибка загрузки или операции.
  String? _error;
  /// Подтверждение удачной операции: другого канала сообщений (тостов) на этом экране нет,
  /// поэтому строка «Имя изменено» живёт прямо в списке.
  String? _notice;
  /// Что случилось с папкой за время, пока экран открыт. `null` — ничего; иначе это ответ
  /// вызывающему, который вернётся при выходе (в том числе системным «назад», см. `PopScope`
  /// в `build`). Без этого переименование не доезжало до списка: экран закрывался без ответа,
  /// и «Файлы» показывали старое имя.
  FolderMetaResult? _changed;
  /// Идёт операция (переименование, вырезание, удаление): пока она в полёте, кнопки выключены,
  /// иначе второе нажатие отправило бы тот же запрос ещё раз.
  bool _busy = false;

  @override
  /// Открытие деталки: сразу читаем метаданные папки.
  void initState() {
    super.initState();
    _load();
  }

  /// Читает метаданные папки с сервера.
  ///
  /// Побочно: перерисовка. При ошибке уже загруженные метаданные остаются на экране — так
  /// неудачная перечитка после переименования не превращает форму в пустую страницу.
  Future<void> _load() async {
    try {
      final m = await ref.read(appStateProvider).api.folderMeta(widget.folderId);
      if (mounted) {
        setState(() {
          _meta = m;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  /// Переименовывает папку, запросив новое имя диалогом.
  ///
  /// Пустое имя или то же самое — выход без запроса к серверу. Побочно: `_notice` и перечитка
  /// метаданных (имя в заголовке берётся из `_meta`, локально его не подставляем), а также
  /// `_changed`: вызывающий экран по возвращении покажет новое имя в заголовке и крошках.
  /// Пока запрос в полёте, кнопка выключена — второе нажатие переименовало бы папку дважды.
  Future<void> _rename() async {
    if (_busy) return;
    final m = _meta;
    if (m == null) return;
    final next = await promptDialog(context, 'Новое имя папки', initial: m.name);
    if (next == null || next.trim().isEmpty || next == m.name) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.renameFolder(m.id, next.trim());
      if (!mounted) return;
      setState(() {
        _notice = 'Имя изменено';
        _changed = (deleted: false, name: next.trim());
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Кладёт папку в буфер обмена сервера в режиме переноса.
  ///
  /// Сама папка тут не меняется — только поле буфера у пользователя, поэтому и возвращать
  /// вызывающему нечего: дальше пользователь открывает нужный уровень в «Файлах» и жмёт
  /// «Вставить». Подсказка объясняет именно этот шаг, потому что иначе кнопка выглядит
  /// как «ничего не произошло».
  Future<void> _cut() async {
    if (_busy) return;
    final m = _meta;
    if (m == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(appStateProvider).api.setClipboard('folder', m.id, 'cut');
      if (mounted) snack(context, 'Папка вырезана. Откройте нужную папку и нажмите «Вставить».');
    } catch (e) {
      if (mounted) snack(context, _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Удаляет папку вместе с содержимым — сервер отправляет её в корзину, откуда её можно
  /// вернуть (раздел «Корзина»).
  ///
  /// Отмена в диалоге — выход без запроса. После успеха экран закрывается с
  /// `(deleted: true, …)`: папки в дереве больше нет, и «Файлы» по этому ответу перечитают
  /// уровень и снимут шаг стека.
  Future<void> _delete() async {
    if (_busy) return;
    final m = _meta;
    if (m == null) return;
    setState(() => _busy = true);
    final ok = await confirmDialog(context, 'Удалить папку «${m.name}»?', 'Папка с содержимым уйдёт в корзину.', danger: true);
    if (!ok) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      await ref.read(appStateProvider).api.deleteFolder(m.id);
      if (mounted) Navigator.pop(context, (deleted: true, name: m.name));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _errText(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    return PopScope(
      // Пока папка не менялась, маршрут закрывается как обычно — в том числе свайпом на iOS,
      // которому `canPop: false` запретил бы жест. После переименования выход перехватывается:
      // системный «назад» на Android иначе закрыл бы маршрут без ответа, и «Файлы» показывали
      // бы старое имя в заголовке и хлебных крошках.
      canPop: _changed == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back, color: C.fg), onPressed: () => Navigator.pop(context, _changed)),
          title: Text(m?.name ?? 'Папка', style: const TextStyle(color: C.fg, fontSize: 16)),
          actions: [
            IconButton(tooltip: 'Переименовать', icon: const Icon(Icons.edit_outlined, color: C.fg), onPressed: _busy ? null : _rename),
            IconButton(tooltip: 'Вырезать', icon: const Icon(Icons.content_cut, color: C.fg), onPressed: _busy ? null : _cut),
            IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline, color: C.danger), onPressed: _busy ? null : _delete),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
            if (_notice != null) Text(_notice!, style: const TextStyle(color: C.ok)),
            if (m == null && _error == null)
              // Спиннер только пока ответа нет.
              const Center(child: CircularProgressIndicator())
            else if (m == null)
              // Ответа нет и не будет: кроме ошибки строкой выше, сказать нечего, но выход
              // из тупика нужен — иначе остаётся только закрыть экран.
              Center(
                child: TextButton(onPressed: _load, child: const Text('Повторить')),
              )
            else
              Panel(child: Column(children: [
                MetaRow('Имя', m.name),
                MetaRow('Расположение', m.path),
                MetaRow('Вложенные папки', '${m.folders}'),
                MetaRow('Файлы', '${m.entries}'),
                // Даты приходят ISO-строкой: fmtLocal может её не разобрать, и тогда показываем
                // исходную строку — прятать дату из-за формата хуже, чем показать её как есть.
                if (m.createdAt != null) MetaRow('Создана', fmtLocal(m.createdAt) ?? m.createdAt!),
                if (m.updatedAt != null) MetaRow('Изменена', fmtLocal(m.updatedAt) ?? m.updatedAt!),
              ])),
          ],
        ),
      ),
    );
  }
}

/// Текст ошибки для человека.
///
/// [ApiException] уже несёт готовое сообщение: серверный текст или разбор сетевого сбоя
/// (см. `CloudlyApi._toException`), поэтому его `toString` и есть то, что нужно показать.
/// Всё остальное — ошибка разбора или наш баг, и её сырой `toString` (с типом исключения)
/// человеку ничего не объясняет: показываем общую формулировку.
String _errText(Object e) =>
    e is ApiException ? e.message : 'не удалось выполнить операцию';
