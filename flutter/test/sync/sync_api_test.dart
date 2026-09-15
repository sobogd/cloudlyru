import 'package:cloudly_flutter/sync/net/sync_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Адрес сервера в клиенте синхронизации: ошибка здесь роняет всё разом — и выпуск токена,
/// и проход зеркала, — а видно её только на телефоне. Один такой случай уже был:
/// `$this.serverUrl` вместо `${this.serverUrl}` давал в baseUrl «Instance of 'SyncApi'…».
void main() {
  group('SyncApi', () {
    test('базовый адрес собирается из адреса сервера', () {
      final api = SyncApi(
        serverUrl: 'https://files.iq-factura.com',
        token: 't',
      );
      expect(api.baseUrl, 'https://files.iq-factura.com/api/v1');
    });

    test('хвостовые слэши не удваиваются', () {
      final api = SyncApi(
        serverUrl: 'https://files.iq-factura.com///',
        token: 't',
      );
      expect(api.baseUrl, 'https://files.iq-factura.com/api/v1');
      expect(api.serverUrl, 'https://files.iq-factura.com');
    });

    test('пробелы по краям адреса не мешают', () {
      final api = SyncApi(
        serverUrl: '  https://cloud.example.com  ',
        token: 't',
      );
      expect(api.baseUrl, 'https://cloud.example.com/api/v1');
    });

    test('пустой адрес — понятная ошибка, а не «странный URL»', () {
      // сервер ещё не настроен: лучше сказать это словами, чем показать текст Dio
      expect(
        () => SyncApi(serverUrl: '   ', token: 't'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'не задан адрес сервера',
          ),
        ),
      );
    });
  });
}
