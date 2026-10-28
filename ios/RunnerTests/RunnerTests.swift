import Flutter
import UIKit
import XCTest
import Speech
@testable import Runner

class RunnerTests: XCTestCase {

  private class VoiceMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
    func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 1 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
  }

  func testVoiceCancelDuringAuthorizationIgnoresLateApproval() {
    var authorization: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
    let bridge = PhoneVoiceSearchBridge(
      messenger: VoiceMessenger(),
      authorizationStatus: { .notDetermined },
      authorizeSpeech: { authorization = $0 }
    )
    var completions = 0
    bridge.handle(FlutterMethodCall(methodName: "listen", arguments: ["sessionId": 1])) { _ in completions += 1 }
    XCTAssertNotNil(authorization)
    bridge.handle(FlutterMethodCall(methodName: "cancel", arguments: ["sessionId": 1])) { _ in }
    authorization?(.authorized)
    XCTAssertEqual(completions, 1)
  }

  func testVoiceDenialReturnsPermissionErrorWithoutRecording() {
    let bridge = PhoneVoiceSearchBridge(messenger: VoiceMessenger(), authorizationStatus: { .denied })
    var failure: FlutterError?
    bridge.handle(FlutterMethodCall(methodName: "listen", arguments: ["sessionId": 1])) { failure = $0 as? FlutterError }
    XCTAssertEqual(failure?.code, "voice_speech_permission")
  }

  func testVoiceWrongSessionCannotCancelAuthorization() {
    let bridge = PhoneVoiceSearchBridge(messenger: VoiceMessenger(), authorizationStatus: { .notDetermined }, authorizeSpeech: { _ in })
    var completions = 0
    bridge.handle(FlutterMethodCall(methodName: "listen", arguments: ["sessionId": 1])) { _ in completions += 1 }
    bridge.handle(FlutterMethodCall(methodName: "cancel", arguments: ["sessionId": 2])) { _ in }
    XCTAssertEqual(completions, 0)
    bridge.dispose()
    XCTAssertEqual(completions, 1)
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testCanonicalLanguageCodeMapsVisionTagsToCatalogCodes() {
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("ja-JP"), "ja")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("zh-Hans"), "zh")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("zh-Hant"), "zh")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("fil-PH"), "tl")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("jw-ID"), "jv")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("nb-NO"), "no")
    XCTAssertEqual(MangaTranslationBridge.canonicalLanguageCode("nn-NO"), "no")
    XCTAssertNil(MangaTranslationBridge.canonicalLanguageCode("xyz-ZZ"))
  }

  func testVisionBoundsConvertFromBottomLeftToTopLeftExactlyOnce() {
    let converted = MangaTranslationBridge.flutterBounds(
      fromVision: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    )

    XCTAssertEqual(converted.minX, 0.1, accuracy: 0.000001)
    XCTAssertEqual(converted.minY, 0.4, accuracy: 0.000001)
    XCTAssertEqual(converted.maxX, 0.4, accuracy: 0.000001)
    XCTAssertEqual(converted.maxY, 0.8, accuracy: 0.000001)
  }

}
