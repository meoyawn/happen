import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var desktopChannel: FlutterMethodChannel?
  private var dictationAudio: DictationAudioBridge?
  private var clipboard: ClipboardBridge?
  private var statusItem: NSStatusItem?
  private var fullscreenCloseObserver: NSObjectProtocol?

  func showSettings() {
    showMainWindow()
    desktopChannel?.invokeMethod("showSettings", arguments: nil)
  }

  func showMainWindow() {
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showFromTray(_ sender: Any?) {
    showMainWindow()
  }

  @objc private func quitFromTray(_ sender: Any?) {
    NSApp.terminate(sender)
  }

  private func createStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: 22)
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      let path = NSBezierPath()
      path.lineWidth = 2.5
      path.lineCapStyle = .round
      path.move(to: NSPoint(x: 4, y: 3))
      path.line(to: NSPoint(x: 4, y: 15))
      path.move(to: NSPoint(x: 14, y: 3))
      path.line(to: NSPoint(x: 14, y: 15))
      path.move(to: NSPoint(x: 4, y: 9))
      path.line(to: NSPoint(x: 14, y: 9))
      path.stroke()
      return true
    }
    image.isTemplate = true
    item.button?.image = image
    item.button?.setAccessibilityLabel("Happen")
    let menu = NSMenu()
    let show = NSMenuItem(title: "Show", action: #selector(showFromTray(_:)), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    let quit = NSMenuItem(title: "Quit", action: #selector(quitFromTray(_:)), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if styleMask.contains(.fullScreen) {
      guard fullscreenCloseObserver == nil else { return false }
      fullscreenCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        if let observer = self.fullscreenCloseObserver { NotificationCenter.default.removeObserver(observer) }
        self.fullscreenCloseObserver = nil
        self.orderOut(nil)
      }
      toggleFullScreen(nil)
    } else {
      orderOut(nil)
    }
    return false
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 540)
    self.setContentSize(NSSize(width: 1120, height: 760))

    RegisterGeneratedPlugins(registry: flutterViewController)
    dictationAudio = DictationAudioBridge(messenger: flutterViewController.engine.binaryMessenger)
    clipboard = ClipboardBridge(messenger: flutterViewController.engine.binaryMessenger)

    let channel = FlutterMethodChannel(
      name: "happen/desktop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "activate" {
        self?.showMainWindow()
        result(nil)
        return
      }
      if call.method == "openMcpLoginUrl" {
        guard let value = call.arguments as? String, let url = URL(string: value),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else {
          result(FlutterError(code: "invalid_url", message: "Invalid MCP sign-in URL", details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
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
    delegate = self
    createStatusItem()
  }

  deinit {
    if let observer = fullscreenCloseObserver { NotificationCenter.default.removeObserver(observer) }
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
  }
}
