import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../api/cloudly_api.dart';
import 'sync_api.dart';

/// Device-токен: им синхронизатор ходит в облако.
class DeviceToken {
  const DeviceToken({required this.token, this.id, this.label = ''});

  final String token;
  final String? id;
  final String label;
}

/// Хранилище device-токена. Токен даёт полный доступ к облаку, а телефон — потеряемая вещь,
/// поэтому лежит он в шифрованном хранилище системы, а не в обычных настройках.
///
/// Ключ включает адрес сервера и логин: корень зеркала сервер заводит **устройству**, то есть
/// токену, и подмена токена на чужой означала бы выгрузку в папку другого аккаунта.
class DeviceTokenStore {
  DeviceTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<DeviceToken?> read(String serverUrl, String login) async {
    final raw = await _storage.read(key: _key(serverUrl, login));
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = json.decode(raw) as Map<String, dynamic>;
      final token = '${j['token'] ?? ''}';
      if (token.isEmpty) return null;
      return DeviceToken(
        token: token,
        id: j['id'] == null ? null : '${j['id']}',
        label: '${j['label'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String serverUrl, String login, DeviceToken token) => _storage.write(
        key: _key(serverUrl, login),
        value: json.encode({'token': token.token, 'id': token.id, 'label': token.label}),
      );

  Future<void> clear(String serverUrl, String login) =>
      _storage.delete(key: _key(serverUrl, login));

  String _key(String serverUrl, String login) => 'device_token|$serverUrl|$login';
}

/// Токен устройства для синхронизации: свой у каждого устройства, чтобы корень зеркала в
/// облаке не делился между телефонами (иначе удаление на одном уносило бы файлы другого).
///
/// Хранимый токен переиспользуется: новый токен — это новый корень зеркала, и после каждого
/// входа-выхода облако получало бы ещё одну папку с тем же содержимым. Новый заводится,
/// только если прежний отозван или его нет.
Future<DeviceToken> ensureDeviceToken({
  required CloudlyApi session,
  required DeviceTokenStore store,
  required String serverUrl,
  required String login,
  required String label,
}) async {
  final saved = await store.read(serverUrl, login);
  if (saved != null) {
    final alive = await _isAlive(saved.token, serverUrl);
    if (alive) return saved;
  }
  final created = await session.createToken(label);
  final token = DeviceToken(
    token: '${created['token'] ?? ''}',
    id: created['id'] == null ? null : '${created['id']}',
    label: '${created['label'] ?? label}',
  );
  if (token.token.isEmpty) throw StateError('сервер не выдал токен устройства');
  await store.write(serverUrl, login, token);
  return token;
}

/// Живой ли токен: сервер отвечает отказом на отозванный, и тогда нужен новый.
Future<bool> _isAlive(String token, String serverUrl) async {
  try {
    await SyncApi(serverUrl: serverUrl, token: token).meInfo();
    return true;
  } catch (e) {
    // 401/403 — токен мёртв; сеть может просто молчать, и тогда токен не виноват
    if (e is SyncApiException) return e.status != 401 && e.status != 403;
    return true;
  }
}
