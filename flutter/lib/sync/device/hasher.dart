import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// SHA-256 файла. Им сервер отличает дубли содержимого, а зеркало — «то же самое» от
/// «изменилось»; читаем потоком, потому что файлы бывают на гигабайты.
abstract final class Hasher {
  static const int _bufferBytes = 1 << 20;

  static Future<String> sha256(File file) async {
    final sink = _DigestSink();
    final input = crypto.sha256.startChunkedConversion(sink);
    final raf = await file.open();
    try {
      while (true) {
        final chunk = await raf.read(_bufferBytes);
        if (chunk.isEmpty) break;
        input.add(chunk);
      }
    } finally {
      await raf.close();
      input.close();
    }
    return sink.digest?.toString() ?? '';
  }
}

/// Ловит итоговый [crypto.Digest] стримингового хеширования.
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) => digest = data;

  @override
  void close() {}
}
