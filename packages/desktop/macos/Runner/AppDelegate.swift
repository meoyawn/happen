import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  @IBAction func showSettings(_ sender: Any?) {
    (mainFlutterWindow as? MainFlutterWindow)?.showSettings()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
