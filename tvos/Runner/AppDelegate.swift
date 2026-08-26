import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let flutterViewController = FlutterViewController(project: nil, nibName: nil, bundle: nil)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = flutterViewController
        window.makeKeyAndVisible()
        self.window = window

        GeneratedPluginRegistrant.register(with: self)
        Self.registerDeviceChannel(with: flutterViewController.binaryMessenger)
        Self.registerNovelHttp(with: flutterViewController.binaryMessenger)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
