import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// Закрытие окна (красный крестик, ⌘W) прячет приложение, а не закрывает его.
  ///
  /// Приложение — клиент синхронизации: пока процесс жив, файлы уезжают в облако и приезжают
  /// из него. Поэтому закрытие окна не должно ни гасить процесс, ни уничтожать окно (заводить
  /// на месте закрытого новый FlutterViewController — это потеря всего состояния приложения).
  /// `NSApp.hide` делает ровно нужное: окно живо и вернётся по иконке в доке или из меню-бара
  /// (см. `AppDelegate.showMainWindow`).
  override func performClose(_ sender: Any?) {
    NSApp.hide(sender)
  }
}
