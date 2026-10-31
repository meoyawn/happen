import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Capture one pasteboard snapshot. Original bytes are staged for the server;
/// resizing belongs to the server's Codex image preparation.
final class ClipboardBridge {
  private let channel: FlutterMethodChannel
  private let queue = OperationQueue()
  private var operations: [String: BlockOperation] = [:]
  private let maximumBytes = 1024 * 1024 * 1024

  init(messenger: FlutterBinaryMessenger) {
    queue.maxConcurrentOperationCount = 1
    channel = FlutterMethodChannel(name: "happen/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      let arguments = call.arguments as? [String: Any] ?? [:]
      if call.method == "cancel", let id = arguments["id"] as? String {
        self.operations[id]?.cancel()
        result(nil)
      } else if call.method == "read", let id = arguments["id"] as? String,
                let directory = arguments["directory"] as? String {
        self.read(id: id, directory: directory, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private struct Snapshot {
    let data: Data?
    let file: URL?
    let name: String
    let type: UTType
  }

  private func read(id: String, directory: String, result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    let text = pasteboard.string(forType: .string)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    var files: [String] = []
    var snapshots: [Snapshot] = []
    var seen = Set<String>()
    var names = Set<String>()
    for url in urls where url.isFileURL {
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory != true, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
        snapshots.append(Snapshot(data: nil, file: url, name: url.lastPathComponent, type: type))
        names.formUnion([url.lastPathComponent, path, url.absoluteString])
      } else {
        files.append(path)
      }
    }
    if snapshots.isEmpty && files.isEmpty {
      for item in pasteboard.pasteboardItems ?? [] {
        for type in [UTType.png, .jpeg, .gif, .webP, .heic, .heif, .tiff] {
          if let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
            snapshots.append(Snapshot(data: data, file: nil, name: "Pasted image", type: type))
            break
          }
        }
      }
    }
    if !shouldAttach(text: text ?? "", html: pasteboard.string(forType: .html), filenames: names) {
      snapshots.removeAll()
    }
    guard !snapshots.isEmpty else {
      return result(["text": text as Any? ?? NSNull(), "files": files, "images": []])
    }
    let captured = snapshots, capturedFiles = files, maximum = maximumBytes
    let operation = BlockOperation()
    operations[id] = operation
    // A cancellation before the queue starts still needs to complete Flutter's
    // method call, so the completion block owns delivery and cleanup.
    var response: Any?
    var failure: Error?
    operation.addExecutionBlock { [weak operation] in
      do {
        var images: [[String: String]] = []
        for (index, snapshot) in captured.enumerated() {
          if operation?.isCancelled != false { throw CocoaError(.userCancelled) }
          let folder = URL(fileURLWithPath: directory).appendingPathComponent(String(index))
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          let convert = snapshot.type.conforms(to: .heic) || snapshot.type.conforms(to: .heif)
          let ext = convert ? "png" : snapshot.type.preferredFilenameExtension ?? "png"
          let stem = URL(fileURLWithPath: snapshot.name).deletingPathExtension().lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
          let name = "\(stem.isEmpty ? "Pasted image" : stem).\(ext)"
          let target = folder.appendingPathComponent(name)
          if let source = snapshot.file, !convert {
            let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) <= maximum else {
              throw ClipboardError.tooLarge
            }
            FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
            defer { try? input.close(); try? output.close() }
            var size = 0
            while true {
              if operation?.isCancelled != false { throw CocoaError(.userCancelled) }
              guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
              size += chunk.count
              guard size <= maximum else { throw ClipboardError.tooLarge }
              try output.write(contentsOf: chunk)
            }
          } else {
            if let file = snapshot.file {
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
              guard size <= maximum else { throw ClipboardError.tooLarge }
            }
            var data = try snapshot.data ?? Data(contentsOf: snapshot.file!, options: .mappedIfSafe)
            guard data.count <= maximum else { throw ClipboardError.tooLarge }
            if convert {
              guard let bitmap = NSBitmapImageRep(data: data),
                    let png = bitmap.representation(using: .png, properties: [:]) else { throw ClipboardError.invalid }
              data = png
            }
            if operation?.isCancelled != false { throw CocoaError(.userCancelled) }
            try data.write(to: target, options: .atomic)
          }
          images.append(["path": target.path, "name": name])
        }
        response = ["text": text as Any? ?? NSNull(), "files": capturedFiles, "images": images]
      } catch { failure = error }
    }
    operation.completionBlock = { [weak self, weak operation] in
      let cancelled = operation?.isCancelled != false
      if cancelled || failure != nil { try? FileManager.default.removeItem(atPath: directory) }
      DispatchQueue.main.async {
        self?.operations.removeValue(forKey: id)
        if cancelled {
          result(FlutterError(code: "cancelled", message: "Paste cancelled", details: nil))
        } else if let error = failure {
          result(FlutterError(code: "clipboard_image", message: error.localizedDescription, details: nil))
        } else { result(response) }
      }
    }
    queue.addOperation(operation)
  }

  private func shouldAttach(text: String, html: String?, filenames: Set<String>) -> Bool {
    if let html = html, !html.isEmpty, html.utf16.count <= 100000,
       let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) {
      var hasText = false, hasMedia = false
      let ignored: Set<String> = ["head", "script", "style", "template", "noscript", "title", "meta", "link"]
      func visit(_ node: XMLNode) {
        if let element = node as? XMLElement {
          let tag = element.name?.lowercased() ?? ""
          if ignored.contains(tag) || element.attribute(forName: "hidden") != nil ||
              element.attribute(forName: "aria-hidden")?.stringValue == "true" { return }
          let style = (element.attribute(forName: "style")?.stringValue ?? "").lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
          if style.contains("display:none") || style.contains("visibility:hidden") { return }
          if ["img", "svg", "canvas", "video"].contains(tag) { hasMedia = true; return }
        } else if node.kind == .text && !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          hasText = true
        }
        for child in node.children ?? [] { visit(child) }
      }
      visit(document)
      if hasText { return false }
      if hasMedia { return true }
    }
    return text.components(separatedBy: .newlines).allSatisfy {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty || filenames.contains(value)
    }
  }

  private enum ClipboardError: LocalizedError {
    case tooLarge, invalid
    var errorDescription: String? {
      switch self {
      case .tooLarge: return "Image exceeds the Codex 1 GiB input limit."
      case .invalid: return "The clipboard image could not be decoded."
      }
    }
  }

  deinit { queue.cancelAllOperations(); channel.setMethodCallHandler(nil) }
}
