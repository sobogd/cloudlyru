import Cocoa
import FlutterMacOS
import ServiceManagement

/// Точка входа macOS-сборки.
///
/// Сверх шаблона Flutter здесь две вещи, и обе — про то, что на маке это не «окно с
/// интерфейсом», а клиент синхронизации, работающий постоянно:
///
/// 1. **Закрытие окна не завершает приложение.** Окно прячется (см.
///    `MainFlutterWindow.performClose`), в доке остаётся иконка, вернуть окно можно по ней или
///    из строки состояния в меню-баре. Иначе закрытие окна гасило бы процесс вместе с
///    синхронизацией — то есть ровно то, ради чего приложение запущено.
/// 2. **Системе сказано, что приложение работает.** Пока окна не видно, macOS считает
///    приложение бездействующим и «усыпляет» его (App Nap): таймеры Dart и доставка событий
///    файловой системы откладываются до возвращения человека в окно. Отсюда и «файл лежит в
///    папке, а в облако не едет». App Nap снимается activity у `ProcessInfo`, взятой на всё
///    время работы приложения: это документированный способ, а одноимённый ключ Info.plist
///    современные macOS не смотрят.
@main
class AppDelegate: FlutterAppDelegate {
  /// Разрешение на работу в фоне, выданное системой. Держим ссылку: activity живёт, пока жив
  /// объект, — освобождение (или явный `endActivity`) разрешение снимает.
  private var backgroundActivity: NSObjectProtocol?

  /// Иконка в меню-баре. Пока окна на экране нет, попасть в приложение больше нечем; там же
  /// переключатель автозапуска и выход.
  private var statusItem: NSStatusItem?

  /// Пункт «Запускать при входе»: его галочка отражает состояние системы, поэтому ссылка нужна
  /// и после того, как меню собрано.
  private var loginItemMenuItem: NSMenuItem?

  /// Настройка приложения — до того, как на экране появится окно.
  ///
  /// Хук выбран именно этот: Flutter заводит своё в `applicationWillFinishLaunching:` (движок и
  /// обработчики жизненного цикла), и вызов `super` здесь гарантированно попадает в его код.
  /// `applicationDidFinishLaunching:` для этого не годится: FlutterAppDelegate его не
  /// реализует, и `super` там — вызов метода, которого у предка нет.
  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    beginBackgroundActivity()
    setUpStatusItem()
  }

  /// Последнее окно закрыли — приложение остаётся: закрытие окна здесь это «спрятать», а не
  /// «выйти» (выход — ⌘Q или пункт в меню-баре).
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// Восстанавливаемое состояние окна кодируется безопасно. Значение то же, что в шаблоне
  /// Flutter: без этого переопределения система на каждом запуске ругается в лог на
  /// небезопасное кодирование состояния.
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Клик по иконке в доке: вернуть окно, а не открыть второе.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  /// Выход (⌘Q или «Выход» в меню-баре): отпускаем activity, не дожидаясь конца процесса.
  ///
  /// `super` здесь не зовём: этого метода у FlutterAppDelegate нет (своё завершение Flutter
  /// ведёт в `applicationShouldTerminate:` — его мы не трогаем), и вызов `super` был бы
  /// вызовом того, чего у предка не существует.
  override func applicationWillTerminate(_ notification: Notification) {
    endBackgroundActivity()
  }

  // MARK: - Работа в фоне

  /// Взять у системы activity на всё время работы: с ней macOS не «усыпляет» приложение,
  /// когда его окна не видно.
  ///
  /// Опция `.userInitiatedAllowingIdleSystemSleep` — «работа по просьбе человека, но системе
  /// спать можно»: App Nap снимается, а машина при простое засыпает как обычно (в отличие от
  /// `.userInitiated`, который заодно запрещает и сон системы).
  ///
  /// Идемпотентно: повторный вызов ничего не делает.
  private func beginBackgroundActivity() {
    guard backgroundActivity == nil else { return }
    backgroundActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Синхронизация папок с облаком")
  }

  /// Отпустить activity: приложение снова обычное, и система может его усыплять.
  private func endBackgroundActivity() {
    if let activity = backgroundActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backgroundActivity = nil
    }
  }

  // MARK: - Меню-бар

  /// Собрать пункт в меню-баре: «Открыть Cloudly», «Запускать при входе», «Выход».
  ///
  /// Ошибок не бросает и ничего не проверяет: если система не дала строку состояния (такое
  /// бывает на перегруженном меню-баре), приложение просто остаётся без неё — прятать и
  /// показывать окно по-прежнему можно по иконке в доке.
  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "arrow.triangle.2.circlepath",
      accessibilityDescription: "Cloudly")
    item.button?.toolTip = "Cloudly — синхронизация"

    let menu = NSMenu()
    menu.addItem(menuItem(title: "Открыть Cloudly", action: #selector(openFromMenu)))
    menu.addItem(.separator())
    // Автозапуск есть только с macOS 13: там появился SMAppService. Костыль под 12
    // (LaunchAgent-плист в домашней папке) не стоит своей цены — на 12 пункта просто нет
    if #available(macOS 13.0, *) {
      let login = menuItem(title: "Запускать при входе", action: #selector(toggleLoginItem))
      loginItemMenuItem = login
      menu.addItem(login)
      menu.addItem(.separator())
    }
    menu.addItem(menuItem(title: "Выход", action: #selector(quitFromMenu)))

    item.menu = menu
    statusItem = item
    if #available(macOS 13.0, *) { refreshLoginItemState() }
  }

  /// Пункт меню с целью на этом объекте: без `target` пункт ушёл бы по цепочке респондеров и
  /// не нашёл обработчика.
  private func menuItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  /// «Открыть Cloudly» в меню-баре.
  @objc private func openFromMenu() {
    showMainWindow()
  }

  /// «Выход» в меню-баре: тот же путь, что у ⌘Q.
  @objc private func quitFromMenu() {
    NSApp.terminate(nil)
  }

  /// Показать главное окно: оно спрятано, а не закрыто, поэтому достаточно вернуть его на экран.
  private func showMainWindow() {
    // Спрятанное приложение сначала надо вернуть: одна активация окна не показывает.
    // `activate()` есть с macOS 14, до неё — прежний вызов с флагом.
    NSApp.unhide(nil)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    mainWindow?.makeKeyAndOrderFront(nil)
  }

  /// Главное окно приложения: ищем по типу, а не по индексу — у приложения бывают и другие
  /// окна (панели, диалоги Flutter).
  private var mainWindow: NSWindow? {
    NSApp.windows.first { $0 is MainFlutterWindow }
  }

  // MARK: - Автозапуск

  /// Переключить автозапуск при входе в систему.
  ///
  /// Состояние не храним у себя: им владеет система (человек может снять галку в «Объектах
  /// входа»), поэтому после попытки галочка перечитывается у неё, а ошибка уходит в лог —
  /// иначе от «пункт не реагирует» не осталось бы и следа.
  @objc private func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      NSLog("cloudly: автозапуск не переключился: \(error)")
    }
    refreshLoginItemState()
  }

  /// Подтянуть галочку автозапуска из системы.
  @available(macOS 13.0, *)
  private func refreshLoginItemState() {
    guard let item = loginItemMenuItem else { return }
    switch SMAppService.mainApp.status {
    case .enabled:
      item.state = .on
      item.title = "Запускать при входе"
    case .requiresApproval:
      // Система ждёт подтверждения человека в «Объектах входа» — галочка при этом не стоит
      item.state = .off
      item.title = "Запускать при входе (разрешите в настройках)"
    default:
      item.state = .off
      item.title = "Запускать при входе"
    }
  }
}
