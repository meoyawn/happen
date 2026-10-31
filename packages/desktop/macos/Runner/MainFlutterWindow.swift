import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?

  func showSettings() {
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    desktopChannel?.invokeMethod("showSettings", arguments: nil)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 540)
    self.setContentSize(NSSize(width: 1120, height: 760))

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "happen/desktop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "activate" {
        self?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
        return
      }
      guard call.method == "openLoginUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let value = call.arguments as? String, let url = URL(string: value),
            url.scheme == "https", ["auth.openai.com", "opencode.ai", "auth.opencode.ai"].contains(url.host ?? "") else {
        result(FlutterError(code: "invalid_url", message: "Invalid sign-in URL", details: nil))
        return
      }
      result(NSWorkspace.shared.open(url))
    }

    super.awakeFromNib()
  }
}
