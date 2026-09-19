import Foundation
import Flutter
import UIKit
import Security
import AVFoundation
import Darwin
#if os(iOS)
import ActivityKit
#endif

/// Shared by iOS and tvOS. Transport/authentication live in Dart; this bridge
/// owns Keychain, Bonjour and (on iPhone/iPad) camera presentation.
final class BetaAppleServices: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static var retained: BetaAppleServices?
    private var browser: NetServiceBrowser?
    private var published: NetService?
    private var services: [NetService] = []
    private var found: [[String: String]] = []
    private var discoveryResult: FlutterResult?
    private weak var presenter: UIViewController?
    private let player: ((String, [String: Any], @escaping FlutterResult) -> Void)?
    init(presenter: UIViewController?, player: ((String, [String: Any], @escaping FlutterResult) -> Void)?) {
        self.presenter = presenter; self.player = player
    }
    static func register(messenger: FlutterBinaryMessenger, presenter: UIViewController?,
                         player: ((String, [String: Any], @escaping FlutterResult) -> Void)? = nil) {
        let service = BetaAppleServices(presenter: presenter, player: player)
        retained = service
        let channel = FlutterMethodChannel(name: "zangetsu/apple_companion", binaryMessenger: messenger)
        channel.setMethodCallHandler { [service] call, result in service.handle(call, result) }
    }
    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "zangetsu.beta.companion", kSecAttrAccount as String: "pairing"]
    }
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "remoteSnapshot":
            #if os(iOS)
            if #available(iOS 16.2, *) {
                let state = call.arguments as? [String: Any] ?? [:]
                let active = state["active"] as? Bool == true && state["playerForeground"] as? Bool == true
                Task { @MainActor in
                    let existing = Activity<BetaRemoteActivityAttributes>.activities.first
                    if !active {
                        for activity in Activity<BetaRemoteActivityAttributes>.activities {
                            await activity.end(nil, dismissalPolicy: .immediate)
                        }
                    } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                        let snapshot = BetaRemoteActivityAttributes.ContentState(title: state["title"] as? String ?? "Zangetsu",
                            episode: state["episodeLabel"] as? String ?? "TV remote", playing: state["playing"] as? Bool == true)
                        let content = ActivityContent(state: snapshot, staleDate: Date().addingTimeInterval(120))
                        if let existing { await existing.update(content) }
                        else if UIApplication.shared.applicationState == .active {
                            _ = try? Activity.request(attributes: BetaRemoteActivityAttributes(name: "Zangetsu TV remote"), content: content, pushType: nil)
                        }
                    }
                }
            }
            #endif
            result(nil)
        case "readStore":
            var query = keyQuery
            query[kSecReturnData as String] = true
            var data: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &data)
            if status == errSecItemNotFound { result(nil) }
            else if status == errSecSuccess, let data = data as? Data { result(String(data: data, encoding: .utf8)) }
            else { result(FlutterError(code: "keychain", message: "Cannot read saved pairing (\(status)).", details: nil)) }
        case "writeStore":
            guard let value = call.arguments as? String, let data = value.data(using: .utf8) else {
                result(FlutterError(code: "arguments", message: "Pairing data required", details: nil)); return
            }
            let values: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(keyQuery as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(keyQuery.merging(values) { _, new in new } as CFDictionary, nil)
            }
            result(status == errSecSuccess ? nil : FlutterError(code: "keychain", message: "Cannot save pairing (\(status)).", details: nil))
        case "discover":
            guard discoveryResult == nil else { result(FlutterError(code: "busy", message: "Already looking for TVs", details: nil)); return }
            discoveryResult = result; found = []; services = []
            browser = NetServiceBrowser(); browser?.delegate = self
            browser?.searchForServices(ofType: "_zangetsubeta._tcp.", inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishDiscovery() }
        case "publish":
            guard let args = call.arguments as? [String: Any], let port = args["port"] as? Int else {
                result(FlutterError(code: "arguments", message: "Port required", details: nil)); return
            }
            published?.stop()
            let service = NetService(domain: "local.", type: "_zangetsubeta._tcp.", name: "Zangetsu Apple TV", port: Int32(port))
            if let id = args["deviceId"] as? String { service.setTXTRecord(NetService.data(fromTXTRecord: ["deviceId": Data(id.utf8)])) }
            published = service; service.publish(); result(nil)
        case "unpublish": published?.stop(); published = nil; result(nil)
        case "player", "stream":
            guard let player else { result(FlutterError(code: "unsupported", message: "Receiver mode requires Apple TV", details: nil)); return }
            player(call.method, call.arguments as? [String: Any] ?? [:], result)
        case "scanPairing":
            #if os(iOS)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard allowed else { result(FlutterError(code: "camera", message: "Allow camera access in Settings to scan the TV QR.", details: nil)); return }
                    let vc = self?.presenter ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
                    guard var host = vc else { result(FlutterError(code: "camera", message: "Open Zangetsu to scan", details: nil)); return }
                    while let next = host.presentedViewController { host = next }
                    host.present(BetaQRScanner(result: result), animated: true)
                }
            }
            #else
            result(FlutterError(code: "unsupported", message: "Scan the TV using your phone", details: nil))
            #endif
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func finishDiscovery() {
        browser?.stop(); browser = nil
        services.forEach { $0.stop() }; services = []
        let done = discoveryResult; discoveryResult = nil; done?(found)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { finishDiscovery() }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard discoveryResult != nil else { return }
        for address in sender.addresses ?? [] {
            let host: String? = address.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var ip = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: text)
            }
            if let host, !found.contains(where: { $0["address"] == "\(host):\(sender.port)" }) {
                found.append(["name": sender.name, "address": "\(host):\(sender.port)"])
            }
        }
    }
}

#if os(iOS)
private final class BetaQRScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate, UIAdaptivePresentationControllerDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "zangetsu.qr.camera")
    private var result: FlutterResult?
    private var preview: AVCaptureVideoPreviewLayer?
    init(result: @escaping FlutterResult) { self.result = result; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        presentationController?.delegate = self
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal); cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(cancel)
        NSLayoutConstraint.activate([cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        queue.async { [weak self] in
            guard let self, let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                DispatchQueue.main.async { self?.finish(FlutterError(code: "camera", message: "Camera unavailable", details: nil)) }; return
            }
            self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else { DispatchQueue.main.async { self.finish(nil) }; return }
            self.session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill; layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0); self.preview = layer
            }
            self.session.startRunning()
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); queue.async { [session] in session.stopRunning() } }
    @objc private func cancelScan() { finish(nil) }
    private func finish(_ value: Any?) { guard let done = result else { return }; result = nil; dismiss(animated: true); done(value) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { let done = result; result = nil; done?(nil) }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let raw = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              let url = URL(string: raw), url.scheme == "zangetsu-beta", url.host == "remote" else { return }
        finish(raw)
    }
}
#endif
