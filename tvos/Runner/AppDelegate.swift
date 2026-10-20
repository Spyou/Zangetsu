import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private var tvPlayerChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let messenger = engineBridge.applicationRegistrar.messenger()
        Self.registerDeviceChannel(with: messenger)
        Self.registerNovelHttp(with: messenger)
        registerTvPlayerChannel(with: messenger)
        // Register on the implicit engine's messenger so companion requests
        // reach the same player as upstream's scene-managed Flutter window.
        AppleCompanionServices.register(messenger: messenger, presenter: nil) { method, args, result in
            if method == "stream" {
                result(TvSystemPlayerViewController.active?.companionStream() ?? [:])
                return
            }
            if let player = TvSystemPlayerViewController.active {
                player.companionCommand(args, result: result)
            } else if args["action"] as? String == "state" {
                result(["active": false, "appForeground": UIApplication.shared.applicationState == .active,
                        "playerForeground": false, "systemControls": false, "qualitySelection": false, "volumeAvailable": false])
            } else if args["action"] as? String == "skipSettings" {
                result(nil)
            } else {
                result(FlutterError(code: "player", message: "Start playback on Apple TV first", details: nil))
            }
        }
    }

    /// Bidirectional bridge for the native AVKit player.
    /// Dart→native: `launch`, `setFillerInfo`. Native→Dart uses the same
    /// channel via `invokeMethod` (resolveEpisode / saveProgress / …).
    private func registerTvPlayerChannel(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "zangetsu/tv_player",
            binaryMessenger: messenger
        )
        tvPlayerChannel = channel
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "launch":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "bad_args", message: "map required", details: nil))
                    return
                }
                guard let flutterVC = Self.flutterViewController() else {
                    result(FlutterError(code: "no_vc", message: "Flutter VC gone", details: nil))
                    return
                }
                if TvSystemPlayerViewController.active != nil {
                    result(FlutterError(code: "busy", message: "player already open", details: nil))
                    return
                }
                let player = TvSystemPlayerViewController(
                    channel: channel, args: args, result: result
                )
                player.modalPresentationStyle = .fullScreen
                flutterVC.present(player, animated: true)
            case "setFillerInfo":
                let flags = (call.arguments as? [String: Any])?["fillerFlags"] as? [Bool]
                    ?? ((call.arguments as? [String: Any])?["fillerFlags"] as? [NSNumber])?.map(\.boolValue)
                let auto = (call.arguments as? [String: Any])?["autoSkipFiller"] as? Bool
                TvSystemPlayerViewController.active?.applyFillerInfo(flags: flags, autoSkip: auto)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func flutterViewController() -> FlutterViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { $0.rootViewController as? FlutterViewController }
            .first
    }

    /// Same channel Android uses for leanback detection. Always true here —
    /// this binary only ships on Apple TV.
    private static func registerDeviceChannel(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.spyou.watch_app/device",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "isTv":
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// tvOS twin of iOS NovelHttp: LNReader plugin HTTP goes through URLSession
    /// so Cloudflare-gated hosts see a Safari-like TLS fingerprint. Dart falls
    /// back to Dio if this channel throws.
    private static func registerNovelHttp(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "zangetsu/novel_http",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            guard call.method == "request" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let urlStr = args["url"] as? String,
                  let url = URL(string: urlStr) else {
                result(FlutterError(code: "bad_args", message: "url required", details: nil))
                return
            }
            let method = (args["method"] as? String ?? "GET").uppercased()
            let headers = args["headers"] as? [String: String] ?? [:]
            let body = args["body"] as? String

            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = method
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let body = body { req.httpBody = body.data(using: .utf8) }

            let task = URLSession.shared.dataTask(with: req) { data, response, error in
                if let error = error {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "novel_http_failed",
                                            message: error.localizedDescription, details: nil))
                    }
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let finalUrl = http?.url?.absoluteString ?? urlStr
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    result(["status": status, "body": bodyStr, "url": finalUrl])
                }
            }
            task.resume()
        }
    }
}
