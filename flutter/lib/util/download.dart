import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/cloudly_api.dart';

/// Скачивает файл во временную папку приложения и открывает системным обработчиком.
Future<void> downloadAndOpen(CloudlyApi api, String entryId, String name) async {
  final dir = await getTemporaryDirectory();
  final safe = name.replaceAll(RegExp(r'[/\\]'), '_');
  final path = '${dir.path}/$safe';
  final dio = Dio();
  await dio.download(
    api.fileUrl(entryId),
    path,
    options: Options(headers: api.authHeaders),
  );
  await OpenFilex.open(path);
}
