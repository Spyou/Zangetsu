import AVKit
import Flutter
import UIKit
import VideoToolbox

@available(iOS 16.0, *)
final class MpvPictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate {
  private let textures: MpvTextureRegistry
  private let channel: FlutterMethodChannel
  private let layer = AVSampleBufferDisplayLayer()
  private var controller: AVPictureInPictureController?
  private var possible: NSKeyValueObservation?
  private var pendingStart: FlutterResult?
  private var pool: CVPixelBufferPool?
  private var format: CMVideoFormatDescription?
  private var transfer: VTPixelTransferSession?
  private var playing = false
  private var sourceSize: (width: Int, height: Int, format: OSType)?
  private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  init(messenger: FlutterBinaryMessenger, textures: MpvTextureRegistry) {
    self.textures = textures
    channel = FlutterMethodChannel(name: "zangetsu/ios_pip", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(false); return }
      switch call.method {
      case "supported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "start":
        guard let args = call.arguments as? [String: Any],
              let id = args["textureId"] as? NSNumber else { result(false); return }
        start(texture: id.int64Value, playing: args["playing"] as? Bool ?? false, result: result)
      case "playing":
        playing = call.arguments as? Bool ?? false
        controller?.invalidatePlaybackState()
        result(nil)
      case "stop":
        stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(texture: Int64, playing: Bool, result: @escaping FlutterResult) {
    guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported(),
          let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let window = scene.windows.first(where: { $0.isKeyWindow }) else {
      result(false)
      return
    }
    let audio = AVAudioSession.sharedInstance()
    if audio.category != .playback {
      previousAudio = (audio.category, audio.mode, audio.categoryOptions)
      do {
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
      } catch {
        restoreAudio()
        result(false)
        return
      }
    }
    self.playing = playing
    pendingStart = result
    layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    window.layer.insertSublayer(layer, at: 0)
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer, playbackDelegate: self)
    let pip = AVPictureInPictureController(contentSource: source)
    pip.delegate = self
    controller = pip
    possible = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startWhenPossible() }
    }
    textures.observedTextureID = texture
    textures.onFrame = { [weak self] buffer in self?.enqueue(buffer) }
    textures.deliverCurrentFrame()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak pip] in
      guard let self, let pip, self.controller === pip, self.pendingStart != nil else { return }
      self.stop()
    }
  }

  private func startWhenPossible() {
    guard let controller, controller.isPictureInPicturePossible, possible != nil else { return }
    possible = nil
    controller.startPictureInPicture()
  }

  private func enqueue(_ input: CVPixelBuffer) {
    if layer.status == .failed { layer.flush() }
    guard layer.isReadyForMoreMediaData else { return }
    let width = CVPixelBufferGetWidth(input)
    let height = CVPixelBufferGetHeight(input)
    let pixelFormat = CVPixelBufferGetPixelFormatType(input)
    if sourceSize?.width != width || sourceSize?.height != height ||
        sourceSize?.format != pixelFormat {
      sourceSize = (width, height, pixelFormat)
      pool = nil
      format = nil
      layer.flush()
    }
    if pool == nil {
      let properties: [String: Any] = [
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      CVPixelBufferPoolCreate(nil, nil, properties as CFDictionary, &pool)
    }
    if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
    guard let pool, let transfer else { return }
    var output: CVPixelBuffer?
    let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output) == kCVReturnSuccess,
          let output, VTPixelTransferSessionTransferImage(transfer, from: input, to: output) == noErr else { return }
    if format == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: output, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output,
      formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    layer.enqueue(sample)
  }

  private func restoreAudio() {
    guard let previousAudio else { return }
    self.previousAudio = nil
    try? AVAudioSession.sharedInstance().setCategory(previousAudio.0,
      mode: previousAudio.1, options: previousAudio.2)
  }

  private func stop() {
    let current = controller
    controller = nil
    current?.delegate = nil
    if current?.isPictureInPictureActive == true { current?.stopPictureInPicture() }
    possible = nil
    textures.onFrame = nil
    textures.observedTextureID = 0
    layer.flushAndRemoveImage()
    layer.removeFromSuperlayer()
    pool = nil
    format = nil
    transfer = nil
    sourceSize = nil
    restoreAudio()
    let result = pendingStart
    pendingStart = nil
    result?(false)
    channel.invokeMethod("stopped", arguments: nil)
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
    guard controller === pip else { return }
    let result = pendingStart
    pendingStart = nil
    result?(true)
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) { if controller === pip { stop() } }

  func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
    guard controller === pip else { return }
    if UIApplication.shared.applicationState == .background {
      channel.invokeMethod("setPlaying", arguments: false)
    }
    stop()
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
    completion(controller === pip)
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController, setPlaying playing: Bool) {
    self.playing = playing
    channel.invokeMethod("setPlaying", arguments: playing)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pip: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pip: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  func pictureInPictureController(_ pip: AVPictureInPictureController, skipByInterval interval: CMTime,
    completion completionHandler: @escaping () -> Void) {
    channel.invokeMethod("skip", arguments: interval.seconds)
    completionHandler()
  }
}
