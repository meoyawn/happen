import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var desktopChannel: FlutterMethodChannel?
  private var dictationAudio: DictationAudioBridge?
  private var clipboard: ClipboardBridge?
  private var statusItem: NSStatusItem?
  private var fullscreenCloseObserver: NSObjectProtocol?
  private let windowControls = WindowControlsView()
  private var trafficLights: [NSButton] = []
  private weak var trafficLightsParent: NSView?
  private var trafficLightFrames: [NSRect] = []
  private var trafficLightPitch: CGFloat = 20
  private var windowLayout = "side"
  private var dragMouseDown: NSEvent?

  // OpenCode uses a hidden title bar and real macOS controls over its content.
  private func configureWindowChrome() {
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    if #available(macOS 11.0, *) { titlebarSeparatorStyle = .none }
    backgroundColor = NSColor(calibratedWhite: 249.0 / 255.0, alpha: 1)
    isMovableByWindowBackground = false

    trafficLights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { standardWindowButton($0) }
    trafficLightsParent = trafficLights.first?.superview
    trafficLightFrames = trafficLights.map { $0.frame }
    if trafficLightFrames.count > 1 {
      trafficLightPitch = trafficLightFrames[1].minX - trafficLightFrames[0].minX
    }
    contentView?.addSubview(windowControls, positioned: .above, relativeTo: nil)
    dockWindowControls()
  }

  private func dockWindowControls() {
    guard !styleMask.contains(.fullScreen), let content = contentView,
          let first = trafficLights.first else { return }
    windowControls.isHidden = false
    let inset: CGFloat = windowLayout == "side" ? 25 : 14
    let size = first.frame.size
    windowControls.frame = NSRect(x: inset, y: content.bounds.height - inset - size.height,
      width: trafficLightPitch * 2 + size.width, height: size.height)
    windowControls.autoresizingMask = [.minYMargin]
    for (index, button) in trafficLights.enumerated() {
      if button.superview !== windowControls { windowControls.addSubview(button) }
      button.setFrameOrigin(NSPoint(x: CGFloat(index) * trafficLightPitch, y: 0))
    }
  }

  private func restoreWindowControls() {
    guard let parent = trafficLightsParent else { return }
    for (button, frame) in zip(trafficLights, trafficLightFrames) {
      parent.addSubview(button)
      button.frame = frame
    }
    windowControls.isHidden = true
  }

  private func windowChromeState() -> [String: Any] {
    ["fullscreen": styleMask.contains(.fullScreen), "trafficLightsEnd": windowControls.frame.maxX]
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown { dragMouseDown = event }
    if event.type == .leftMouseUp { dragMouseDown = nil }
    super.sendEvent(event)
  }

  func windowDidResize(_ notification: Notification) {
    dockWindowControls()
  }

  func windowWillEnterFullScreen(_ notification: Notification) {
    restoreWindowControls()
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    desktopChannel?.invokeMethod("windowChromeChanged", arguments: windowChromeState())
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    dockWindowControls()
    desktopChannel?.invokeMethod("windowChromeChanged", arguments: windowChromeState())
  }

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
    // Admit hover from the first tracking area, even before this window is key.
    flutterViewController.mouseTrackingMode = .always
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
      if call.method == "setWindowLayout" {
        guard let self = self, let arguments = call.arguments as? [String: Any],
              let layout = arguments["layout"] as? String, ["top", "side"].contains(layout) else {
          result(FlutterError(code: "invalid_layout", message: "Invalid window layout", details: nil))
          return
        }
        self.windowLayout = layout
        self.dockWindowControls()
        result(self.windowChromeState())
        return
      }
      if call.method == "startWindowDrag" {
        result(nil)
        if let self = self, let event = self.dragMouseDown { self.performDrag(with: event) }
        return
      }
      if call.method == "titlebarDoubleClick" {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if action == "Minimize" {
          self?.miniaturize(nil)
        } else if action != "None" {
          self?.zoom(nil)
        }
        result(nil)
        return
      }
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
    configureWindowChrome()
    createStatusItem()
  }

  deinit {
    if let observer = fullscreenCloseObserver { NotificationCenter.default.removeObserver(observer) }
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
  }
}

// Empty space passes through to Flutter; these are the system's original buttons.
private class WindowControlsView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
