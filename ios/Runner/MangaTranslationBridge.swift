import CoreGraphics
import Flutter
import Foundation
import ImageIO
import Vision

/// iOS OCR implementation for `AniAura/manga_translation`.
///
/// iOS keeps the app's iOS 15.0 deployment target and uses Vision for OCR.
/// Online translation remains in Dart; native iOS never sends text or image
/// data to a translation service.
internal final class MangaTranslationBridge {
  private static let channelName = "AniAura/manga_translation"
  private static let onlineEngine = "online"
  private static let offlineEngine = "offline"

  /// This mirrors `MangaTranslationLanguages.online` so a Vision language can
  /// only be exposed when the reader's translation picker understands it.
  private static let catalogLanguageCodes: Set<String> = [
    "af", "sq", "am", "ar", "hy", "az", "eu", "be", "bn", "bs", "bg", "ca", "ceb",
    "zh", "co", "hr", "cs", "da", "nl", "en", "eo", "et", "tl", "fi", "fr", "fy",
    "gl", "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is",
    "ig", "id", "ga", "it", "ja", "jv", "kn", "kk", "km", "rw", "ko", "ku", "ky",
    "lo", "la", "lv", "lt", "lb", "mk", "mg", "ms", "ml", "mt", "mi", "mr", "mn",
    "my", "ne", "no", "ny", "or", "ps", "fa", "pl", "pt", "pa", "ro", "ru", "sm",
    "gd", "sr", "st", "sn", "sd", "si", "sk", "sl", "so", "es", "su", "sw", "sv",
    "tg", "ta", "tt", "te", "th", "tr", "tk", "uk", "ur", "ug", "uz", "vi", "cy",
    "xh", "yi", "yo", "zu", "ace", "ach", "awa", "ban", "bem", "bho", "bik", "din",
    "doi", "dty", "fj", "gom", "ilo", "kha", "kri", "mai", "mak", "lus", "mni", "mos",
    "pap", "sa", "sat", "scn", "shn", "ti", "tum", "war",
  ]

  private static let supportedMethods: Set<String> = [
    "supportedOcrLanguages",
    "supportedOfflineLanguages",
    "modelStatus",
    "downloadModels",
    "recognize",
    "translateTexts",
  ]

  private let workQueue = DispatchQueue(
    label: "com.spyou.AniAura.manga-translation.ocr",
    qos: .userInitiated
  )

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Self.supportedMethods.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }

    workQueue.async {
      do {
        let response = try self.dispatch(call)
        DispatchQueue.main.async { result(response) }
      } catch let error as MangaTranslationBridgeFailure {
        DispatchQueue.main.async {
          result(FlutterError(code: error.code, message: error.message, details: error.details))
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "platform_error",
              message: error.localizedDescription,
              details: ["exception": String(describing: type(of: error))]
            )
          )
        }
      }
    }
  }

  private func dispatch(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "supportedOcrLanguages":
      return try Self.supportedOcrLanguageCodes()
    case "supportedOfflineLanguages":
      return [String]()
    case "modelStatus":
      return try modelStatus(arguments: call.arguments)
    case "downloadModels":
      // iOS has system-provided OCR but intentionally has no offline text
      // translation engine. Online translation is handled by Dart.
      throw MangaTranslationBridgeFailure(
        code: "unsupported_engine",
        message: "iOS supports online manga translation only; no local models are available."
      )
    case "recognize":
      return try recognize(arguments: call.arguments)
    case "translateTexts":
      // Do not create a second translation/network path on iOS.
      throw MangaTranslationBridgeFailure(
        code: "unsupported_engine",
        message: "Native text translation is unavailable on iOS."
      )
    default:
      return FlutterMethodNotImplemented
    }
  }

  private func modelStatus(arguments: Any?) throws -> [String: Bool] {
    let args = try Self.requiredArguments(arguments)
    let engine = try Self.requiredString("engine", from: args)
    guard engine == Self.onlineEngine || engine == Self.offlineEngine else {
      throw MangaTranslationBridgeFailure(
        code: "invalid_argument",
        message: "Unknown translation engine '\(engine)'."
      )
    }

    let onlineReady = engine == Self.onlineEngine
    return [
      "ocrReady": true,
      "sourceTranslationReady": onlineReady,
      "targetTranslationReady": onlineReady,
    ]
  }

  private func recognize(arguments: Any?) throws -> [String: Any] {
    let args = try Self.requiredArguments(arguments)
    let path = try Self.requiredString("filePath", from: args)
    let sourceLanguage = try Self.requiredString("sourceLanguage", from: args)
    guard let sourceCode = Self.canonicalLanguageCode(sourceLanguage) else {
      throw MangaTranslationBridgeFailure(
        code: "unsupported_source_language",
        message: "The selected OCR language '\(sourceLanguage)' is not in the manga language catalog."
      )
    }

    let fileURL = URL(fileURLWithPath: path)
    guard fileURL.isFileURL, FileManager.default.isReadableFile(atPath: fileURL.path),
          let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          CGImageSourceGetCount(imageSource) > 0,
          let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any],
          let rawWidth = (imageProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let rawHeight = (imageProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          rawWidth > 0, rawHeight > 0
    else {
      throw MangaTranslationBridgeFailure(
        code: "image_read_failed",
        message: "The local manga page image could not be read."
      )
    }

    let orientationValue =
      (imageProperties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    guard let orientation = CGImagePropertyOrientation(rawValue: orientationValue) else {
      throw MangaTranslationBridgeFailure(
        code: "image_read_failed",
        message: "The local manga page image has an invalid EXIF orientation."
      )
    }

    let visionLanguages = try Self.availableVisionLanguageTags()
    guard let recognitionLanguage = Self.visionLanguageTag(
      for: sourceCode,
      among: visionLanguages
    ) else {
      throw MangaTranslationBridgeFailure(
        code: "unsupported_source_language",
        message: "Vision does not provide OCR for '\(sourceLanguage)' on this iOS version."
      )
    }

    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequest.currentRevision
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [recognitionLanguage]
    let handler = VNImageRequestHandler(url: fileURL, orientation: orientation, options: [:])

    do {
      try handler.perform([request])
    } catch {
      throw MangaTranslationBridgeFailure(
        code: "ocr_failed",
        message: error.localizedDescription,
        details: ["exception": String(describing: type(of: error))]
      )
    }

    let (imageWidth, imageHeight) = Self.orientedDimensions(
      rawWidth: rawWidth,
      rawHeight: rawHeight,
      orientation: orientation
    )
    let regions = (request.results ?? []).compactMap { observation -> [String: Any]? in
      guard let candidate = observation.topCandidates(1).first,
            !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }

      let bounds = Self.flutterBounds(fromVision: observation.boundingBox)
      return [
        "text": candidate.string,
        "left": bounds.minX,
        "top": bounds.minY,
        "right": bounds.maxX,
        "bottom": bounds.maxY,
      ]
    }

    return [
      "imageWidth": imageWidth,
      "imageHeight": imageHeight,
      "regions": regions,
    ]
  }

  private static func supportedOcrLanguageCodes() throws -> [String] {
    let canonicalCodes = try availableVisionLanguageTags().compactMap(canonicalLanguageCode)
    return Array(Set(canonicalCodes)).sorted()
  }

  private static func availableVisionLanguageTags() throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequest.currentRevision
    request.recognitionLevel = .accurate
    do {
      return try request.supportedRecognitionLanguages()
    } catch {
      throw MangaTranslationBridgeFailure(
        code: "ocr_failed",
        message: "Vision OCR languages could not be queried: \(error.localizedDescription)",
        details: ["exception": String(describing: type(of: error))]
      )
    }
  }

  /// Converts a Vision BCP-47 identifier to the app's canonical language code.
  /// Unknown languages stay absent rather than leaking codes the Dart picker
  /// cannot translate.
  internal static func canonicalLanguageCode(_ languageTag: String) -> String? {
    let normalizedTag = languageTag.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
    guard let language = normalizedTag.split(separator: "-").first?.lowercased(),
          !language.isEmpty
    else {
      return nil
    }

    let canonical: String
    switch language {
    case "fil":
      canonical = "tl"
    case "jw":
      canonical = "jv"
    case "iw":
      canonical = "he"
    case "in":
      canonical = "id"
    case "ji":
      canonical = "yi"
    case "nb", "nn":
      canonical = "no"
    default:
      canonical = language
    }

    return catalogLanguageCodes.contains(canonical) ? canonical : nil
  }

  /// Changes only the origin. Vision normalized rectangles have a bottom-left
  /// origin; the Flutter image overlay expects a top-left origin.
  internal static func flutterBounds(fromVision bounds: CGRect) -> CGRect {
    CGRect(
      x: bounds.minX,
      y: 1 - bounds.maxY,
      width: bounds.width,
      height: bounds.height
    )
  }

  private static func visionLanguageTag(for code: String, among tags: [String]) -> String? {
    let matches = tags.filter { canonicalLanguageCode($0) == code }
    if code == "zh" {
      return matches.first {
        $0.replacingOccurrences(of: "_", with: "-")
          .localizedCaseInsensitiveContains("zh-Hans")
      } ?? matches.sorted().first
    }
    return matches.sorted().first
  }

  private static func orientedDimensions(
    rawWidth: Int,
    rawHeight: Int,
    orientation: CGImagePropertyOrientation
  ) -> (Int, Int) {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      return (rawHeight, rawWidth)
    default:
      return (rawWidth, rawHeight)
    }
  }

  private static func requiredArguments(_ arguments: Any?) throws -> [String: Any] {
    guard let args = arguments as? [String: Any] else {
      throw MangaTranslationBridgeFailure(
        code: "invalid_argument",
        message: "Method arguments must be a map."
      )
    }
    return args
  }

  private static func requiredString(_ key: String, from arguments: [String: Any]) throws -> String {
    guard let value = arguments[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MangaTranslationBridgeFailure(
        code: "invalid_argument",
        message: "Missing or invalid '\(key)' argument."
      )
    }
    return value
  }
}

private struct MangaTranslationBridgeFailure: Error {
  let code: String
  let message: String
  let details: Any?

  init(code: String, message: String, details: Any? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}
