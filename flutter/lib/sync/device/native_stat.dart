import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Ключ файла в файловой системе: том ([dev]) и номер файла внутри тома ([ino]).
///
/// Номер уникален **только внутри тома**: на внутренней памяти и на карте памяти легко
/// найдутся файлы с одним и тем же номером (каждый том нумерует свои), и сравнивать номера
/// без тома нельзя — копия файла, перенесённая на другой том, выглядела бы переименованием
/// и увезла бы облачную запись на чужой путь. Поэтому том и номер ходят вместе.
///
/// `ino == 0` — «номер неизвестен» (раскладка не сошлась, файла нет, нет прав): тогда
/// сравнение по ключу не делается вовсе, и остаются размер с датой.
///
/// Том — величина не вечная: у съёмного тома номер устройства меняется при каждом подключении,
/// поэтому совпадение тома требуется только для распознавания переименования, и его отсутствие
/// означает «сравнить нельзя», а не «файл изменился».
class FileId {
  const FileId(this.dev, this.ino);

  /// Идентификатор тома (`st_dev`).
  final int dev;

  /// Номер файла внутри тома (`st_ino`).
  final int ino;

  /// Ключа нет: сравнивать не с чем.
  static const FileId unknown = FileId(0, 0);

  /// Номер известен — по ключу можно сравнивать.
  bool get known => ino > 0;

  @override
  bool operator ==(Object other) =>
      other is FileId && other.dev == dev && other.ino == ino;

  @override
  int get hashCode => Object.hash(dev, ino);

  @override
  String toString() => known ? 'FileId($dev, $ino)' : 'FileId(неизвестен)';
}

/// Чтение номера файла (`st_ino`) через `stat(2)` — прямо из libc, без нативного кода проекта.
///
/// Зачем он нужен: Dart `FileStat` номера файла не отдаёт, а зеркалу он необходим, чтобы
/// отличать переименование от «удалил и залил заново» (`MirrorRules.changed`,
/// `MirrorRules.plan`). Раньше за этим ходили в Kotlin по `MethodChannel`; теперь тот же
/// системный вызов делается из Dart — ни моста, ни канала, ни нативной прослойки.
///
/// ## Раскладки `struct stat`
///
/// `stat` пишет всю структуру целиком, поэтому буфер обязан быть не меньше её размера, а
/// смещения — точными. Ошибка здесь даёт не исключение, а правдоподобное чужое число, и
/// переименования начинают складываться неправильно. Поэтому смещения не «по памяти»,
/// а сняты с заголовков:
///
/// | платформа | символ | `st_dev` | `st_ino` | `st_size` | `sizeof` |
/// |---|---|---|---|---|---|
/// | macOS (arm64 и x86_64) | `stat`, на x86_64 ещё `stat$INODE64` | 0 | 8 | 96 | 144 |
/// | Android, arm64 | `stat` | 0 | 8 | 48 | 128 |
/// | Android, x86_64 | `stat` | 0 | 8 | 48 | 144 |
/// | Android, arm 32 | `stat` | 0 | 96 | 48 | 104 |
///
/// Три андроидные раскладки сняты с NDK 28.2.13676358:
/// `clang --target=<abi>21 -Xclang -fdump-record-layouts` по `<sys/stat.h>`. На arm 32
/// 64-битный номер лежит не в начале, а в самом конце структуры, рядом с устаревшим
/// 32-битным `__st_ino`: прочитать не то поле — значит выдать двум разным файлам один номер.
/// Раскладка macOS снята с `<sys/stat.h>` этого мака (`sizeof`, `offsetof`).
///
/// ## Самопроверка
///
/// Сборкой раскладку не проверить, поэтому она проверяется дважды. Сначала объявление
/// сверяется по размеру структуры (`sizeOf` должен дать 128/144/104 — размер из заголовка):
/// разошлось — раскладка не берётся вовсе. Потом, первым же вызовом, размер файла из `stat`
/// сверяется с [File.lengthSync] — два независимых источника об одном и том же файле.
/// Не сошлось — [id] и [ids] навсегда отвечают [FileId.unknown], и приложение работает как без
/// номеров: переименование не распознаётся и файл уедет заново. Это дороже, но не потеря
/// данных, и это единственный безопасный ответ, если раскладка не та.
///
/// Том читается из той же структуры и по той же причине: без него номер файла с одной карты
/// памяти совпал бы с номером чужого файла на другой, и копия выглядела бы переименованием.
class NativeStat {
  NativeStat._(this._layout);

  /// Раскладка текущей платформы; [ _NoLayout] — FFI недоступен, номера не будет.
  final _Layout _layout;

  static NativeStat? _instance;

  /// Экземпляр на изолят: разбор символа, выбор раскладки и буфер делаются один раз.
  ///
  /// Отдельный экземпляр на изолят — не роскошь: у каждого изолята своя таблица символов
  /// и своя память, делиться ими между изолятами нельзя.
  static NativeStat get instance => _instance ??= _open();

  /// Раскладка уже сошлась (`true`), не сошлась (`false`) или ещё не проверялась (`null`).
  ///
  /// Проверка делается один раз на процесс и только на настоящем файле: у каталога размеры
  /// из двух источников расходятся законно, и судить по нему о раскладке нельзя.
  bool? _layoutOk;

  /// Вердикт самопроверки: `null` — ещё не проверялась. Нужен для логов.
  bool? get layoutOk => _layoutOk;

  /// Ключ файла (том и номер в нём); [FileId.unknown] — «узнать не удалось».
  ///
  /// Пустой ключ вместо исключения — сознательный контракт: сбой `stat` (файла нет, нет прав,
  /// раскладка не сошлась) не должен ронять обход. Все вызывающие уже трактуют такой ключ как
  /// «сравнивать не с чем» и деградируют до сравнения по размеру и дате.
  FileId id(String path) {
    if (_layoutOk == false) return FileId.unknown;
    final pathPtr = path.toNativeUtf8();
    try {
      final read = _layout.read(pathPtr);
      if (read == null) return FileId.unknown;
      if (!_verify(path, read.size)) return FileId.unknown;
      return read.id;
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Ключи файлов пачкой — в том же порядке, что [paths].
  ///
  /// Пачка нужна обходу: на десятках тысяч файлов разница между циклом здесь и запросом на
  /// каждый файл — это разница между «проход идёт» и «проход ползёт».
  List<FileId> ids(List<String> paths) {
    if (paths.isEmpty) return const [];
    final out = List<FileId>.filled(paths.length, FileId.unknown);
    for (var i = 0; i < paths.length; i++) {
      out[i] = id(paths[i]);
    }
    return out;
  }

  /// Проверить раскладку по настоящему файлу и запомнить вердикт.
  ///
  /// Сверяется размер, а не номер: номера в Dart взять неоткуда, а размер есть у обоих
  /// источников. Совпал размер — совпало смещение `st_size`, а оно лежит дальше `st_ino`,
  /// значит и номер прочитан с верного места.
  ///
  /// @return `true` — номеру можно доверять.
  bool _verify(String path, int size) {
    if (_layoutOk != null) return _layoutOk!;
    // У каталога размер в `stat` — это размер записи каталога, а не сумма содержимого,
    // а у символической ссылки — длина цели; в проверку идут только обычные файлы.
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
      return true;
    }
    final int expected;
    try {
      expected = File(path).lengthSync();
    } on FileSystemException {
      // файла уже нет: судить не о чем, попробуем на следующем
      return true;
    }
    _layoutOk = expected == size;
    return _layoutOk!;
  }

  /// Выбрать раскладку и символ по платформе; при любой осечке — [ _NoLayout].
  ///
  /// Осечка — не «приложение сломалось»: номер файла только ускоряет сверку, и без него всё
  /// работает, просто переименование обходится повторной выгрузкой.
  static NativeStat _open() {
    try {
      final layout = Platform.isMacOS
          ? _openMacos()
          : Platform.isAndroid
              ? _openAndroid()
              : null;
      if (layout != null) return NativeStat._(layout);
    } catch (_) {
      // библиотеки нет, символа нет, платформа другая — остаёмся без номеров
    }
    return NativeStat._(const _NoLayout());
  }

  /// Раскладка macOS: сначала объявление, потом символ.
  ///
  /// На x86_64 исторический символ с 64-битным номером идёт с суффиксом `$INODE64`, на arm64
  /// тот же вызов называется просто `stat`.
  static _Layout? _openMacos() {
    if (sizeOf<_StatDarwin>() != 144) return null;
    final lib = DynamicLibrary.process();
    final names = Abi.current() == Abi.macosX64
        ? const ['stat\$INODE64', 'stat']
        : const ['stat'];
    for (final name in names) {
      try {
        return _DarwinLayout(
          lib.lookupFunction<_StatDarwinNative, _StatDarwinDart>(name),
        );
      } on ArgumentError {
        // символа с таким именем нет — пробуем следующее
      }
    }
    return null;
  }

  /// Раскладка Android: своя структура на каждый ABI, символ один и тот же — `stat`.
  static _Layout? _openAndroid() {
    final lib = DynamicLibrary.open('libc.so');
    switch (Abi.current()) {
      case Abi.androidArm64:
        if (sizeOf<_StatAndroidArm64>() != 128) return null;
        try {
          return _AndroidArm64Layout(
            lib.lookupFunction<_StatArm64Native, _StatArm64Dart>('stat'),
          );
        } on ArgumentError {
          return null;
        }
      case Abi.androidX64:
        if (sizeOf<_StatAndroidX64>() != 144) return null;
        try {
          return _AndroidX64Layout(
            lib.lookupFunction<_StatX64Native, _StatX64Dart>('stat'),
          );
        } on ArgumentError {
          return null;
        }
      case Abi.androidArm:
        if (sizeOf<_StatAndroidArm>() != 104) return null;
        try {
          return _AndroidArmLayout(
            lib.lookupFunction<_StatArmNative, _StatArmDart>('stat'),
          );
        } on ArgumentError {
          return null;
        }
      default:
        return null;
    }
  }
}

/// Сигнатуры `stat(2)`: `int stat(const char *path, struct stat *buf)`.
///
/// На каждую раскладку своя пара: тип структуры в Dart — часть типа указателя, и общим его
/// не сделать (FFI не принимает параметр типа вместо конкретной структуры).
typedef _StatDarwinNative = Int32 Function(Pointer<Utf8>, Pointer<_StatDarwin>);
typedef _StatDarwinDart = int Function(Pointer<Utf8>, Pointer<_StatDarwin>);
typedef _StatArm64Native = Int32 Function(Pointer<Utf8>, Pointer<_StatAndroidArm64>);
typedef _StatArm64Dart = int Function(Pointer<Utf8>, Pointer<_StatAndroidArm64>);
typedef _StatX64Native = Int32 Function(Pointer<Utf8>, Pointer<_StatAndroidX64>);
typedef _StatX64Dart = int Function(Pointer<Utf8>, Pointer<_StatAndroidX64>);
typedef _StatArmNative = Int32 Function(Pointer<Utf8>, Pointer<_StatAndroidArm>);
typedef _StatArmDart = int Function(Pointer<Utf8>, Pointer<_StatAndroidArm>);

/// Чтение полей одной раскладки: свой тип структуры, свой буфер, своё поле номера.
abstract class _Layout {
  const _Layout();

  /// Ключ файла и его размер; `null` — `stat` вернул ошибку (файла нет, нет прав).
  ({FileId id, int size})? read(Pointer<Utf8> path);
}

/// Платформа без поддержки: номера не отдаём вовсе, как при неудачном `stat`.
class _NoLayout extends _Layout {
  const _NoLayout();

  @override
  ({FileId id, int size})? read(Pointer<Utf8> path) => null;
}

/// Раскладка macOS.
///
/// Буфер заводится один на процесс и переиспользуется: он крошечный, а `calloc`/`free` на
/// каждом из десятков тысяч файлов — лишняя работа в самом горячем цикле. Второй вызов пишет
/// в тот же буфер поверх прежнего, но прежние значения уже прочитаны, и терять их негде.
final class _DarwinLayout extends _Layout {
  _DarwinLayout(this._stat);

  final _StatDarwinDart _stat;
  final Pointer<_StatDarwin> _buf = calloc<_StatDarwin>();

  @override
  ({FileId id, int size})? read(Pointer<Utf8> path) {
    if (_stat(path, _buf) != 0) return null;
    final id = FileId(_buf.ref.dev, _buf.ref.ino);
    return (id: id, size: _buf.ref.size);
  }
}

/// Раскладка Android, 64-битный ARM.
final class _AndroidArm64Layout extends _Layout {
  _AndroidArm64Layout(this._stat);

  final _StatArm64Dart _stat;
  final Pointer<_StatAndroidArm64> _buf = calloc<_StatAndroidArm64>();

  @override
  ({FileId id, int size})? read(Pointer<Utf8> path) {
    if (_stat(path, _buf) != 0) return null;
    final id = FileId(_buf.ref.dev, _buf.ref.ino);
    return (id: id, size: _buf.ref.size);
  }
}

/// Раскладка Android, x86_64.
final class _AndroidX64Layout extends _Layout {
  _AndroidX64Layout(this._stat);

  final _StatX64Dart _stat;
  final Pointer<_StatAndroidX64> _buf = calloc<_StatAndroidX64>();

  @override
  ({FileId id, int size})? read(Pointer<Utf8> path) {
    if (_stat(path, _buf) != 0) return null;
    final id = FileId(_buf.ref.dev, _buf.ref.ino);
    return (id: id, size: _buf.ref.size);
  }
}

/// Раскладка Android, 32-битный ARM.
final class _AndroidArmLayout extends _Layout {
  _AndroidArmLayout(this._stat);

  final _StatArmDart _stat;
  final Pointer<_StatAndroidArm> _buf = calloc<_StatAndroidArm>();

  @override
  ({FileId id, int size})? read(Pointer<Utf8> path) {
    if (_stat(path, _buf) != 0) return null;
    final id = FileId(_buf.ref.dev, _buf.ref.ino);
    return (id: id, size: _buf.ref.size);
  }
}

/// `struct timespec` в 64-битных раскладках: два `long` по 8 байт.
///
/// Значения этих полей не нужны — но место занимать они обязаны: `stat` пишет структуру
/// целиком, и без них буфер оказался бы меньше структуры, а запись мимо буфера — порча памяти.
final class _Timespec extends Struct {
  @Int64()
  external int seconds;

  @Int64()
  external int nanoseconds;
}

/// `struct timespec` на 32-битном ARM: `long` там 4 байта, поэтому элемент 8 байт, а не 16.
final class _Timespec32 extends Struct {
  @Int32()
  external int seconds;

  @Int32()
  external int nanoseconds;
}

/// `struct stat` в macOS. `sizeof = 144`, `st_ino` — @8, `st_size` — @96.
final class _StatDarwin extends Struct {
  @Int32()
  external int dev; // @0

  @Uint16()
  external int mode; // @4

  @Uint16()
  external int nlink; // @6

  @Uint64()
  external int ino; // @8 — то, за чем пришли

  @Uint32()
  external int uid; // @16

  @Uint32()
  external int gid; // @20

  @Int32()
  external int rdev; // @24

  @Int32()
  external int pad0; // @28 — выравнивание до timespec

  external _Timespec atime; // @32

  external _Timespec mtime; // @48

  external _Timespec ctime; // @64

  external _Timespec birthtime; // @80

  @Int64()
  external int size; // @96 — по нему проверяется раскладка

  @Int64()
  external int blocks; // @104

  @Int32()
  external int blksize; // @112

  @Uint32()
  external int flags; // @116

  @Uint32()
  external int gen; // @120

  @Int32()
  external int lspare; // @124

  @Int64()
  external int qspare0; // @128

  @Int64()
  external int qspare1; // @136
}

/// `struct stat` на 64-битном ARM (Android). `sizeof = 128`, `st_ino` — @8, `st_size` — @48.
final class _StatAndroidArm64 extends Struct {
  @Uint64()
  external int dev; // @0

  @Uint64()
  external int ino; // @8 — то, за чем пришли

  @Uint32()
  external int mode; // @16

  @Uint32()
  external int nlink; // @20

  @Uint32()
  external int uid; // @24

  @Uint32()
  external int gid; // @28

  @Uint64()
  external int rdev; // @32

  @Uint64()
  external int pad1; // @40

  @Int64()
  external int size; // @48 — по нему проверяется раскладка

  @Int32()
  external int blksize; // @56

  @Int32()
  external int pad2; // @60

  @Int64()
  external int blocks; // @64

  external _Timespec atime; // @72

  external _Timespec mtime; // @88

  external _Timespec ctime; // @104

  @Uint32()
  external int unused4; // @120

  @Uint32()
  external int unused5; // @124
}

/// `struct stat` на x86_64 (Android). `sizeof = 144`, `st_ino` — @8, `st_size` — @48.
///
/// От arm64 отличается порядком `nlink` и `mode` и хвостом структуры: один и тот же Android
/// на разных процессорах — две разные раскладки, и путать их нельзя.
final class _StatAndroidX64 extends Struct {
  @Uint64()
  external int dev; // @0

  @Uint64()
  external int ino; // @8 — то, за чем пришли

  @Uint64()
  external int nlink; // @16

  @Uint32()
  external int mode; // @24

  @Uint32()
  external int uid; // @28

  @Uint32()
  external int gid; // @32

  @Uint32()
  external int pad0; // @36

  @Uint64()
  external int rdev; // @40

  @Int64()
  external int size; // @48 — по нему проверяется раскладка

  @Int64()
  external int blksize; // @56

  @Int64()
  external int blocks; // @64

  external _Timespec atime; // @72

  external _Timespec mtime; // @88

  external _Timespec ctime; // @104

  @Int64()
  external int pad3a; // @120

  @Int64()
  external int pad3b; // @128

  @Int64()
  external int pad3c; // @136
}

/// `struct stat` на 32-битном ARM (Android). `sizeof = 104`, `st_ino` — @96, `st_size` — @48.
final class _StatAndroidArm extends Struct {
  @Uint64()
  external int dev; // @0

  @Uint32()
  external int pad0; // @8

  @Uint32()
  external int legacyIno; // @12 — устаревший 32-битный номер, не читаем

  @Uint32()
  external int mode; // @16

  @Uint32()
  external int nlink; // @20

  @Uint32()
  external int uid; // @24

  @Uint32()
  external int gid; // @28

  @Uint64()
  external int rdev; // @32

  @Uint32()
  external int pad3; // @40

  @Int64()
  external int size; // @48 — по нему проверяется раскладка

  @Uint32()
  external int blksize; // @56

  @Uint64()
  external int blocks; // @64

  external _Timespec32 atime; // @72

  external _Timespec32 mtime; // @80

  external _Timespec32 ctime; // @88

  @Uint64()
  external int ino; // @96 — настоящий 64-битный номер
}
