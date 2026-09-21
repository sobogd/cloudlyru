import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Доступ к папкам, выбранным в «Файлах» (см. `FolderAccess.swift`). Ссылку держим здесь:
  /// объект — делегат системного выбора папки и владелец обработчика канала, без ссылки его
  /// освободил бы ARC, и Dart остался бы без ответов.
  private var folderAccess: FolderAccess?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Свой канал поднимается вместе с плагинами: на iOS папку нельзя ни обойти, ни выбрать
    // без системного диалога, поэтому без этого кода синхронизация на iPad работать не может.
    folderAccess = FolderAccess(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
