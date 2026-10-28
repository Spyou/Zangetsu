import AVFoundation
import Flutter
import Speech
import UIKit

/// iPhone recognition for the shared voice sheet. Apple TV keeps its own input.
final class PhoneVoiceSearchBridge {
  private final class Session {
    let id: Int
    let reply: FlutterResult
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    var recognizer: SFSpeechRecognizer?
    var task: SFSpeechRecognitionTask?
    var timer: DispatchSourceTimer?
    var tapInstalled = false
    var processing = false
    var hasWords = false
    var startedAt = ProcessInfo.processInfo.systemUptime
    var lastVoiceAt = ProcessInfo.processInfo.systemUptime
    var lastLevelAt = 0.0
    var previousCategory: AVAudioSession.Category?
    var previousMode: AVAudioSession.Mode?
    var previousOptions: AVAudioSession.CategoryOptions?

    init(id: Int, reply: @escaping FlutterResult) { self.id = id; self.reply = reply }
  }

  private let channel: FlutterMethodChannel
  private let authorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
  private let authorizeSpeech: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
  private var active: Session?
  private var observers: [NSObjectProtocol] = []

  init(
    messenger: FlutterBinaryMessenger,
    authorizationStatus: @escaping () -> SFSpeechRecognizerAuthorizationStatus = { SFSpeechRecognizer.authorizationStatus() },
    authorizeSpeech: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { SFSpeechRecognizer.requestAuthorization($0) }
  ) {
    channel = FlutterMethodChannel(name: "zangetsu/phone_voice_search", binaryMessenger: messenger)
    self.authorizationStatus = authorizationStatus
    self.authorizeSpeech = authorizeSpeech
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else { reply(FlutterMethodNotImplemented); return }
      self.handle(call, result: reply)
    }
    for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.cancelActive()
      })
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let id = (call.arguments as? [String: Any])?["sessionId"] as? Int
    switch call.method {
    case "isAvailable": result(SFSpeechRecognizer(locale: Locale.current) != nil)
    case "cancel":
      if active?.id == id { cancelActive() }
      result(nil)
    case "listen":
      guard let id = id, id > 0 else {
        result(FlutterError(code: "voice_failed", message: "Invalid voice session", details: nil)); return
      }
      guard active == nil else {
        result(FlutterError(code: "voice_busy", message: "Voice search is already listening", details: nil)); return
      }
      let session = Session(id: id, reply: result)
      active = session
      if authorizationStatus() == .notDetermined {
        authorizeSpeech { [weak self, weak session] status in
          DispatchQueue.main.async {
            guard let self = self, let session = session, self.active === session else { return }
            if status == .authorized { self.start(session) }
            else { self.finish(session, error: "voice_speech_permission") }
          }
        }
      } else if authorizationStatus() == .authorized { start(session) }
      else { finish(session, error: "voice_speech_permission") }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ session: Session) {
    guard active === session else { return }
    guard UIApplication.shared.applicationState != .background else { finish(session); return }
    let audio = AVAudioSession.sharedInstance()
    guard audio.recordPermission == .granted else { finish(session, error: "voice_permission"); return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
      finish(session, error: "voice_unavailable"); return
    }
    do {
      let category = audio.category, mode = audio.mode, options = audio.categoryOptions
      try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
      session.previousCategory = category
      session.previousMode = mode
      session.previousOptions = options
      try audio.setActive(true)
      session.recognizer = recognizer
      session.request.shouldReportPartialResults = true
      session.task = recognizer.recognitionTask(with: session.request) { [weak self, weak session] response, error in
        DispatchQueue.main.async {
          guard let self = self, let session = session, self.active === session else { return }
          if let response = response {
            let text = response.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if response.isFinal {
              self.finish(session, text: text, error: text.isEmpty ? "voice_no_match" : nil)
              return
            }
            if !text.isEmpty {
              session.hasWords = true
              session.lastVoiceAt = ProcessInfo.processInfo.systemUptime
              self.emit(session, state: "partial", text: text)
            }
          }
          if error != nil { self.finish(session, error: "voice_failed") }
        }
      }
      let input = session.engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        finish(session, error: "voice_failed"); return
      }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak session] buffer, _ in
        guard let session = session else { return }
        session.request.append(buffer)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - session.lastLevelAt >= 0.08, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        session.lastLevelAt = now
        var total: Float = 0
        for i in 0..<Int(buffer.frameLength) { total += samples[i] * samples[i] }
        let rms = sqrt(total / Float(buffer.frameLength))
        let level = min(1.0, max(0.0, Double((20 * log10(max(rms, 0.000001)) + 55) / 45)))
        DispatchQueue.main.async {
          guard let self = self, self.active === session, !session.processing else { return }
          if level > 0.18 { session.lastVoiceAt = now }
          self.emit(session, state: "level", level: level)
        }
      }
      session.tapInstalled = true
      session.engine.prepare()
      try session.engine.start()
      session.startedAt = ProcessInfo.processInfo.systemUptime
      session.lastVoiceAt = session.startedAt
      emit(session, state: "listening")
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
      timer.setEventHandler { [weak self, weak session] in
        guard let self = self, let session = session, self.active === session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - session.startedAt >= 30 {
          self.finish(session, error: "voice_no_match")
        } else if !session.processing && now - session.lastVoiceAt >= 1.4 {
          if session.hasWords {
            session.processing = true
            self.stopInput(session)
            session.request.endAudio()
            self.emit(session, state: "processing")
          } else if now - session.startedAt >= 8 {
            self.finish(session, error: "voice_no_match")
          }
        }
      }
      session.timer = timer
      timer.resume()
    } catch { finish(session, error: "voice_failed") }
  }

  private func emit(_ session: Session, state: String, level: Double = 0, text: String? = nil) {
    guard active === session else { return }
    var payload: [String: Any] = ["sessionId": session.id, "state": state, "level": level]
    if let text = text { payload["text"] = text }
    channel.invokeMethod("state", arguments: payload)
  }

  private func stopInput(_ session: Session) {
    session.engine.stop()
    if session.tapInstalled {
      session.engine.inputNode.removeTap(onBus: 0)
      session.tapInstalled = false
    }
  }

  private func finish(_ session: Session, text: String? = nil, error: String? = nil) {
    guard active === session else { return }
    active = nil
    session.timer?.cancel()
    stopInput(session)
    session.request.endAudio()
    session.task?.cancel()
    session.task = nil
    let audio = AVAudioSession.sharedInstance()
    if let category = session.previousCategory, let mode = session.previousMode,
       let options = session.previousOptions, audio.category == .record, audio.mode == .measurement {
      try? audio.setActive(false, options: .notifyOthersOnDeactivation)
      try? audio.setCategory(category, mode: mode, options: options)
    }
    if let error = error { session.reply(FlutterError(code: error, message: "Voice recognition did not complete", details: nil)) }
    else { session.reply(text) }
  }

  private func cancelActive() { if let session = active { finish(session) } }

  func dispose() {
    cancelActive()
    channel.setMethodCallHandler(nil)
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
