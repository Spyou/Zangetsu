import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Novel-fetch channel: the iOS twin of Android's NovelHttp. The LNReader
    // plugin's HTTP goes through URLSession here instead of Dart's HTTP client,
    // because URLSession rides the system TLS stack (a Safari-like fingerprint)
    // that Cloudflare-gated novel hosts like webnovel.com let through — Dart's
    // fingerprint gets 403'd and no header block fixes that. Dart falls back to
    // its own request if this channel throws, so nothing regresses.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NovelHttp") {
      let channel = FlutterMethodChannel(
        name: "zangetsu/novel_http",
        binaryMessenger: registrar.messenger()
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

        // Default session: system cookie storage persists a session/CF cookie
        // between requests, mirroring the Android in-memory jar. HTTPS + follow
        // redirects are the URLSession defaults.
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
}
