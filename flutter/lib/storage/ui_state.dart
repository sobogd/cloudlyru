import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Мелкое UI-состояние, которое должно пережить перезапуск приложения: один ключ в
/// SharedPreferences, внутри — JSON-объект.
///
/// Кто чем пользуется:
/// - `tab` — имя выбранного раздела (`AppTab.name`): пишет оболочка при переключении вкладки
///   и читает при старте (`shell.dart`);
/// - `files.stack` — цепочка открытых папок: пишет и читает экран «Файлы» (`_saveStack` при
///   входе в папку, подъёме и возврате из «Инфо о папке»), поэтому позиция в файлах переживает
///   перезапуск приложения, а не только переключение вкладок. Прежний веб-клиент (каталог
///   `web/` удалён из репозитория коммитом 407a490) обещал то же самое; сверять с ним нечего —
///   здесь хранится ровно то, что записал кто-то из экранов;
/// - `agent_model_<харнесс>` — модель для новых сессий раздела «Проекты» (`local/qwen/qwen3.8-27b`
///   у pi, `claude/sonnet` у Claude Code). Выбор хранится отдельно по харнессу: у них разные
///   наборы моделей, и одна общая настройка означала бы «вчера выбрал Claude, сегодня pi
///   запустился не тем, чем я думал».
///
/// Читать значения нужно типизированными геттерами ([tab], [filesStack]): в prefs может
/// лежать что угодно — запись старой сборки, ручная правка, будущий формат, — и сырое значение
/// из [read] нельзя кастовать в `as String`/`as List`: исключение в `initState` означает
/// красный экран при входе в приложение.
class UiStateStore {
  // Ключи — часть формата на диске: переименование потеряет состояние у уже установленных
  // приложений (запись останется лежать под старым ключом). Имена без префикса-пространства
  // имён — та же схема, что у адреса сервера и сессии в `settings.dart`.
  static const _key = 'ui_state';
  // Прежний ключ с префиксом: читаем его только чтобы не потерять вкладку у тех, кто уже
  // поставил сборку со старым именем. Писать в него больше не нужно.
  static const _legacyKey = 'cloudlyru:ui';

  /// Показывать ли превью в сетке галереи (кнопка в шапке раздела).
  static const _kGalleryPreviews = 'gallery_previews';

  final SharedPreferences _prefs;

  /// [SharedPreferences] передаёт владелец настроек — своё хранилище здесь не открывается,
  /// чтобы не создавать второй экземпляр на то же место.
  UiStateStore(this._prefs);

  /// Отдаёт сохранённый объект состояния; пустой объект — если ничего не сохранено или
  /// запись повреждена.
  ///
  /// Значение сырое: типы полей не проверяются, поэтому кастовать его напрямую нельзя (см.
  /// [tab] и [filesStack]). Битый JSON и не-объект в значении молча превращаются в пустую
  /// карту: настройка не тот случай, ради которого стоит показывать человеку ошибку при запуске.
  Map<String, dynamic> read() {
    for (final key in [_key, _legacyKey]) {
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final v = json.decode(raw);
        if (v is Map) return v.cast<String, dynamic>();
      } catch (_) {
        // повреждённая запись — то же, что её отсутствие
      }
    }
    return {};
  }

  /// Выбранная вкладка приложения (`AppTab.name`) или `null`, если её нет или записано не то.
  ///
  /// Значение проверяется на тип: имя вкладки приходит из настроек, то есть с диска, а `as
  /// String` на числе или списке бросил бы исключение прямо в `initState` оболочки.
  String? get tab {
    final v = read()['tab'];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  /// Цепочка открытых папок: `[{'id': …, 'name': …}]` или `null`, если её нет или она битая.
  ///
  /// Каждый элемент проверяется по отдельности: одна испорченная запись не должна уносить
  /// с собой весь путь. Экран «Файлы» читает ключ сырым (`ui['files']?['stack'] as List?`)
  /// и пишет стек пока никто, поэтому ключ здесь только читается.
  List<({String? id, String name})>? get filesStack {
    final files = read()['files'];
    if (files is! Map) return null;
    final stack = files['stack'];
    if (stack is! List || stack.isEmpty) return null;
    return stack.whereType<Map>().map((e) {
      final id = e['id'];
      final name = e['name'];
      return (id: id is String ? id : null, name: name is String ? name : '');
    }).toList();
  }

  /// Показывать ли превью в сетке галереи. По умолчанию `true`: обычный режим раздела — это
  /// картинки, а «только значки» включают кнопкой в шапке галереи и выключают ею же.
  ///
  /// Значение проверяется на тип, как [tab]: в prefs может лежать что угодно, а `as bool`
  /// на строке уронил бы экран галереи прямо при открытии раздела.
  bool get galleryPreviews {
    final v = read()[_kGalleryPreviews];
    return v is bool ? v : true;
  }

  /// Запомнить выбор показа превью (см. [galleryPreviews]).
  Future<void> setGalleryPreviews(bool on) => patch({_kGalleryPreviews: on});

  /// Модель, выбранная для харнесса в разделе «Проекты» (`провайдер/модель`), либо `null`.
  ///
  /// Тип проверяем по той же причине, что и у вкладки: значение приходит с диска, а ключ, в
  /// котором вместо строки окажется что-то другое, уронил бы экран открытием сессии.
  String? agentModel(String harness) {
    final v = read()['agent_model_$harness'];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  /// Запоминает выбранную модель харнесса (см. [agentModel]).
  Future<void> setAgentModel(String harness, String key) =>
      patch({'agent_model_$harness': key});

  /// Уровень усилия, выбранный для харнесса в разделе «Проекты», либо пусто.
  ///
  /// Хранится отдельно от модели, потому что в файле разговора у Claude Code его нет: без этой
  /// памяти выбор терялся бы при перезапуске моста, и возобновлённая сессия считалась бы с
  /// умолчанием модели. Пусто — «пусть решает модель», и это значение по умолчанию.
  String agentEffort(String harness) {
    final v = read()['agent_effort_$harness'];
    return v is String ? v : '';
  }

  /// Запоминает выбранный уровень усилия (см. [agentEffort]).
  Future<void> setAgentEffort(String harness, String effort) =>
      patch({'agent_effort_$harness': effort});

  /// Ширина колонки со списком в раскладке «список — деталка» (`util/master_detail.dart`)
  /// или `null`, если её ещё не тянули.
  ///
  /// Ключ ([key]) — имя раздела: у списка разговоров и у списка настроек удобная ширина
  /// разная, поэтому общая настройка на всех подгоняла бы чужие разделы под один размер.
  /// Тип проверяем, как у [tab]: значение приходит с диска, а `as double` на строке уронил бы
  /// раздел прямо при открытии.
  double? splitWidth(String key) {
    final v = read()['split_width_$key'];
    return v is num ? v.toDouble() : null;
  }

  /// Запоминает ширину колонки со списком (см. [splitWidth]).
  Future<void> setSplitWidth(String key, double width) =>
      patch({'split_width_$key': width});

  /// Идентификатор разговора, заведённого для ревью пул-реквеста ([key] вида `repo#123`).
  ///
  /// Связь хранится по идентификатору, а не по имени разговора: имя переписывает сам харнесс
  /// (Claude Code ставит свой заголовок по первому вопросу), и поиск «разговор с таким именем»
  /// после первого же ответа переставал находить начатое ревью.
  String? reviewSession(String key) {
    final map = read()['review_sessions'];
    if (map is! Map) return null;
    final id = map[key];
    return (id is String && id.isNotEmpty) ? id : null;
  }

  /// Запоминает разговор ревью для пул-реквеста (см. [reviewSession]).
  Future<void> setReviewSession(String key, String sessionId) async {
    final map = _reviewSessions()..[key] = sessionId;
    await patch({'review_sessions': map});
  }

  /// Забывает разговор ревью: его удалили на маке или он потерялся.
  Future<void> forgetReviewSession(String key) async {
    final map = _reviewSessions();
    if (map.remove(key) == null) return;
    await patch({'review_sessions': map});
  }

  /// Текущая карта «пул-реквест → разговор»; мусор в записи считается пустой картой.
  Map<String, dynamic> _reviewSessions() {
    final map = read()['review_sessions'];
    return map is Map ? map.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// Дописывает поля к сохранённому состоянию: читает текущий объект, накладывает [patch]
  /// и записывает обратно.
  ///
  /// Наложение поверхностное: значение по существующему ключу заменяется целиком, вложенные
  /// объекты не сливаются. Чтение-запись без блокировки, поэтому два одновременных вызова
  /// могут затереть результат друг друга — вызывающий код пишет сюда по одному полю за раз
  /// из действия человека. Возвращает `Future`, как `settings.setSession`: запись асинхронная,
  /// и вызывающий сам решает, ждать её или нет (ошибку записи никто не показывает — неудачная
  /// запись настройки не должна ломать текущий экран).
  Future<void> patch(Map<String, dynamic> patch) async {
    final cur = read();
    cur.addAll(patch);
    await _prefs.setString(_key, json.encode(cur));
    // старый ключ больше не нужен: его значение уже перенесено этим чтением
    await _prefs.remove(_legacyKey);
  }

  /// Стирает всё сохранённое UI-состояние разом: после него вкладка берётся по умолчанию.
  ///
  /// Вызывается при выходе из аккаунта: вкладка предыдущего пользователя не должна достаться
  /// следующему.
  Future<void> clear() async {
    await _prefs.remove(_key);
    await _prefs.remove(_legacyKey);
  }
}
