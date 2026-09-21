import Flutter
import UIKit
import UniformTypeIdentifiers

/// Папки, к которым человек дал доступ через системный «Файлы».
///
/// iOS не выпускает приложение за пределы его песочницы: обойти диск, как на Android и macOS,
/// здесь нечего, и единственный способ получить папку — системный выбор
/// (`UIDocumentPickerViewController`). Выбранный адрес приходит с «security scope», и право
/// на доступ к нему надо открыть вызовом `startAccessingSecurityScopedResource()`: из Dart
/// его не сделать, а без него любое обращение к файлу по этому пути получит отказ. Ровно
/// поэтому здесь есть нативный код, а всё остальное (обход, чтение, запись, хэш) синхронизатор
/// делает сам, обычным Dart.
///
/// Право живёт до конца процесса, поэтому после перезапуска приложения его надо открыть заново.
/// Чтобы папка после перезапуска нашлась, путь сохраняется не строкой, а закладкой
/// (`bookmarkData`): закладка переживает и смену пути контейнера у сторонних провайдеров, и
/// обновление системы, тогда как записанный строкой путь в этих случаях устаревает.
///
/// Канал: `ru.cloudly.sync/folders`, методы `list`, `pick`, `remove`. Ответ — словари
/// `{path, name, granted}`, те же поля читает `lib/sync/device/ios_folders.dart`.
final class FolderAccess: NSObject, UIDocumentPickerDelegate {
  /// Где лежат закладки. UserDefaults, а не своя база: папок единицы, и хранить больше нечего.
  private static let bookmarksKey = "cloudly.folderBookmarks"

  private let channel: FlutterMethodChannel

  /// Папки с открытым доступом: путь → адрес. Ключ — путь, потому что с путями работает Dart.
  private var opened: [String: URL] = [:]

  /// Ответ на идущий выбор папки: системный диалог отвечает не сразу, а два диалога сразу
  /// показать нельзя, поэтому второй запрос получает ошибку, а не второй диалог.
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ru.cloudly.sync/folders", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    // Доступ к выбранным раньше папкам открываем сразу при запуске: синхронизация начинается
    // до того, как человек что-нибудь нажмёт, и к этому моменту папки уже должны читаться.
    restoreBookmarks()
  }

  /// Разбор вызова из Dart. Исключений наружу нет: любая осечка — это `FlutterError`
  /// с понятной причиной, а не падение приложения.
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "list":
      result(folders())
    case "pick":
      presentPicker(result)
    case "remove":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "нужен path", details: nil))
        return
      }
      forget(path)
      result(folders())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Список папок: путь для Dart, имя для человека и признак «читается прямо сейчас».
  private func folders() -> [[String: Any]] {
    opened.values
      .sorted { $0.path < $1.path }
      .map { ["path": $0.path, "name": displayName($0), "granted": canRead($0)] }
  }

  /// Показать системный выбор папки.
  ///
  /// `asCopy: false` — принципиально: с копией система отдала бы приложению собственную копию
  /// содержимого, и синхронизировали бы мы её, а не папку человека.
  private func presentPicker(_ result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "busy", message: "выбор папки уже открыт", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "no_window", message: "нет окна для выбора папки", details: nil))
      return
    }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    host.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      finish(nil)
      return
    }
    // Право открываем сразу и держим до конца процесса: обход папки и выгрузка идут в фоне,
    // и доступ понадобится в любой момент, а не только сейчас. Закрывать его между операциями
    // нельзя — на этом и построена работа синхронизатора.
    _ = url.startAccessingSecurityScopedResource()
    opened[url.path] = url
    persist()
    finish(["path": url.path, "name": displayName(url), "granted": canRead(url)])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    // Человек закрыл диалог: это не ошибка, а «ничего не выбрано».
    finish(nil)
  }

  /// Ответить на запрос выбора папки ровно один раз: `FlutterResult` — одноразовый,
  /// а система может позвать и `didPick`, и `WasCancelled` подряд.
  private func finish(_ value: Any?) {
    let result = pending
    pending = nil
    result?(value)
  }

  /// Забыть папку: доступ закрывается, закладка стирается.
  ///
  /// Без этого выбранную по ошибке папку нельзя было бы убрать из списка — а в списке она
  /// остаётся навсегда, потому что восстанавливается из закладки при каждом запуске.
  private func forget(_ path: String) {
    guard let url = opened.removeValue(forKey: path) else { return }
    url.stopAccessingSecurityScopedResource()
    persist()
  }

  /// Открыть доступ к папкам, выбранным в прошлые запуски.
  ///
  /// Устаревшая закладка (провайдер переехал, система обновилась) не повод терять папку:
  /// адрес из неё всё ещё разрешается, поэтому доступ открывается, а закладка перезаписывается
  /// свежей. Совсем неразрешимая закладка отбрасывается — сказать о ней человеку нечем,
  /// а папка просто появится в списке заново, если её выбрать снова.
  private func restoreBookmarks() {
    guard let stored = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [String] else { return }
    for base64 in stored {
      guard let data = Data(base64Encoded: base64) else { continue }
      var stale = false
      guard let url = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ) else { continue }
      _ = url.startAccessingSecurityScopedResource()
      opened[url.path] = url
    }
    // Перезапись идёт целиком: так устаревшие закладки заменяются свежими, а неразрешимые
    // исчезают из хранилища сами.
    persist()
  }

  /// Сохранить закладки на все открытые папки.
  private func persist() {
    let bookmarks = opened.values.compactMap { url -> String? in
      let options: URL.BookmarkCreationOptions = []
      guard let data = try? url.bookmarkData(
        options: options,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      ) else { return nil }
      return data.base64EncodedString()
    }
    UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
  }

  /// Имя папки для человека: последний кусок пути. У папки из iCloud это её имя,
  /// у корня провайдера — имя провайдера, и в обоих случаях это то, что человек узнаёт.
  private func displayName(_ url: URL) -> String {
    let name = url.lastPathComponent
    return name.isEmpty ? "Папка" : name
  }

  /// Читается ли папка прямо сейчас. Проверка делом, а не флагом: `startAccessing…` возвращает
  /// `false` и для папки внутри собственного контейнера приложения — там доступ есть и без него,
  /// и принимать этот `false` за отказ значило бы врать человеку.
  private func canRead(_ url: URL) -> Bool {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
  }

  /// Контроллер, поверх которого показывать диалог: у приложения одна сцена, но выбирать
  /// надо самый верхний контроллер — иначе диалог не покажется, если что-то уже открыто поверх.
  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}
