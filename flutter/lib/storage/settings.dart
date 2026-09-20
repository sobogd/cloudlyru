import 'package:shared_preferences/shared_preferences.dart';

import 'ui_state.dart';

/// Настройки приложения: адрес сервера и cookie веб-сессии.
///
/// Лежат в SharedPreferences — без нативных Keystore-плагинов, чтобы старт не мог упасть на
/// инициализации хранилища. Пароль не хранится нигде: после входа остаётся только cookie,
/// которую сервер может отозвать. Через [ui] те же prefs отдаются хранилищу UI-состояния,
/// чтобы на диске был один файл настроек, а не два.
///
/// Принятый риск: cookie сессии лежит в обычном XML в приватном каталоге приложения, то есть
/// читается на рутованном устройстве и попадает в бэкапы, а это полный доступ к облаку.
/// Осознанный обмен: Keystore-плагин усложнил бы старт (и однажды уже ронял приложение), а
/// сессию сервер может отозвать. Если понадобится убрать риск — cookie переезжает в
/// `flutter_secure_storage` лениво, уже после первого кадра, а не на старте.
class Settings {
  // Ключи — часть формата на диске: переименование потеряет у уже установленных приложений
  // и адрес сервера, и сессию.
  static const _kServer = 'server_url';
  static const _kSession = 'cloudly_session';
  static const _kAgentUrl = 'pi_bridge_url';
  static const _kAgentToken = 'pi_bridge_token';
  static const _kAgentCfId = 'pi_bridge_cf_id';
  static const _kAgentCfSecret = 'pi_bridge_cf_secret';

  /// Адрес прода по умолчанию: на первом запуске человек не должен вводить его руками,
  /// а свой сервер он вписывает на экране входа (`LoginScreen`, поле «Адрес сервера»).
  static const _kDefaultServer = 'https://files.iq-factura.com';

  /// Адрес моста до харнесса pi (раздел «Проекты»).
  ///
  /// Тот же по умолчанию, что и адрес сервера: на первом запуске раздел должен работать без
  /// настройки, а поле ввода нужно только тому, кто поднял мост на другом домене.
  static const _kDefaultAgentUrl = 'https://pi.iq-factura.com';

  final SharedPreferences _prefs;

  /// Только через [load]: нужен уже открытый экземпляр SharedPreferences, а не путь к нему.
  Settings._(this._prefs);

  /// Открывает SharedPreferences и отдаёт готовые настройки.
  ///
  /// Асинхронный, потому что чтение с диска: вызывающий (старт приложения) обязан дождаться
  /// его до первого обращения к [serverUrl].
  ///
  /// `SharedPreferences.getInstance()` — прежний API (не `SharedPreferencesAsync`), и выбран он
  /// намеренно: он отдаёт один общий на процесс кэш значений, поэтому синхронизатор
  /// (`SyncController.start` открывает свои настройки так же) и это хранилище работают с одним
  /// и тем же состоянием, а не с двумя копиями одного файла.
  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Settings._(prefs);
  }

  /// Адрес сервера для API; при пустом или не заполненном значении — прод по умолчанию.
  ///
  /// Пробелы по краям срезаем: адрес часто вставляют копированием, а лишний пробел в baseUrl
  /// делает URL неразбираемым.
  String get serverUrl {
    final v = _prefs.getString(_kServer);
    return (v == null || v.trim().isEmpty) ? _kDefaultServer : v.trim();
  }

  /// Запоминает адрес сервера (тоже без пробелов по краям).
  ///
  /// Сам по себе адрес ничего не переключает: уже созданный клиент API держит baseUrl в себе.
  /// Менять адрес нужно через `AppState.useServer`: он сохраняет значение здесь и пересоздаёт
  /// клиент — иначе запросы ушли бы на старый адрес, а ссылки на файлы и превью — на новый.
  Future<void> setServerUrl(String url) => _prefs.setString(_kServer, url.trim());

  /// Cookie веб-сессии (`cl_session=…`) или `null`, если вход не выполнялся.
  String? get session => _prefs.getString(_kSession);

  /// Сохраняет cookie после успешного входа — им приложение ходит в ручки, закрытые для
  /// device-токена.
  Future<void> setSession(String s) => _prefs.setString(_kSession, s);

  /// Стирает cookie (выход из аккаунта). Адрес сервера остаётся: выход не должен заставлять
  /// вводить его заново.
  Future<void> clearSession() => _prefs.remove(_kSession);

  /// Адрес моста до харнесса pi (раздел «Проекты»); пустое значение — адрес по умолчанию.
  String get agentUrl {
    final v = _prefs.getString(_kAgentUrl);
    return (v == null || v.trim().isEmpty) ? _kDefaultAgentUrl : v.trim();
  }

  /// Запоминает адрес моста (пробелы по краям срезаем — адрес часто вставляют копированием).
  Future<void> setAgentUrl(String url) => _prefs.setString(_kAgentUrl, url.trim());

  /// Токен моста из `~/.pi-bridge.json` на маке.
  ///
  /// Лежит рядом с cookie сессии и с тем же принятым риском (см. описание класса): на
  /// рутованном устройстве он читается, а с ним открыт агент с правом писать файлы и запускать
  /// команды на маке. Отзыв — смена токена в файле настроек моста: приложение сразу получает
  /// 401 и раздел перестаёт работать, пока новый токен не вписан.
  String get agentToken => _prefs.getString(_kAgentToken)?.trim() ?? '';

  /// Запоминает токен моста.
  Future<void> setAgentToken(String token) => _prefs.setString(_kAgentToken, token.trim());

  /// Пара Cloudflare Access: идентификатор клиента service token.
  ///
  /// Нужна потому, что адрес моста опубликован в интернет, и закрывает его именно Access —
  /// до того, как запрос дойдёт до мака. Пустые значения означают «Access настроен иначе»
  /// (например, по почте владельца): тогда заголовки просто не отправляются.
  String get agentCfId => _prefs.getString(_kAgentCfId)?.trim() ?? '';

  /// Секрет того же service token (вторая половина пары).
  String get agentCfSecret => _prefs.getString(_kAgentCfSecret)?.trim() ?? '';

  /// Сохраняет пару Cloudflare Access.
  Future<void> setAgentCf(String id, String secret) async {
    await _prefs.setString(_kAgentCfId, id.trim());
    await _prefs.setString(_kAgentCfSecret, secret.trim());
  }

  /// Хранилище UI-состояния поверх тех же prefs (выбранная вкладка и прочая мелочь).
  UiStateStore get ui => UiStateStore(_prefs);
}
