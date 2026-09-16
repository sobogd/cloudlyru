import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';

/// Миниатюра квадратом: с диска, если она уже скачана, иначе — заглушка и загрузка в очередь.
///
/// Заменяет `CachedNetworkImage` там, где миниатюры копятся в данных приложения
/// (`ThumbCache`), а не в кэш-каталоге: картинка хранится файлом по sha256, поэтому её можно
/// показать без сети, а размер кэша виден и управляем в настройках.
///
/// Почему не `Image.file` напрямую: файла на первом показе ещё нет, и виджет должен сам
/// попросить его у очереди, а по готовности перерисоваться. Ожидание общее для всех плиток
/// с тем же содержимым — очередь дедуплицирует запросы по sha256.
class ThumbImage extends ConsumerStatefulWidget {
  const ThumbImage({
    super.key,
    required this.sha,
    required this.size,
    this.radius = 8,
    this.fallback,
    this.background = false,
  });

  /// Хэш содержимого: и имя файла в хранилище, и адрес миниатюры на сервере.
  final String sha;

  /// Сторона квадрата в логических пикселях.
  final double size;

  /// Скругление углов.
  final double radius;

  /// Что показывать, пока миниатюры нет (обычно иконка типа файла). По умолчанию — серая
  /// плашка: пустое место в списке читается как ошибка вёрстки, а плашка — как «картинки нет».
  final Widget? fallback;

  /// Просить миниатюру в фоне (уступая видимым кадрам). Ставит прогрев библиотеки: он идёт
  /// сотнями тысяч кадров и не должен задерживать то, что человек листает сейчас.
  final bool background;

  @override
  ConsumerState<ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends ConsumerState<ThumbImage> {
  /// Ближайший кадр плитка уже просила миниатюру: повторные просьбы не нужны (очередь и так
  /// дедуплицирует), а вот запомнить факт полезно — иначе каждый `build` слал бы запрос заново.
  bool _requested = false;

  @override
  /// Просьба о миниатюре — после первого кадра, а не в `build`: запрос трогает провайдеры
  /// и очередь, а `build` обязан оставаться чистым.
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  /// Попросить миниатюру у очереди и перерисоваться, когда она появится.
  ///
  /// Если хранилище ещё открывается (первый кадр после запуска), просьба повторяется через
  /// мгновение: открытие асинхронное (чтение каталога на диске), а плитка не должна из-за
  /// этого остаться без картинки до следующего скролла.
  void _request() {
    if (!mounted || _requested) return;
    final cache = ref.read(thumbCacheProvider).value;
    if (cache == null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _request();
      });
      return;
    }
    _requested = true;
    unawaited(cache.request(widget.sha, background: widget.background).then((_) {
      if (mounted) setState(() {});
    }));
  }

  @override
  /// Файл с диска, если он есть; заглушка — если нет. Ошибку декодирования тоже показываем
  /// заглушкой: битый файл (например, недокачанный при падении процесса) не должен ронять
  /// список исключением.
  Widget build(BuildContext context) {
    final cache = ref.watch(thumbCacheProvider).value;
    final file = cache?.file(widget.sha);
    final miss = widget.fallback ?? Container(color: C.surface3);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: file == null
            ? miss
            : Image.file(
                file,
                fit: BoxFit.cover,
                // Кадр не мигает заглушкой при перерисовке списка и декодируется в размер
                // плитки, а не в размер файла: миниатюра 100×100 после кэша картинок Flutter
                // иначе занимала бы память под полный ARGB-квадрат.
                gaplessPlayback: true,
                cacheWidth: (widget.size * dpr).round(),
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => miss,
              ),
      ),
    );
  }
}
