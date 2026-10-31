import Cocoa
import AVFoundation
import FlutterMacOS

// Local microphone capture only. Authentication and transcription stay in Dart;
// neither audio nor tokens are written to logs or the system pasteboard.
final class DictationAudioBridge: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var engine: AVAudioEngine?
  private var captureID: String?
  private var pendingID: String?
  private var gain: Double = 1
  private let sampleRate: Double = 16000

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "happen/dictation", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "happen/dictation/audio", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterError(code: "unavailable", message: "Dictation is unavailable", details: nil)) }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "status":
        let authorization: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorization = "authorized"
        case .notDetermined: authorization = "notDetermined"
        case .denied: authorization = "denied"
        case .restricted: authorization = "restricted"
        @unknown default: authorization = "unknown"
        }
        result(["permission": authorization, "recording": self.engine != nil, "sampleRate": Int(self.sampleRate)])
      case "start":
        guard let id = args?["id"] as? String else { return result(FlutterError(code: "invalid_id", message: "Missing capture identifier", details: nil)) }
        self.start(id: id, result: result)
      case "stop", "cancel":
        let id = args?["id"] as? String
        if id == nil || id == self.pendingID { self.pendingID = nil }
        if id == nil || id == self.captureID { self.stop() }
        // Drain audio events already queued by the tap before completing stop.
        DispatchQueue.main.async { result(nil) }
      case "openMicrophoneSettings":
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    events.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    pendingID = nil
    stop()
    sink = nil
    return nil
  }

  private func start(id: String, result: @escaping FlutterResult) {
    guard captureID == nil, pendingID == nil else {
      return result(FlutterError(code: "microphone_busy", message: "The microphone is already in use by dictation", details: nil))
    }
    pendingID = id
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      begin(id: id, result: result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
        DispatchQueue.main.async {
          guard let self = self, self.pendingID == id else { return result(FlutterError(code: "cancelled", message: "Dictation cancelled", details: nil)) }
          if allowed { self.begin(id: id, result: result) }
          else {
            self.pendingID = nil
            result(FlutterError(code: "microphone_permission", message: "Enable mic access to dictate", details: nil))
          }
        }
      }
    default:
      pendingID = nil
      result(FlutterError(code: "microphone_permission", message: "Enable mic access to dictate", details: nil))
    }
  }

  private func begin(id: String, result: @escaping FlutterResult) {
    guard pendingID == id, sink != nil else {
      pendingID = nil
      return result(FlutterError(code: "cancelled", message: "Dictation cancelled", details: nil))
    }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
          let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      pendingID = nil
      return result(FlutterError(code: "microphone_missing", message: "Connect a microphone to use dictation", details: nil))
    }
    gain = 1
    captureID = id
    pendingID = nil
    self.engine = engine
    input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
      guard let self = self else { return }
      let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate) + 64)
      guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
      var supplied = false
      var conversionError: NSError?
      let status = converter.convert(to: converted, error: &conversionError) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      if status == .error {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.captureID == id else { return }
          self.sink?(["type": "error", "id": id, "code": "microphone_unavailable"])
          self.stop()
        }
        return
      }
      guard converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
      let count = Int(converted.frameLength)
      var squareSum: Double = 0
      var peak: Double = 0
      for index in 0..<count {
        let sample = Double(samples[index])
        squareSum += sample * sample
        peak = max(peak, abs(sample))
      }
      let rms = sqrt(squareSum / Double(count))
      // Source N7a/P7a: adaptive gain with a silence floor and bounded peak.
      if rms < 0.003 { self.gain = 1 }
      else {
        let target = min(4, max(1, 0.063 / rms), 0.708 / max(peak, 0.000001))
        self.gain = target <= self.gain ? target : self.gain + (target - self.gain) * 0.35
      }
      var pcm = Data(capacity: count * 2)
      for index in 0..<count {
        let sample = max(-1, min(1, Double(samples[index]) * self.gain))
        var value = Int16(sample < 0 ? sample * 32768 : sample * 32767).littleEndian
        withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.sink?(["type": "audio", "id": id, "pcm": FlutterStandardTypedData(bytes: pcm), "rms": rms, "sampleRate": Int(self.sampleRate)])
      }
    }
    do {
      engine.prepare()
      try engine.start()
      result(["sampleRate": Int(sampleRate)])
    } catch {
      stop()
      result(FlutterError(code: "microphone_unavailable", message: "Close other apps using the microphone", details: nil))
    }
  }

  private func stop() {
    let previous = engine
    engine = nil
    captureID = nil
    previous?.inputNode.removeTap(onBus: 0)
    previous?.stop()
  }

  deinit {
    stop()
    methods.setMethodCallHandler(nil)
    events.setStreamHandler(nil)
  }
}
