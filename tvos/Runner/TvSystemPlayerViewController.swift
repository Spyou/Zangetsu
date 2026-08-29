import AVFoundation
import AVKit
import CoreText
import Flutter
import UIKit

/// AVKit-based Apple TV player: stock transport chrome plus Zangetsu hooks
/// (`transportBarCustomMenuItems`, `contextualActions`, Episodes tab,
/// Up Next content proposal). See Apple's "Customizing the tvOS Playback Experience".
final class TvSystemPlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    static weak var active: TvSystemPlayerViewController?

    private var channel: FlutterMethodChannel!
    private var launchResult: FlutterResult?
    private var pendingArgs: [String: Any]?
    private var finished = false

    // Session
    private var episodeIndex = 0
    private var episodeCount = 1
    private var episodeLabels: [String] = []
    private var titleText = ""
    private var episodeLabelText = ""
    private var category = "sub"
    private var availableCategories: [String] = []
    private var currentSpeed: Float = 1
    private var headers: [String: String] = [:]
    private var subtitles: [[String: String]] = []
    /// Pack skew already baked into fetched cue text (or 0).
    private var providerSubtitleSkewApplied = false
    private var megaSkip = true
    private var megaSkipSeconds = 85
    private var skipIntro = true
    private var autoSkipOp = false
    private var autoSkipEd = false
    private var autoSkipRecap = false
    private var autoSkipFiller = false
    private var fillerFlags: [Bool] = []
    private var skipIntervals: [(start: Int64, end: Int64, type: String)] = []
    private var autoSkippedStarts: Set<Int64> = []

    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var saveTimer: Timer?
    private var endObserver: NSObjectProtocol?
    private var episodesTab: TvEpisodesInfoViewController?
    private var cachedSources: [[String: Any]] = []
    private var lastContextualKey: String?
    private var captionCues: [(start: Double, end: Double, text: String)] = []
    private var selectedSubtitleKey: String = "off"
    private let captionHost = UIView()
    private let captionBubble = UIView()
    private let captionLabel = UILabel()
    private var embeddedLegibleOptions: [(label: String, option: AVMediaSelectionOption)] = []
    private var captionOverlayInstalled = false
    private var lastCaptionDiagAt: TimeInterval = 0
    /// Dedicated window above AVKit's video plane (contentOverlayView is unreliable on tvOS).
    private var captionWindow: UIWindow?
    /// While `Date() < captionStatusUntil`, keep the toast; afterwards always clear/replace.
    private var captionStatusUntil: Date?
    private var captionBottomConstraint: NSLayoutConstraint?
    /// App Captions Styling (PlaybackPrefs) — not system Accessibility.
    private var captionScale: Double = 1.0
    private var captionColorHex: String = "#FFFFFFFF"
    private var captionBgOpacity: Double = 0.0
    private var captionOutlineType: String = "outline"
    private var captionFontFamily: String = ""
    private var captionFontPath: String?
    private var captionPositionPref: Int = 95
    private var captionFont: UIFont = .systemFont(ofSize: 36, weight: .semibold)
    private var captionFgColor: UIColor = .white

    // Subtitle timing debug (`[zangetsu-sub-timing]` in Xcode console).
    private var lastActiveCueIndex: Int?
    private var lastPlaybackT: Double = -1
    private var lastSubTimingHeartbeatAt: TimeInterval = 0
    /// Positive = show captions later (user fine-tune on top of media epoch).
    private var captionDelaySeconds: Double = 0
    /// True when the active stream is HLS — sideloaded VTTs need media-epoch mapping.
    private var streamIsHls = false
    private var streamURL: URL?
    /// First-segment media time in seconds, probed from the playlist. Nil until known.
    private var probedHlsEpochSeconds: Double?
    private var pendingCueText: String?
    /// Last VTT body so a late native/Dart epoch can re-map cues.
    private var lastCueSourceText: String?
    private var appliedVttOffset: Double = 0
    private var lastSubtitleURL: URL?
    private var probedVttEncodeSkew = false

    convenience init(
        channel: FlutterMethodChannel,
        args: [String: Any],
        result: @escaping FlutterResult
    ) {
        self.init(nibName: nil, bundle: nil)
        self.channel = channel
        self.launchResult = result
        pendingArgs = args
        parseSession(args)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        TvSystemPlayerViewController.active = self
        showsPlaybackControls = true
        delegate = self
        transportBarIncludesTitleView = true
        // Caption overlay is installed lazily when a track is selected.
        if let args = pendingArgs {
            pendingArgs = nil
            installEpisodesTab()
            rebuildTransportMenus()
            loadStream(
                url: args["url"] as? String,
                positionMs: (args["positionMs"] as? NSNumber)?.int64Value ?? 0,
                episodeLabel: args["episodeLabel"] as? String ?? episodeLabelText
            )
            startSaveLoop()
            refreshSourcesCache()
        }
    }

    private func captionParentView() -> UIView {
        ensureCaptionWindow()
        return captionWindow?.rootViewController?.view ?? contentOverlayView ?? view
    }

    private func ensureCaptionWindow() {
        if let existing = captionWindow {
            existing.isHidden = false
            return
        }
        let scene = view.window?.windowScene
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let w: UIWindow
        if let scene {
            w = UIWindow(windowScene: scene)
        } else {
            w = UIWindow(frame: UIScreen.main.bounds)
        }
        w.frame = UIScreen.main.bounds
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        w.rootViewController = root
        // Show without becoming key — avoids stealing Siri Remote focus from AVKit.
        w.isHidden = false
        captionWindow = w
    }

    private func tearDownCaptionWindow() {
        captionHost.removeFromSuperview()
        captionOverlayInstalled = false
        captionWindow?.isHidden = true
        captionWindow = nil
    }

    private func installCaptionOverlay() {
        let parent = captionParentView()
        if captionHost.superview !== parent {
            captionHost.removeFromSuperview()
            captionOverlayInstalled = false
        }
        guard !captionOverlayInstalled else {
            parent.bringSubviewToFront(captionHost)
            return
        }
        captionOverlayInstalled = true
        captionHost.isUserInteractionEnabled = false
        captionHost.backgroundColor = .clear
        captionHost.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(captionHost)
        NSLayoutConstraint.activate([
            captionHost.topAnchor.constraint(equalTo: parent.topAnchor),
            captionHost.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            captionHost.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            captionHost.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])

        if captionBubble.superview == nil {
            captionBubble.translatesAutoresizingMaskIntoConstraints = false
            captionBubble.isUserInteractionEnabled = false
            captionBubble.layer.cornerRadius = 10
            captionBubble.clipsToBounds = true
            captionBubble.isHidden = true
            captionHost.addSubview(captionBubble)

            captionLabel.translatesAutoresizingMaskIntoConstraints = false
            captionLabel.textAlignment = .center
            captionLabel.numberOfLines = 4
            captionLabel.isUserInteractionEnabled = false
            captionBubble.addSubview(captionLabel)

            NSLayoutConstraint.activate([
                captionBubble.centerXAnchor.constraint(equalTo: captionHost.centerXAnchor),
                captionBubble.leadingAnchor.constraint(
                    greaterThanOrEqualTo: captionHost.leadingAnchor, constant: 80
                ),
                captionBubble.trailingAnchor.constraint(
                    lessThanOrEqualTo: captionHost.trailingAnchor, constant: -80
                ),
                captionLabel.topAnchor.constraint(equalTo: captionBubble.topAnchor, constant: 10),
                captionLabel.bottomAnchor.constraint(equalTo: captionBubble.bottomAnchor, constant: -10),
                captionLabel.leadingAnchor.constraint(equalTo: captionBubble.leadingAnchor, constant: 22),
                captionLabel.trailingAnchor.constraint(equalTo: captionBubble.trailingAnchor, constant: -22),
            ])
            let bottom = captionBubble.bottomAnchor.constraint(
                equalTo: captionHost.safeAreaLayoutGuide.bottomAnchor, constant: -48
            )
            bottom.isActive = true
            captionBottomConstraint = bottom
        }
        applyCaptionAppearance()
        parent.bringSubviewToFront(captionHost)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard captionWindow != nil else { return }
        installCaptionOverlay()
        updateCaptionPosition()
        captionWindow?.rootViewController?.view.bringSubviewToFront(captionHost)
    }

    /// Apply Zangetsu Captions Styling (PlaybackPrefs) to the overlay.
    private func applyCaptionAppearance() {
        let size = max(18, 36 * CGFloat(max(0.5, captionScale)))
        captionFont = Self.resolveFont(
            family: captionFontFamily,
            path: captionFontPath,
            size: size
        )
        captionFgColor = Self.color(hex: captionColorHex) ?? .white
        captionLabel.font = captionFont
        captionLabel.textColor = captionFgColor

        let bgA = max(0, min(1, captionBgOpacity))
        if bgA > 0.02 {
            captionBubble.backgroundColor = UIColor.black.withAlphaComponent(bgA)
            captionBubble.layer.cornerRadius = 8
        } else {
            captionBubble.backgroundColor = .clear
            captionBubble.layer.cornerRadius = 0
        }
        updateCaptionPosition()

        if !captionBubble.isHidden,
           let text = captionLabel.attributedText?.string ?? captionLabel.text,
           !text.isEmpty {
            setCaptionText(text)
        }
    }

    private func updateCaptionPosition() {
        let h = max(captionHost.bounds.height, view.bounds.height, UIScreen.main.bounds.height)
        let t = CGFloat(max(0, min(100, captionPositionPref))) / 100.0
        // 100 ≈ near bottom; 0 ≈ upper third.
        captionBottomConstraint?.constant = -((1 - t) * (h * 0.55) + 36)
    }

    private static func resolveFont(family: String, path: String?, size: CGFloat) -> UIFont {
        if let path, !path.isEmpty,
           let data = NSData(contentsOfFile: path) as CFData?,
           let provider = CGDataProvider(data: data),
           let cgFont = CGFont(provider) {
            var err: Unmanaged<CFError>?
            CTFontManagerRegisterGraphicsFont(cgFont, &err)
            if let ps = cgFont.postScriptName as String?,
               let font = UIFont(name: ps, size: size) {
                return font
            }
        }
        if !family.isEmpty {
            let candidates = [family, "\(family)-Regular", family.replacingOccurrences(of: " ", with: "")]
            for name in candidates {
                if let font = UIFont(name: name, size: size) { return font }
            }
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    private static func color(hex: String) -> UIColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 6 { h += "FF" }
        guard h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((v >> 24) & 0xFF) / 255
        let g = CGFloat((v >> 16) & 0xFF) / 255
        let b = CGFloat((v >> 8) & 0xFF) / 255
        let a = CGFloat(v & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Build attributed caption text from app outline prefs.
    private func makeCaptionAttributed(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: captionFgColor,
            .paragraphStyle: para,
        ]

        captionLabel.layer.shadowOpacity = 0
        captionLabel.layer.shadowRadius = 0
        captionLabel.layer.shadowOffset = .zero
        captionLabel.layer.shadowColor = UIColor.black.cgColor

        switch captionOutlineType {
        case "none":
            break
        case "shadow":
            captionLabel.layer.shadowOpacity = 0.95
            captionLabel.layer.shadowRadius = 3
            captionLabel.layer.shadowOffset = CGSize(width: 1.5, height: 1.5)
        case "raised":
            captionLabel.layer.shadowOpacity = 0.9
            captionLabel.layer.shadowRadius = 0.5
            captionLabel.layer.shadowOffset = CGSize(width: -1.5, height: -1.5)
        case "depressed":
            captionLabel.layer.shadowOpacity = 0.9
            captionLabel.layer.shadowRadius = 0.5
            captionLabel.layer.shadowOffset = CGSize(width: 1.5, height: 1.5)
        case "outline", "soft", "glow", "bold":
            fallthrough
        default:
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -4.0
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            finishIfNeeded()
        }
    }

    deinit {
        tearDownObservers()
        tearDownCaptionWindow()
        saveTimer?.invalidate()
        if TvSystemPlayerViewController.active === self {
            TvSystemPlayerViewController.active = nil
        }
    }

    func applyFillerInfo(flags: [Bool]?, autoSkip: Bool?) {
        if let flags { fillerFlags = flags }
        if let autoSkip { autoSkipFiller = autoSkip }
        rebuildTransportMenus()
    }

    // MARK: - Session / load

    private func parseSession(_ args: [String: Any]) {
        titleText = args["title"] as? String ?? ""
        episodeIndex = (args["startIndex"] as? NSNumber)?.intValue ?? 0
        episodeCount = (args["episodeCount"] as? NSNumber)?.intValue ?? 1
        episodeLabels = args["episodeLabels"] as? [String] ?? []
        episodeLabelText = args["episodeLabel"] as? String
            ?? (episodeIndex < episodeLabels.count ? episodeLabels[episodeIndex] : "Episode \(episodeIndex + 1)")
        category = args["category"] as? String ?? "sub"
        availableCategories = args["availableCategories"] as? [String] ?? []
        currentSpeed = Float((args["defaultSpeed"] as? NSNumber)?.doubleValue ?? 1)
        megaSkip = args["megaSkip"] as? Bool ?? true
        megaSkipSeconds = (args["megaSkipSeconds"] as? NSNumber)?.intValue ?? 85
        skipIntro = args["skipIntro"] as? Bool ?? true
        autoSkipOp = args["autoSkipOp"] as? Bool ?? false
        autoSkipEd = args["autoSkipEd"] as? Bool ?? false
        autoSkipRecap = args["autoSkipRecap"] as? Bool ?? false
        autoSkipFiller = args["autoSkipFiller"] as? Bool ?? false
        if let flags = args["fillerFlags"] as? [Bool] {
            fillerFlags = flags
        } else if let flags = args["fillerFlags"] as? [NSNumber] {
            fillerFlags = flags.map(\.boolValue)
        }
        headers = Self.parseHeaders(args["headers"])
        if let subs = args["subtitles"] as? [[String: String]] {
            subtitles = subs
        } else if let subs = args["subtitles"] as? [[String: Any]] {
            subtitles = subs.map { row in
                var out: [String: String] = [:]
                for (k, v) in row { out[k] = "\(v)" }
                return out
            }
        }
        if let n = args["subtitleDelaySeconds"] as? NSNumber {
            captionDelaySeconds = max(-60, min(60, n.doubleValue))
        }
        if let n = args["subtitleScale"] as? NSNumber {
            captionScale = max(0.5, min(2.5, n.doubleValue))
        }
        if let hex = args["subtitleColorHex"] as? String, !hex.isEmpty {
            captionColorHex = hex
        }
        if let n = args["subtitleBgOpacity"] as? NSNumber {
            captionBgOpacity = max(0, min(1, n.doubleValue))
        }
        if let t = args["subtitleOutlineType"] as? String, !t.isEmpty {
            captionOutlineType = t
        }
        if let f = args["subtitleFontFamily"] as? String {
            captionFontFamily = f
        }
        if let p = args["subtitleFontPath"] as? String, !p.isEmpty {
            captionFontPath = p
        }
        if let n = args["subtitlePositionPref"] as? NSNumber {
            captionPositionPref = max(0, min(100, n.intValue))
        }
        let skew = (args["subtitleSkewSeconds"] as? NSNumber)?.doubleValue ?? 0
        providerSubtitleSkewApplied = abs(skew) >= 0.05
        if providerSubtitleSkewApplied {
            logSubtitleTiming(
                "provider pack skew \(Self.fmtDelta(skew)) " +
                "(baked into cue text on fetch; skip encode-skew probe)"
            )
        }
    }

    private static func parseHeaders(_ raw: Any?) -> [String: String] {
        if let h = raw as? [String: String] { return h }
        if let h = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in h { out[k] = "\(v)" }
            return out
        }
        return [:]
    }

    private func loadStream(url: String?, positionMs: Int64, episodeLabel: String) {
        guard let urlStr = url, let u = URL(string: urlStr) else {
            finishIfNeeded(error: "Invalid stream URL")
            return
        }
        episodeLabelText = episodeLabel
        tearDownObservers()
        skipIntervals = []
        autoSkippedStarts = []
        lastContextualKey = nil
        contextualActions = []
        captionCues = []
        if captionWindow != nil {
            setCaptionText(nil)
        } else {
            captionLabel.text = nil
            captionBubble.isHidden = true
        }
        lastActiveCueIndex = nil
        lastPlaybackT = -1
        selectedSubtitleKey = "off"
        embeddedLegibleOptions = []
        streamURL = u
        probedHlsEpochSeconds = nil
        pendingCueText = nil
        lastCueSourceText = nil
        appliedVttOffset = 0
        lastSubtitleURL = nil
        probedVttEncodeSkew = false
        streamIsHls = urlStr.lowercased().contains(".m3u8")
        logSubtitleTiming(
            "loadStream hls=\(streamIsHls) posMs=\(positionMs) subs=\(subtitles.count) " +
            "delay=\(Self.fmtDelta(captionDelaySeconds)) \(u.absoluteString)"
        )
        if abs(captionDelaySeconds) > 0.05 {
            logSubtitleTiming(
                "MANUAL DELAY \(Self.fmtDelta(captionDelaySeconds)) from Settings " +
                "(global subtitleDelaySeconds). lookup=playerTime-delay, separate from auto probe. " +
                "Set Delay to 0 before judging auto-sync."
            )
        }
        for (i, row) in subtitles.enumerated() {
            logSubtitleTiming(
                "catalogSub[\(i)] label=\(row["label"] ?? "-") lang=\(row["lang"] ?? "-") " +
                "fmt=\(row["format"] ?? "-") url=\(row["url"] ?? "-")"
            )
        }
        if streamIsHls {
            probeHlsMediaEpoch(playlist: u)
        }

        let opts = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: u, options: opts)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = makeMetadata(title: titleText, subtitle: episodeLabel)

        let av = player ?? AVPlayer()
        // Manual menu picks must stick — automatic criteria otherwise reverts them.
        av.appliesMediaSelectionCriteriaAutomatically = false
        player = av
        av.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self.refreshEmbeddedLegibleOptions()
                    self.rebuildTransportMenus()
                    self.logPlayerTimelineDiagnostics(item, label: "ready")
                    self.probeEpochFromPlayerItem(item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        guard let self, let late = self.player?.currentItem else { return }
                        self.logPlayerTimelineDiagnostics(late, label: "t+2.5s")
                        self.probeEpochFromPlayerItem(late)
                    }
                    let play: () -> Void = {
                        av.playImmediately(atRate: self.currentSpeed)
                        self.fetchSkips()
                        self.refreshContentProposal()
                    }
                    if positionMs > 0 {
                        let t = CMTime(value: positionMs, timescale: 1000)
                        av.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in play() }
                    } else {
                        play()
                    }
                } else if item.status == .failed {
                    let msg = item.error?.localizedDescription ?? "Playback failed"
                    NSLog("[zangetsu-av-system] item failed: %@", msg)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded()
        }

        if timeObserver == nil {
            let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
            timeObserver = av.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
                [weak self] t in
                self?.onTick(t)
            }
        }

        episodesTab?.highlight(index: episodeIndex)
        rebuildTransportMenus()
    }

    private func makeMetadata(title: String, subtitle: String) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as? AVMetadataItem
        }
        return [
            item(.commonIdentifierTitle, title),
            item(.iTunesMetadataTrackSubTitle, subtitle),
        ].compactMap { $0 }
    }

    private func tearDownObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: - Transport menus

    private func rebuildTransportMenus() {
        var items: [UIMenuElement] = []

        // Next episode — leftmost in the transport icon row.
        if episodeIndex < episodeCount - 1 {
            items.append(UIAction(
                title: "Next Episode",
                image: UIImage(systemName: "forward.end.fill")
            ) { [weak self] _ in
                self?.playNext()
            })
        }

        // Speed
        let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        let speedChildren: [UIAction] = speeds.map { s in
            let title = abs(s - 1) < 0.001 ? "Normal" : String(format: "%g×", s)
            return UIAction(
                title: title,
                state: abs(currentSpeed - s) < 0.01 ? .on : .off
            ) { [weak self] _ in
                self?.applySpeed(s)
            }
        }
        items.append(UIMenu(
            title: "Speed",
            image: UIImage(systemName: "gauge.with.dots.needle.67percent"),
            options: [.singleSelection],
            children: speedChildren
        ))

        // Audio / Sources / Subs
        if let audio = buildAudioMenu() {
            items.append(audio)
        }
        if let sources = buildSourcesMenu() {
            items.append(sources)
        }

        // Subtitles (embedded + provider + online)
        items.append(buildSubtitlesMenu())

        // MegaSkip as a stable transport action (not contextual — that glitched).
        if megaSkip {
            let secs = megaSkipSeconds
            items.append(UIAction(
                title: "+\(secs)s",
                image: UIImage(systemName: "goforward")
            ) { [weak self] _ in
                self?.seekBy(Int64(secs) * 1000)
            })
        }

        transportBarCustomMenuItems = items
    }

    private func buildAudioMenu() -> UIMenu? {
        guard !availableCategories.isEmpty else { return nil }
        let catActions: [UIAction] = availableCategories.map { cat in
            let name = cat == "dub" ? "Dub" : (cat == "sub" ? "Sub" : cat)
            return UIAction(
                title: name,
                state: cat == category ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.category = cat
                self.channel.invokeMethod("setCategory", arguments: ["category": cat])
                self.resolveAndPlay(index: self.episodeIndex, forceReload: true)
            }
        }
        return UIMenu(
            title: "Audio",
            image: UIImage(systemName: "speaker.wave.2"),
            options: [.singleSelection],
            children: catActions
        )
    }

    private func buildSourcesMenu() -> UIMenu? {
        if !cachedSources.isEmpty {
            let srcActions: [UIAction] = cachedSources.enumerated().map { i, src in
                let label = (src["label"] as? String)
                    ?? (src["quality"] as? String)
                    ?? "Server \(i + 1)"
                let url = src["url"] as? String
                let currentUrl = (player?.currentItem?.asset as? AVURLAsset)?.url.absoluteString
                let selected = url != nil && url == currentUrl
                return UIAction(title: label, state: selected ? .on : .off) { [weak self] _ in
                    self?.playSource(src)
                }
            }
            return UIMenu(
                title: "Sources",
                image: UIImage(systemName: "rectangle.stack"),
                children: srcActions
            )
        }
        return UIMenu(
            title: "Sources",
            image: UIImage(systemName: "rectangle.stack"),
            children: [
                UIAction(title: "Refresh sources") { [weak self] _ in
                    self?.refreshSourcesCache(rebuildMenus: true)
                },
            ]
        )
    }

    private func buildSubtitlesMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        children.append(buildCaptionStyleMenu())
        children.append(buildCaptionDelayMenu())
        children.append(UIAction(
            title: "Off",
            state: selectedSubtitleKey == "off" ? .on : .off
        ) { [weak self] _ in
            self?.clearSubtitles()
        })

        for (i, pair) in embeddedLegibleOptions.enumerated() {
            let key = "embed:\(i)"
            children.append(UIAction(
                title: pair.label,
                state: selectedSubtitleKey == key ? .on : .off
            ) { [weak self] _ in
                self?.selectEmbeddedSubtitle(index: i)
            })
        }

        for (i, s) in subtitles.enumerated() {
            let label = s["label"] ?? s["lang"] ?? "Track \(i + 1)"
            let key = "provider:\(i)"
            children.append(UIAction(
                title: label,
                state: selectedSubtitleKey == key ? .on : .off
            ) { [weak self] _ in
                self?.applyProviderSubtitle(s, key: key)
            })
        }

        children.append(UIAction(title: "Search online…") { [weak self] _ in
            self?.searchOnlineSubtitles()
        })
        return UIMenu(
            title: "Subtitles",
            image: UIImage(systemName: "captions.bubble"),
            children: children
        )
    }

    /// Nested Caption style menus (Size / Color / Edge / …).
    private func buildCaptionStyleMenu() -> UIMenu {
        func nearestSizeLabel() -> String {
            Self.nearestLabel(in: Self.captionSizes.map { ($0.0, $0.1) }, value: captionScale)
        }
        func nearestBgLabel() -> String {
            Self.nearestLabel(in: Self.captionBackgrounds.map { ($0.0, $0.1) }, value: captionBgOpacity)
        }
        func nearestPosLabel() -> String {
            Self.nearestLabel(
                in: Self.captionPositions.map { ($0.0, Double($0.1)) },
                value: Double(captionPositionPref)
            )
        }
        let colorLabel = Self.captionColors.first {
            $0.1.caseInsensitiveCompare(captionColorHex) == .orderedSame
        }?.0 ?? "Custom"
        let edgeId = ["soft", "glow", "bold"].contains(captionOutlineType)
            ? "outline"
            : captionOutlineType
        let edgeLabel = Self.captionEdges.first { $0.1 == edgeId }?.0 ?? "Outline"
        let fontLabel = captionFontFamily.isEmpty ? "Default" : captionFontFamily

        let sizeMenu = UIMenu(
            title: "Size",
            subtitle: nearestSizeLabel(),
            options: [.singleSelection],
            children: Self.captionSizes.map { label, scale in
                UIAction(
                    title: label,
                    state: nearestSizeLabel() == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionScale(scale)
                }
            }
        )
        let colorMenu = UIMenu(
            title: "Color",
            subtitle: colorLabel,
            options: [.singleSelection],
            children: Self.captionColors.map { label, hex in
                UIAction(
                    title: label,
                    state: colorLabel == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionColorHex(hex)
                }
            }
        )
        let edgeMenu = UIMenu(
            title: "Edge",
            subtitle: edgeLabel,
            options: [.singleSelection],
            children: Self.captionEdges.map { label, id in
                UIAction(
                    title: label,
                    state: edgeLabel == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionOutlineType(id)
                }
            }
        )
        let bgMenu = UIMenu(
            title: "Background",
            subtitle: nearestBgLabel(),
            options: [.singleSelection],
            children: Self.captionBackgrounds.map { label, opacity in
                UIAction(
                    title: label,
                    state: nearestBgLabel() == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionBgOpacity(opacity)
                }
            }
        )
        let fontMenu = UIMenu(
            title: "Font",
            subtitle: fontLabel,
            options: [.singleSelection],
            children: Self.captionFonts.map { label, family in
                UIAction(
                    title: label,
                    state: fontLabel == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionFontFamily(family)
                }
            }
        )
        let posMenu = UIMenu(
            title: "Position",
            subtitle: nearestPosLabel(),
            options: [.singleSelection],
            children: Self.captionPositions.map { label, pos in
                UIAction(
                    title: label,
                    state: nearestPosLabel() == label ? .on : .off
                ) { [weak self] _ in
                    self?.setCaptionPosition(pos)
                }
            }
        )

        return UIMenu(
            title: "Caption style",
            image: UIImage(systemName: "textformat"),
            children: [sizeMenu, colorMenu, edgeMenu, bgMenu, fontMenu, posMenu]
        )
    }

    private static let captionSizes: [(String, Double)] = [
        ("Small", 0.8), ("Medium", 1.0), ("Large", 1.3),
    ]
    private static let captionColors: [(String, String)] = [
        ("White", "#FFFFFFFF"),
        ("Yellow", "#FFFF00FF"),
        ("Cyan", "#00E5FFFF"),
        ("Green", "#7CFC00FF"),
        ("Red", "#FF6B6BFF"),
        ("Black", "#000000FF"),
    ]
    private static let captionEdges: [(String, String)] = [
        ("None", "none"),
        ("Outline", "outline"),
        ("Drop Shadow", "shadow"),
        ("Raised", "raised"),
        ("Depressed", "depressed"),
    ]
    private static let captionBackgrounds: [(String, Double)] = [
        ("Off", 0.0), ("Light", 0.25), ("Medium", 0.5), ("Strong", 0.75),
    ]
    private static let captionFonts: [(String, String)] = [
        ("Default", ""),
        ("Inter", "Inter"),
        ("Poppins", "Poppins"),
        ("Roboto", "Roboto"),
        ("Open Sans", "Open Sans"),
        ("Lato", "Lato"),
        ("Montserrat", "Montserrat"),
        ("Nunito", "Nunito"),
        ("Rubik", "Rubik"),
        ("Noto Sans", "Noto Sans"),
        ("Source Sans 3", "Source Sans 3"),
    ]
    private static let captionPositions: [(String, Int)] = [
        ("Low", 95), ("Middle", 70), ("High", 40),
    ]

    private static func nearestLabel(in options: [(String, Double)], value: Double) -> String {
        options.min(by: { abs($0.1 - value) < abs($1.1 - value) })?.0 ?? options.first?.0 ?? ""
    }

    private func setCaptionScale(_ scale: Double) {
        captionScale = scale
        channel.invokeMethod("setSubtitleScale", arguments: ["scale": scale])
        applyCaptionAppearance()
        rebuildTransportMenus()
    }

    private func setCaptionColorHex(_ hex: String) {
        captionColorHex = hex
        channel.invokeMethod("setSubtitleColorHex", arguments: ["hex": hex])
        applyCaptionAppearance()
        rebuildTransportMenus()
    }

    private func setCaptionOutlineType(_ type: String) {
        captionOutlineType = type
        channel.invokeMethod("setSubtitleOutlineType", arguments: ["type": type])
        applyCaptionAppearance()
        rebuildTransportMenus()
    }

    private func setCaptionBgOpacity(_ opacity: Double) {
        captionBgOpacity = opacity
        channel.invokeMethod("setSubtitleBgOpacity", arguments: ["opacity": opacity])
        applyCaptionAppearance()
        rebuildTransportMenus()
    }

    private func setCaptionPosition(_ position: Int) {
        captionPositionPref = position
        channel.invokeMethod("setSubtitlePosition", arguments: ["position": position])
        applyCaptionAppearance()
        rebuildTransportMenus()
    }

    private func setCaptionFontFamily(_ family: String) {
        captionFontFamily = family
        channel.invokeMethod("setSubtitleFont", arguments: ["font": family])
        if family.isEmpty {
            captionFontPath = nil
            applyCaptionAppearance()
            rebuildTransportMenus()
            return
        }
        channel.invokeMethod("stageSubtitleFont", arguments: ["font": family]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.captionFontPath = result as? String
                self.applyCaptionAppearance()
                self.rebuildTransportMenus()
            }
        }
    }

    private func buildCaptionDelayMenu() -> UIMenu {
        let presets: [(String, Double)] = [
            ("−5s (earlier)", -5),
            ("0s (file)", 0),
            ("+10s", 10),
            ("+12s", 12),
            ("+13s", 13),
            ("+15s", 15),
            ("+20s", 20),
            ("+25s", 25),
            ("+30s", 30),
        ]
        var actions = presets.map { title, delay in
            UIAction(
                title: title,
                state: abs(captionDelaySeconds - delay) < 0.05 ? .on : .off
            ) { [weak self] _ in
                self?.setCaptionDelay(delay)
            }
        }
        actions.append(UIAction(title: "Nudge −1s") { [weak self] _ in
            guard let self else { return }
            self.setCaptionDelay(self.captionDelaySeconds - 1)
        })
        actions.append(UIAction(title: "Nudge +1s") { [weak self] _ in
            guard let self else { return }
            self.setCaptionDelay(self.captionDelaySeconds + 1)
        })
        let label: String
        if abs(captionDelaySeconds) < 0.05 {
            label = "Delay"
        } else {
            label = String(format: "Delay (%+.0fs)", captionDelaySeconds)
        }
        return UIMenu(
            title: label,
            image: UIImage(systemName: "clock.arrow.2.circlepath"),
            children: actions
        )
    }

    private func setCaptionDelay(_ seconds: Double) {
        captionDelaySeconds = max(-60, min(60, seconds))
        lastActiveCueIndex = nil
        logSubtitleTiming("delay set to \(Self.fmtDelta(captionDelaySeconds))")
        channel.invokeMethod(
            "setSubtitleDelay",
            arguments: ["seconds": captionDelaySeconds]
        )
        flashCaptionStatus(String(format: "Subtitle delay %+.0fs", captionDelaySeconds))
        updateCaptionLabel(force: true)
        rebuildTransportMenus()
    }

    private func refreshEmbeddedLegibleOptions() {
        embeddedLegibleOptions = []
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        else { return }
        embeddedLegibleOptions = group.options
            .filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            .map { opt in
                let name = opt.displayName
                let lang = opt.locale?.languageCode.map { " (\($0))" } ?? ""
                return (name + lang, opt)
            }
    }

    private func clearSubtitles() {
        selectedSubtitleKey = "off"
        captionCues = []
        lastActiveCueIndex = nil
        lastPlaybackT = -1
        setCaptionText(nil)
        if let item = player?.currentItem,
           let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            item.select(nil, in: group)
        }
        rebuildTransportMenus()
    }

    private func selectEmbeddedSubtitle(index: Int) {
        guard index < embeddedLegibleOptions.count,
              let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        else { return }
        captionCues = []
        setCaptionText(nil)
        player?.appliesMediaSelectionCriteriaAutomatically = false
        item.select(embeddedLegibleOptions[index].option, in: group)
        selectedSubtitleKey = "embed:\(index)"
        rebuildTransportMenus()
        NSLog("[zangetsu-av-system] selected embedded sub: %@", embeddedLegibleOptions[index].label)
    }

    private func applySpeed(_ s: Float) {
        currentSpeed = s
        if let player, player.rate > 0 {
            player.rate = s
        }
        channel.invokeMethod("setDefaultSpeed", arguments: ["speed": Double(s)])
        rebuildTransportMenus()
    }

    private func refreshSourcesCache(rebuildMenus: Bool = false) {
        channel.invokeMethod(
            "sourcesFor",
            arguments: ["index": episodeIndex, "category": category]
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.cachedSources = result as? [[String: Any]] ?? []
                if rebuildMenus { self?.rebuildTransportMenus() }
            }
        }
    }

    private func playSource(_ src: [String: Any]) {
        guard let url = src["url"] as? String else { return }
        headers = Self.parseHeaders(src["headers"])
        if let subs = src["subtitles"] as? [[String: String]] {
            subtitles = subs
        } else if let subs = src["subtitles"] as? [[String: Any]] {
            subtitles = subs.map { row in
                var out: [String: String] = [:]
                for (k, v) in row { out[k] = "\(v)" }
                return out
            }
        }
        let skew = (src["subtitleSkewSeconds"] as? NSNumber)?.doubleValue ?? 0
        providerSubtitleSkewApplied = abs(skew) >= 0.05
        persistProgress()
        loadStream(url: url, positionMs: 0, episodeLabel: episodeLabelText)
        rebuildTransportMenus()
    }

    // MARK: - Subtitles

    private func applyProviderSubtitle(_ s: [String: String], key: String) {
        guard let urlStr = s["url"], let url = URL(string: urlStr) else {
            NSLog("[zangetsu-av-system] provider sub missing url")
            flashCaptionStatus("Subtitle URL missing")
            return
        }
        selectedSubtitleKey = key
        logSubtitleTiming("SELECT track=\(key) url=\(url.absoluteString)")
        // Always load the provider file — do not redirect to embedded tracks
        // (language match often picks an empty forced track on dubs).
        applyCaptionAppearance()
        loadCueFile(from: url)
        rebuildTransportMenus()
    }

    private func searchOnlineSubtitles() {
        channel.invokeMethod("searchSubtitles", arguments: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let rows = result as? [[String: Any]] ?? []
                guard !rows.isEmpty else {
                    self.flashCaptionStatus("No online subtitles found")
                    return
                }
                let sheet = UIAlertController(
                    title: "Online subtitles",
                    message: nil,
                    preferredStyle: .alert
                )
                for (i, r) in rows.prefix(12).enumerated() {
                    let name = r["name"] as? String ?? "Sub \(i)"
                    let lang = r["language"] as? String ?? ""
                    sheet.addAction(UIAlertAction(title: "\(name) (\(lang))", style: .default) {
                        [weak self] _ in
                        self?.downloadOnlineSub(index: i)
                    })
                }
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                self.present(sheet, animated: true)
            }
        }
    }

    private func downloadOnlineSub(index: Int) {
        channel.invokeMethod("downloadSubtitle", arguments: ["index": index]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let map = result as? [String: Any],
                      let path = map["path"] as? String else {
                    self.flashCaptionStatus("Download failed")
                    return
                }
                self.selectedSubtitleKey = "online:\(index)"
                self.applyCaptionAppearance()
                self.loadCueFile(from: URL(fileURLWithPath: path))
                self.rebuildTransportMenus()
            }
        }
    }

    private func loadCueFile(from url: URL) {
        lastSubtitleURL = url
        installCaptionOverlay()
        if let item = player?.currentItem,
           let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            item.select(nil, in: group)
        }
        flashCaptionStatus("Loading subtitles…")

        let applyText: (String?) -> Void = { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.captionCues = []
                self.flashCaptionStatus("Could not load subtitles")
                return
            }
            if text.contains("[Script Info]") || text.contains("Dialogue:") {
                self.captionCues = []
                self.flashCaptionStatus("ASS/SSA not supported yet")
                return
            }
            self.applyCueText(text, announce: true)
        }

        if url.isFileURL {
            let data = try? Data(contentsOf: url)
            let text = data.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1)
            }
            applyText(text)
            return
        }

        channel.invokeMethod(
            "fetchSubtitle",
            arguments: ["url": url.absoluteString, "headers": headers]
        ) { result in
            DispatchQueue.main.async {
                let text = (result as? [String: Any])?["text"] as? String
                if text == nil {
                    NSLog("[zangetsu-av-system] fetchSubtitle nil for %@", url.absoluteString)
                }
                applyText(text)
            }
        }
    }

    private func applyCueText(_ text: String, announce: Bool) {
        lastCueSourceText = text
        if streamIsHls, probedHlsEpochSeconds == nil {
            pendingCueText = text
            logSubtitleTiming("VTT ready — waiting for HLS media-epoch probe")
            return
        }
        pendingCueText = nil
        let parsed = Self.parseSubtitleCues(
            text,
            hlsMediaEpoch: streamIsHls ? probedHlsEpochSeconds : nil
        )
        captionCues = parsed.cues
        appliedVttOffset = parsed.vttOffset
        let prefix = String(text.prefix(280))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "'")
        logSubtitleTiming("vtt prefix: \(prefix)")
        if parsed.headerLines.isEmpty {
            logSubtitleTiming("no VTT header lines (no X-TIMESTAMP-MAP)")
        } else {
            for line in parsed.headerLines {
                logSubtitleTiming("header: \(line)")
            }
        }
        if parsed.usedProbedHlsEpoch {
            logSubtitleTiming(
                "HLS sideloaded VTT missing X-TIMESTAMP-MAP — applied stream media " +
                "start \(Self.fmtDelta(parsed.vttOffset)) (from playlist/segment, not a constant)"
            )
            if abs(captionDelaySeconds) >= 8, abs(captionDelaySeconds) <= 30 {
                logSubtitleTiming(
                    "clearing manual delay \(Self.fmtDelta(captionDelaySeconds)) " +
                    "(replaced by probed media start)"
                )
                captionDelaySeconds = 0
                channel.invokeMethod("setSubtitleDelay", arguments: ["seconds": 0.0])
                rebuildTransportMenus()
            }
        } else if abs(parsed.vttOffset) > 0.001 {
            logSubtitleTiming(
                "applied VTT media offset \(Self.fmtDelta(parsed.vttOffset)) to all cue times"
            )
        } else if streamIsHls {
            logSubtitleTiming(
                "HLS VTT has no X-TIMESTAMP-MAP and media start is ~0 — using file timestamps"
            )
            if !providerSubtitleSkewApplied {
                probeVttEncodeSkewIfNeeded()
            } else {
                logSubtitleTiming("VTT encode-skew skipped — provider pack skew already applied")
            }
        }
        lastActiveCueIndex = nil
        if abs(captionDelaySeconds) > 0.05 {
            logSubtitleTiming(
                "using saved delay \(Self.fmtDelta(captionDelaySeconds)) — " +
                "net=\(Self.fmtDelta(appliedVttOffset + captionDelaySeconds)) " +
                "(applied \(Self.fmtDelta(appliedVttOffset)) + delay). " +
                "ON/GAP lookup is shifted; spoken audio is not."
            )
        }
        logSubtitleLoadDiagnostics(cues: parsed.cues)
        logVttVsSkips()
        guard announce else {
            updateCaptionLabel(force: true)
            return
        }
        if parsed.cues.isEmpty {
            flashCaptionStatus("No cues in subtitle file")
        }
    }

    private func isCaptionStatusActive() -> Bool {
        guard let until = captionStatusUntil else { return false }
        if Date() < until { return true }
        captionStatusUntil = nil
        return false
    }

    private func setCaptionText(_ text: String?) {
        installCaptionOverlay()
        captionParentView().bringSubviewToFront(captionHost)
        if let text, !text.isEmpty {
            captionLabel.attributedText = makeCaptionAttributed(text)
            captionBubble.isHidden = false
        } else {
            captionLabel.attributedText = nil
            captionLabel.text = nil
            captionBubble.isHidden = true
        }
    }

    private func flashCaptionStatus(_ message: String) {
        captionStatusUntil = Date().addingTimeInterval(2.0)
        setCaptionText(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.captionStatusUntil = nil
            self.updateCaptionLabel(force: true)
        }
    }

    private func updateCaptionLabel(force: Bool = false) {
        if !force, isCaptionStatusActive() { return }
        installCaptionOverlay()
        captionParentView().bringSubviewToFront(captionHost)
        guard !captionCues.isEmpty, let player else {
            if captionCues.isEmpty { setCaptionText(nil) }
            return
        }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        // Positive delay → show file cues later (lookup as if earlier in the file).
        let lookupT = t - captionDelaySeconds
        logSubtitleSeekIfNeeded(t: t)
        if let match = cueMatch(at: lookupT) {
            if lastActiveCueIndex != match.index {
                logSubtitleCueTransition(
                    kind: lastActiveCueIndex == nil ? "ON" : "CHANGE",
                    index: match.index,
                    cue: match.cue,
                    t: t,
                    lookupT: lookupT
                )
                lastActiveCueIndex = match.index
            }
            setCaptionText(match.cue.text)
        } else {
            if let prev = lastActiveCueIndex {
                if prev < captionCues.count {
                    let ended = captionCues[prev]
                    logSubtitleTiming(
                        "CUE OFF idx=\(prev) t=\(Self.fmtT(t)) lookup=\(Self.fmtT(lookupT)) " +
                        "ended=\(Self.fmtT(ended.end)) late=\(Self.fmtDelta(lookupT - ended.end))"
                    )
                }
                lastActiveCueIndex = nil
            }
            setCaptionText(nil)
            logSubtitleGap(at: lookupT, playbackT: t)
        }
        logSubtitleHeartbeat(at: t, lookupT: lookupT)
    }

    // MARK: - Subtitle timing debug

    private func logSubtitleTiming(_ message: String) {
        NSLog("[zangetsu-sub-timing] %@", message)
        // Also mirror to Flutter terminal (`flutter: [zangetsu-sub-timing] …`).
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod(
                "subtitleTimingLog",
                arguments: ["message": message]
            )
        }
    }

    private static func fmtT(_ t: Double) -> String { String(format: "%.3f", t) }
    private static func fmtDelta(_ d: Double) -> String {
        String(format: "%+.3fs", d)
    }

    private static func cuePreview(_ text: String, maxLen: Int = 48) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        if oneLine.count <= maxLen { return oneLine }
        return String(oneLine.prefix(maxLen - 1)) + "…"
    }

    private func logSubtitleLoadDiagnostics(cues: [(start: Double, end: Double, text: String)]) {
        let t = player?.currentTime().seconds ?? -1
        let dur = player?.currentItem?.duration.seconds ?? -1
        let first = cues.first.map { "\(Self.fmtT($0.start))-\(Self.fmtT($0.end))" } ?? "-"
        let last = cues.last.map { "\(Self.fmtT($0.start))-\(Self.fmtT($0.end))" } ?? "-"
        logSubtitleTiming(
            "LOADED count=\(cues.count) playback=\(Self.fmtT(t)) duration=\(dur.isFinite ? Self.fmtT(dur) : "?") " +
            "span=\(first)…\(last) applied=\(Self.fmtDelta(appliedVttOffset)) " +
            "delay=\(Self.fmtDelta(captionDelaySeconds)) " +
            "net=\(Self.fmtDelta(appliedVttOffset + captionDelaySeconds))"
        )
        if let firstCue = cues.first, let lastCue = cues.last, dur.isFinite, dur > 0 {
            let fileFirst = firstCue.start - appliedVttOffset
            let fileLast = lastCue.end - appliedVttOffset
            logSubtitleTiming(
                "clocks vttFileFirst=\(Self.fmtT(fileFirst)) vttFileLast=\(Self.fmtT(fileLast)) " +
                "playerDur=\(Self.fmtT(dur)) tailAfterVtt=\(Self.fmtDelta(dur - fileLast)) " +
                "headBeforeFirst=\(Self.fmtDelta(fileFirst))"
            )
        }
        for i in 0..<min(5, cues.count) {
            let c = cues[i]
            logSubtitleTiming(
                "sample[\(i)] \(Self.fmtT(c.start))-\(Self.fmtT(c.end)) \"\(Self.cuePreview(c.text))\""
            )
        }
        if cues.count > 8 {
            for i in (cues.count - 3)..<cues.count {
                let c = cues[i]
                logSubtitleTiming(
                    "sampleLast[\(i)] \(Self.fmtT(c.start))-\(Self.fmtT(c.end)) \"\(Self.cuePreview(c.text))\""
                )
            }
        }
        if t.isFinite, !cues.isEmpty {
            logSubtitleNearest(to: t, label: "at load")
        }
    }

    private func logVttVsSkips() {
        guard !captionCues.isEmpty else { return }
        let fileTimes: [(i: Int, start: Double, end: Double, text: String)] = captionCues.enumerated().map { pair in
            let fileStart = pair.element.start - appliedVttOffset
            let fileEnd = pair.element.end - appliedVttOffset
            return (pair.offset, fileStart, fileEnd, pair.element.text)
        }
        let inHead = fileTimes.filter { $0.start < 40 }
        if !inHead.isEmpty {
            let desc = inHead.prefix(12).map { c in
                "\(Self.fmtT(c.start)) \"\(Self.cuePreview(c.text, maxLen: 28))\""
            }.joined(separator: " · ")
            logSubtitleTiming("vtt first40s (\(inHead.count) cues) \(desc)")
        }
        if skipIntervals.isEmpty {
            logSubtitleTiming("vtt vs aniskip: skips not loaded yet")
            return
        }
        for skip in skipIntervals {
            let a = Double(skip.start) / 1000.0
            let b = Double(skip.end) / 1000.0
            let inside = fileTimes.filter { $0.start >= a && $0.start < b }
            let before = fileTimes.last(where: { $0.end <= a })
            let after = fileTimes.first(where: { $0.start >= b })
            var parts = [
                "vtt vs aniskip \(skip.type) \(Self.fmtT(a))-\(Self.fmtT(b)) " +
                "cuesInside=\(inside.count)",
            ]
            if let before {
                parts.append(
                    "lastBefore[\(before.i)] \(Self.fmtT(before.start))-\(Self.fmtT(before.end)) " +
                    "\"\(Self.cuePreview(before.text, maxLen: 32))\""
                )
            }
            if let first = inside.first {
                parts.append(
                    "firstInside[\(first.i)] \(Self.fmtT(first.start)) " +
                    "\"\(Self.cuePreview(first.text, maxLen: 32))\""
                )
            }
            if let after {
                parts.append(
                    "firstAfter[\(after.i)] \(Self.fmtT(after.start)) " +
                    "\"\(Self.cuePreview(after.text, maxLen: 32))\""
                )
            }
            logSubtitleTiming(parts.joined(separator: " | "))
        }
    }

    private func logSubtitleCueTransition(
        kind: String,
        index: Int,
        cue: (start: Double, end: Double, text: String),
        t: Double,
        lookupT: Double
    ) {
        logSubtitleTiming(
            "\(kind) idx=\(index) t=\(Self.fmtT(t)) lookup=\(Self.fmtT(lookupT)) " +
            "file=\(Self.fmtT(cue.start - appliedVttOffset)) " +
            "delay=\(Self.fmtDelta(captionDelaySeconds)) applied=\(Self.fmtDelta(appliedVttOffset)) " +
            "net=\(Self.fmtDelta(appliedVttOffset + captionDelaySeconds)) " +
            "range=\(Self.fmtT(cue.start))-\(Self.fmtT(cue.end)) " +
            "offset=\(Self.fmtDelta(lookupT - cue.start)) dur=\(Self.fmtT(cue.end - cue.start)) " +
            "\"\(Self.cuePreview(cue.text))\""
        )
    }

    private func logSubtitleSeekIfNeeded(t: Double) {
        guard lastPlaybackT >= 0 else {
            lastPlaybackT = t
            return
        }
        let delta = t - lastPlaybackT
        // Periodic observer fires every 0.2s; anything larger is a seek or speed change.
        if abs(delta) > 1.5 {
            logSubtitleTiming(
                "SEEK \(Self.fmtT(lastPlaybackT)) → \(Self.fmtT(t)) delta=\(Self.fmtDelta(delta))"
            )
            if !captionCues.isEmpty {
                logSubtitleNearest(to: t - captionDelaySeconds, label: "after seek")
            }
            lastActiveCueIndex = nil
        }
        lastPlaybackT = t
    }

    private func logSubtitleGap(at lookupT: Double, playbackT: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastCaptionDiagAt > 2 else { return }
        lastCaptionDiagAt = now
        let (prev, next) = nearestCueBounds(at: lookupT)
        var parts = [
            "GAP t=\(Self.fmtT(playbackT)) lookup=\(Self.fmtT(lookupT)) " +
            "delay=\(Self.fmtDelta(captionDelaySeconds))",
        ]
        if let p = prev {
            parts.append("prev[\(p.index)] ended \(Self.fmtT(p.end)) (\(Self.fmtDelta(lookupT - p.end)) ago)")
        }
        if let n = next {
            parts.append("next[\(n.index)] starts \(Self.fmtT(n.start)) (in \(Self.fmtDelta(n.start - lookupT)))")
        }
        if prev == nil && next == nil {
            parts.append("no cues")
        }
        logSubtitleTiming(parts.joined(separator: " | "))
    }

    private func logSubtitleHeartbeat(at t: Double, lookupT: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastSubTimingHeartbeatAt >= 10 else { return }
        lastSubTimingHeartbeatAt = now
        if let match = cueMatch(at: lookupT) {
            logSubtitleTiming(
                "heartbeat t=\(Self.fmtT(t)) lookup=\(Self.fmtT(lookupT)) " +
                "delay=\(Self.fmtDelta(captionDelaySeconds)) active idx=\(match.index) " +
                "range=\(Self.fmtT(match.cue.start))-\(Self.fmtT(match.cue.end)) " +
                "offset=\(Self.fmtDelta(lookupT - match.cue.start))"
            )
        } else {
            let (_, next) = nearestCueBounds(at: lookupT)
            if let n = next {
                logSubtitleTiming(
                    "heartbeat t=\(Self.fmtT(t)) lookup=\(Self.fmtT(lookupT)) " +
                    "delay=\(Self.fmtDelta(captionDelaySeconds)) no cue | next[\(n.index)] @ \(Self.fmtT(n.start)) " +
                    "in \(Self.fmtDelta(n.start - lookupT))"
                )
            } else {
                logSubtitleTiming(
                    "heartbeat t=\(Self.fmtT(t)) lookup=\(Self.fmtT(lookupT)) " +
                    "delay=\(Self.fmtDelta(captionDelaySeconds)) no cue | past last cue"
                )
            }
        }
    }

    private func logSubtitleNearest(to t: Double, label: String) {
        if let match = cueMatch(at: t) {
            logSubtitleTiming(
                "nearest (\(label)) INSIDE idx=\(match.index) " +
                "range=\(Self.fmtT(match.cue.start))-\(Self.fmtT(match.cue.end)) " +
                "offset=\(Self.fmtDelta(t - match.cue.start))"
            )
            return
        }
        let (prev, next) = nearestCueBounds(at: t)
        var parts = ["nearest (\(label)) t=\(Self.fmtT(t))"]
        if let p = prev {
            parts.append("prev[\(p.index)] \(Self.fmtT(p.start))-\(Self.fmtT(p.end))")
        }
        if let n = next {
            parts.append("next[\(n.index)] \(Self.fmtT(n.start))-\(Self.fmtT(n.end)) " +
                         "starts in \(Self.fmtDelta(n.start - t))")
        }
        logSubtitleTiming(parts.joined(separator: " | "))
    }

    private typealias CueBounds = (index: Int, start: Double, end: Double)

    private func cueMatch(at t: Double) -> (index: Int, cue: (start: Double, end: Double, text: String))? {
        var lo = 0
        var hi = captionCues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = captionCues[mid]
            if t < cue.start {
                hi = mid - 1
            } else if t >= cue.end {
                lo = mid + 1
            } else {
                return (mid, cue)
            }
        }
        if let idx = captionCues.firstIndex(where: { t >= $0.start && t < $0.end }) {
            return (idx, captionCues[idx])
        }
        return nil
    }

    private func nearestCueBounds(at t: Double) -> (prev: CueBounds?, next: CueBounds?) {
        var prev: CueBounds?
        var next: CueBounds?
        for (i, cue) in captionCues.enumerated() {
            if cue.end <= t {
                prev = (i, cue.start, cue.end)
            } else if cue.start > t, next == nil {
                next = (i, cue.start, cue.end)
                break
            }
        }
        return (prev, next)
    }

    private func cueAt(time t: Double) -> (start: Double, end: Double, text: String)? {
        cueMatch(at: t)?.cue
    }

    private func logPlayerTimelineDiagnostics(_ item: AVPlayerItem, label: String = "ready") {
        func ranges(_ raw: [NSValue]) -> String {
            let parts = raw
                .compactMap { $0 as? CMTimeRange }
                .filter(\.isValid)
                .map { r -> String in
                    let a = r.start.seconds
                    let b = (r.start + r.duration).seconds
                    return String(format: "[%.3f…%.3f]", a.isFinite ? a : -1, b.isFinite ? b : -1)
                }
            return parts.isEmpty ? "none" : parts.joined(separator: ",")
        }
        let dur = item.duration
        let cur = player?.currentTime() ?? item.currentTime()
        logSubtitleTiming(
            "player timeline \(label) hls=\(streamIsHls) " +
            "current=\(Self.fmtT(cur.seconds)) " +
            "duration=\(dur.seconds.isFinite ? Self.fmtT(dur.seconds) : "?") " +
            "durTS=\(dur.timescale) " +
            "seekable=\(ranges(item.seekableTimeRanges)) " +
            "loaded=\(ranges(item.loadedTimeRanges))"
        )
        for track in item.tracks {
            guard let assetTrack = track.assetTrack else {
                logSubtitleTiming("asset track (no AVAssetTrack)")
                continue
            }
            let tr = assetTrack.timeRange
            let start = tr.start.seconds
            let durT = tr.duration.seconds
            logSubtitleTiming(
                "asset track \(label) \(assetTrack.mediaType.rawValue) " +
                "valid=\(tr.isValid) " +
                "start=\(start.isFinite ? Self.fmtT(start) : "?") " +
                "dur=\(durT.isFinite ? Self.fmtT(durT) : "?") " +
                "ts=\(tr.start.timescale)"
            )
        }
        if let events = item.accessLog()?.events, let last = events.last {
            logSubtitleTiming(
                "accessLog \(label) indicatedBitrate=\(Int(last.indicatedBitrate)) " +
                "observedBitrate=\(Int(last.observedBitrate)) " +
                "stalls=\(last.numberOfStalls) dropped=\(last.numberOfDroppedVideoFrames)"
            )
        }
    }

    private func probeEpochFromPlayerItem(_ item: AVPlayerItem) {
        guard streamIsHls else { return }
        var best: Double?
        for track in item.tracks {
            guard let assetTrack = track.assetTrack else { continue }
            let start = assetTrack.timeRange.start.seconds
            guard start.isFinite, start >= 8, start <= 30 else { continue }
            if best == nil || start < best! { best = start }
        }
        guard let best else { return }
        finishHlsEpochProbe(best, reason: "AVAssetTrack.timeRange.start")
    }

    private func probeVttEncodeSkewIfNeeded() {
        guard streamIsHls, !probedVttEncodeSkew else { return }
        guard let stream = streamURL, let vtt = lastSubtitleURL else { return }
        let dur = player?.currentItem?.duration.seconds ?? 0
        guard dur.isFinite, dur > 30 else {
            logSubtitleTiming("VTT encode-skew waiting for duration")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.probeVttEncodeSkewIfNeeded()
            }
            return
        }
        probedVttEncodeSkew = true
        logSubtitleTiming(
            "VTT encode-skew probe playerDur=\(dur.isFinite ? Self.fmtT(dur) : "?") " +
            "vtt=\(vtt.absoluteString)"
        )
        channel.invokeMethod(
            "probeVttEncodeSkew",
            arguments: [
                "streamUrl": stream.absoluteString,
                "subtitleUrl": vtt.absoluteString,
                "streamDuration": dur.isFinite ? dur : 0,
                "headers": headers,
            ]
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let map = result as? [String: Any]
                let seconds = (map?["seconds"] as? NSNumber)?.doubleValue
                let reason = map?["reason"] as? String ?? "no result"
                self.logSubtitleTiming(
                    "VTT encode-skew \(reason) → \(Self.fmtDelta(seconds ?? 0))"
                )
                if let seconds, seconds >= 8, seconds <= 30 {
                    self.finishHlsEpochProbe(seconds, reason: reason)
                }
            }
        }
    }

    private struct ParsedSubtitleCues {
        let cues: [(start: Double, end: Double, text: String)]
        let vttOffset: Double
        let headerLines: [String]
        let usedProbedHlsEpoch: Bool
    }

    private func probeHlsMediaEpoch(playlist url: URL) {
        logSubtitleTiming("HLS epoch probe start \(url.absoluteString)")
        channel.invokeMethod(
            "probeHlsEpoch",
            arguments: ["url": url.absoluteString, "headers": headers]
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.streamURL == url else { return }
                let map = result as? [String: Any]
                let seconds = (map?["seconds"] as? NSNumber)?.doubleValue
                let reason = map?["reason"] as? String ?? "no result"
                if let seconds, seconds >= 8 {
                    self.finishHlsEpochProbe(seconds, reason: reason)
                } else {
                    self.finishHlsEpochProbe(nil, reason: reason)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.streamURL == url, self.probedHlsEpochSeconds == nil else { return }
            self.finishHlsEpochProbe(nil, reason: "timed out")
        }
    }

    private func finishHlsEpochProbe(_ seconds: Double?, reason: String) {
        if let existing = probedHlsEpochSeconds, existing >= 8 { return }
        let previous = probedHlsEpochSeconds
        if let seconds, seconds >= 8 {
            probedHlsEpochSeconds = seconds
            logSubtitleTiming("HLS epoch probe \(reason) → \(Self.fmtDelta(seconds))")
        } else if probedHlsEpochSeconds == nil {
            probedHlsEpochSeconds = 0
            logSubtitleTiming("HLS epoch probe skipped (\(reason)) — file timestamps")
        } else {
            return
        }
        let upgraded = (previous == 0 || previous == nil) && (probedHlsEpochSeconds ?? 0) >= 8
        if let pending = pendingCueText {
            applyCueText(pending, announce: true)
        } else if upgraded, let text = lastCueSourceText {
            applyCueText(text, announce: false)
        }
    }

    /// Minimal SRT / WebVTT cue parser. Applies HLS [X-TIMESTAMP-MAP] when present;
    /// for HLS sidecars with no map, uses the probed first-segment media time.
    private static func parseSubtitleCues(
        _ raw: String,
        hlsMediaEpoch: Double?
    ) -> ParsedSubtitleCues {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var (vttOffset, headerLines) = parseWebVttMediaOffset(text)
        var usedProbed = false
        if abs(vttOffset) < 0.001, let epoch = hlsMediaEpoch, epoch >= 8, text.hasPrefix("WEBVTT") {
            vttOffset = epoch
            usedProbed = true
        }
        if text.hasPrefix("WEBVTT") {
            if let range = text.range(of: "\n\n") {
                text = String(text[range.upperBound...])
            }
        }
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [(start: Double, end: Double, text: String)] = []
        let ts = #"(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}"#
        let lineRe = try? NSRegularExpression(
            pattern: "(\(ts))\\s*-->\\s*(\(ts))"
        )
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrowLine = lines.first(where: { $0.contains("-->") }),
                  let match = lineRe?.firstMatch(
                      in: arrowLine,
                      range: NSRange(arrowLine.startIndex..., in: arrowLine)
                  ),
                  match.numberOfRanges >= 3,
                  let r1 = Range(match.range(at: 1), in: arrowLine),
                  let r2 = Range(match.range(at: 2), in: arrowLine),
                  let start = parseTimestamp(String(arrowLine[r1])),
                  let end = parseTimestamp(String(arrowLine[r2])),
                  end > start
            else { continue }
            let bodyLines = lines.filter { !$0.contains("-->") && Int($0) == nil && !$0.isEmpty }
            let body = bodyLines
                .map { line -> String in
                    var s = line
                    while let r = s.range(of: #"<[^>]+>"#, options: .regularExpression) {
                        s.removeSubrange(r)
                    }
                    return s
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                cues.append((start + vttOffset, end + vttOffset, body))
            }
        }
        return ParsedSubtitleCues(
            cues: cues,
            vttOffset: vttOffset,
            headerLines: headerLines,
            usedProbedHlsEpoch: usedProbed
        )
    }

    /// HLS WebVTT maps local cue times onto the MPEG-TS timeline via this header.
    /// Ignoring it makes cues appear early by MPEGTS/90000 − LOCAL seconds.
    private static func parseWebVttMediaOffset(_ raw: String) -> (offset: Double, headerLines: [String]) {
        guard raw.hasPrefix("WEBVTT") else { return (0, []) }
        var headerLines: [String] = []
        var offset: Double = 0
        for line in raw.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix("NOTE") { continue }
            headerLines.append(trimmed)
            // Spec uses `X-TIMESTAMP-MAP=LOCAL:…,MPEGTS:…` (equals, not colon after MAP).
            let upper = trimmed.uppercased()
            if upper.hasPrefix("X-TIMESTAMP-MAP"),
               let mapped = parseTimestampMapLine(trimmed) {
                offset = mapped
            }
        }
        return (offset, headerLines)
    }

    private static func parseTimestampMapLine(_ line: String) -> Double? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...]
        var localSec: Double = 0
        var mpegts: Double?
        for part in value.split(separator: ",") {
            let p = String(part).trimmingCharacters(in: .whitespaces)
            if p.uppercased().hasPrefix("LOCAL:") {
                let v = String(p.dropFirst(6))
                localSec = parseTimestamp(v) ?? 0
            } else if p.uppercased().hasPrefix("MPEGTS:") {
                mpegts = Double(p.dropFirst(7))
            }
        }
        guard let mpegts else { return nil }
        return mpegts / 90000.0 - localSec
    }

    private static func parseTimestamp(_ s: String) -> Double? {
        let norm = s.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ":").map(String.init)
        guard let last = parts.last else { return nil }
        let secParts = last.split(separator: ".").map(String.init)
        guard let sec = Double(secParts[0]) else { return nil }
        let frac = secParts.count > 1 ? Double("0.\(secParts[1])") ?? 0 : 0
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]) {
            return h * 3600 + m * 60 + sec + frac
        }
        if parts.count == 2, let m = Double(parts[0]) {
            return m * 60 + sec + frac
        }
        return sec + frac
    }

    // MARK: - Tick / skip / contextual

    private func onTick(_ t: CMTime) {
        let seconds = t.seconds
        guard seconds.isFinite else { return }
        let pos = Int64(seconds * 1000)
        updateContextualActions(posMs: pos)
        maybeAutoSkip(posMs: pos)
        updateCaptionLabel()
    }

    private func updateContextualActions(posMs: Int64) {
        var key = ""
        var action: UIAction?
        if skipIntro,
           let hit = skipIntervals.first(where: { posMs >= $0.start && posMs < $0.end }) {
            let title: String
            switch hit.type {
            case "op", "opening": title = "Skip Opening"
            case "ed", "ending": title = "Skip Ending"
            case "recap": title = "Skip Recap"
            default: title = "Skip"
            }
            key = "\(title):\(hit.end)"
            let end = hit.end
            action = UIAction(title: title) { [weak self] _ in
                self?.player?.seek(to: CMTime(value: end, timescale: 1000))
                self?.lastContextualKey = nil
                self?.contextualActions = []
            }
        }
        guard key != lastContextualKey else { return }
        lastContextualKey = key
        contextualActions = action.map { [$0] } ?? []
    }

    private func maybeAutoSkip(posMs: Int64) {
        for hit in skipIntervals {
            guard posMs >= hit.start && posMs < hit.start + 800 else { continue }
            guard !autoSkippedStarts.contains(hit.start) else { continue }
            let type = hit.type
            let auto =
                (type == "op" || type == "opening") && autoSkipOp
                || (type == "ed" || type == "ending") && autoSkipEd
                || type == "recap" && autoSkipRecap
            if auto {
                autoSkippedStarts.insert(hit.start)
                player?.seek(to: CMTime(value: hit.end, timescale: 1000))
                return
            }
        }
        if autoSkipFiller,
           episodeIndex < fillerFlags.count,
           fillerFlags[episodeIndex],
           posMs < 1500 {
            playNext()
        }
    }

    private func seekBy(_ ms: Int64) {
        guard let player else { return }
        let cur = CMTimeGetSeconds(player.currentTime())
        guard cur.isFinite else { return }
        var dur = player.currentItem?.duration.seconds ?? cur
        if !dur.isFinite || dur <= 0 { dur = cur + Double(ms) / 1000.0 }
        let next = max(0, min(dur, cur + Double(ms) / 1000.0))
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600))
    }

    private func fetchSkips() {
        let durSeconds = player?.currentItem?.duration.seconds ?? 0
        let dur = durSeconds.isFinite && durSeconds > 0 ? Int(durSeconds * 1000) : 0
        channel.invokeMethod(
            "skipsFor",
            arguments: ["index": episodeIndex, "durationMs": dur]
        ) { [weak self] result in
            DispatchQueue.main.async {
                let rows = result as? [[String: Any]] ?? []
                self?.skipIntervals = rows.compactMap { r in
                    guard let start = (r["start"] as? NSNumber)?.int64Value,
                          let end = (r["end"] as? NSNumber)?.int64Value,
                          let type = r["type"] as? String else { return nil }
                    return (start, end, type)
                }
                let skips = self?.skipIntervals ?? []
                if skips.isEmpty {
                    self?.logSubtitleTiming("skips none")
                } else {
                    let desc = skips.map { s in
                        String(format: "%@ %.1f-%.1f", s.type, Double(s.start) / 1000.0, Double(s.end) / 1000.0)
                    }.joined(separator: ", ")
                    self?.logSubtitleTiming("skips \(desc)")
                    self?.logVttVsSkips()
                }
            }
        }
    }

    // MARK: - Episodes / next / resolve

    private func installEpisodesTab() {
        let tab = TvEpisodesInfoViewController()
        tab.title = "Episodes"
        // Tall enough that AVKit doesn't clip the list; table fills the tab.
        tab.preferredContentSize = CGSize(width: 1720, height: 560)
        tab.onPick = { [weak self] index in
            self?.resolveAndPlay(index: index)
        }
        tab.configure(labels: episodeLabels, count: episodeCount, current: episodeIndex)
        episodesTab = tab
        customInfoViewControllers = [tab]
    }

    private func playNext() {
        let next = episodeIndex + 1
        guard next < episodeCount else { return }
        resolveAndPlay(index: next)
    }

    private func resolveAndPlay(index: Int, forceReload: Bool = false) {
        if !forceReload && index == episodeIndex, player?.currentItem != nil {
            return
        }
        persistProgress()
        channel.invokeMethod(
            "resolveEpisode",
            arguments: ["index": index, "category": category]
        ) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let map = result as? [String: Any],
                      let url = map["url"] as? String else { return }
                self.headers = Self.parseHeaders(map["headers"])
                if let s = map["subtitles"] as? [[String: String]] {
                    self.subtitles = s
                } else if let s = map["subtitles"] as? [[String: Any]] {
                    self.subtitles = s.map { row in
                        var out: [String: String] = [:]
                        for (k, v) in row { out[k] = "\(v)" }
                        return out
                    }
                }
                let skew = (map["subtitleSkewSeconds"] as? NSNumber)?.doubleValue ?? 0
                self.providerSubtitleSkewApplied = abs(skew) >= 0.05
                self.episodeIndex = index
                let pos = (map["positionMs"] as? NSNumber)?.int64Value ?? 0
                let label = map["episodeLabel"] as? String
                    ?? (index < self.episodeLabels.count
                        ? self.episodeLabels[index]
                        : "Episode \(index + 1)")
                self.loadStream(url: url, positionMs: forceReload ? 0 : pos, episodeLabel: label)
                self.refreshSourcesCache(rebuildMenus: true)
            }
        }
    }

    private func onEnded() {
        // Up Next content proposal handles advance when another episode exists.
        if episodeIndex + 1 >= episodeCount {
            finishIfNeeded()
        }
    }

    // MARK: - Content proposal (Up Next)

    private func refreshContentProposal() {
        guard let item = player?.currentItem else { return }
        guard episodeIndex + 1 < episodeCount else {
            item.nextContentProposal = nil
            return
        }
        let dur = item.duration
        guard dur.isNumeric, dur.seconds.isFinite, dur.seconds > 15 else {
            // Duration may still be unknown — retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshContentProposal()
            }
            return
        }
        let transition = dur - CMTime(seconds: 10, preferredTimescale: 1)
        let nextIdx = episodeIndex + 1
        let title = nextIdx < episodeLabels.count
            ? episodeLabels[nextIdx]
            : "Episode \(nextIdx + 1)"
        let proposal = AVContentProposal(
            contentTimeForTransition: transition,
            title: "Up Next: \(title)",
            previewImage: UIImage(systemName: "play.rectangle.fill")!
        )
        // URL filled after Dart resolve on accept — placeholder keeps proposal eligible.
        proposal.url = URL(string: "zangetsu://next/\(nextIdx)")
        proposal.automaticAcceptanceInterval = 8
        item.nextContentProposal = proposal
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        shouldPresent proposal: AVContentProposal
    ) -> Bool {
        let vc = TvUpNextProposalViewController()
        vc.proposalTitle = proposal.title
        playerViewController.contentProposalViewController = vc
        return true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didAccept proposal: AVContentProposal
    ) {
        playNext()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didReject proposal: AVContentProposal
    ) {
        // Stay on current / ended state.
    }

    // MARK: - Progress / close

    private func startSaveLoop() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.persistProgress()
        }
    }

    private func persistProgress() {
        guard let player else { return }
        let cur = player.currentTime().seconds
        let durS = player.currentItem?.duration.seconds ?? 0
        guard cur.isFinite, durS.isFinite else { return }
        channel.invokeMethod("saveProgress", arguments: [
            "index": episodeIndex,
            "positionMs": Int(cur * 1000),
            "durationMs": Int(durS * 1000),
            "playing": player.rate > 0,
        ])
    }

    private func finishIfNeeded(error: String? = nil) {
        guard !finished else { return }
        finished = true
        persistProgress()
        tearDownObservers()
        saveTimer?.invalidate()
        saveTimer = nil
        tearDownCaptionWindow()

        let cur = player?.currentTime().seconds ?? 0
        let durS = player?.currentItem?.duration.seconds ?? 0
        let pos = cur.isFinite ? Int(cur * 1000) : 0
        let dur = durS.isFinite ? Int(durS * 1000) : 0
        player?.pause()
        player = nil

        let payload: [String: Any] = [
            "episodeIndex": episodeIndex,
            "positionMs": pos,
            "durationMs": dur,
        ]
        if let error {
            NSLog("[zangetsu-av-system] %@", error)
        }
        launchResult?(payload)
        launchResult = nil
        TvSystemPlayerViewController.active = nil
        if presentingViewController != nil, !isBeingDismissed {
            dismiss(animated: true)
        }
    }
}

// MARK: - Episodes info tab

final class TvEpisodesInfoViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onPick: ((Int) -> Void)?
    private let table = UITableView(frame: .zero, style: .plain)
    private var labels: [String] = []
    private var count = 0
    private var current = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        // Let AVKit's info chrome provide the panel; avoid our own black slab.
        view.backgroundColor = .clear
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.rowHeight = 64
        table.estimatedRowHeight = 64
        table.dataSource = self
        table.delegate = self
        table.remembersLastFocusedIndexPath = true
        table.register(UITableViewCell.self, forCellReuseIdentifier: "ep")
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToCurrent(animated: false)
    }

    func configure(labels: [String], count: Int, current: Int) {
        loadViewIfNeeded()
        self.labels = labels
        self.count = count
        self.current = current
        table.reloadData()
        DispatchQueue.main.async { [weak self] in
            self?.scrollToCurrent(animated: false)
        }
    }

    func highlight(index: Int) {
        current = index
        table.reloadData()
        DispatchQueue.main.async { [weak self] in
            self?.scrollToCurrent(animated: true)
        }
    }

    private func scrollToCurrent(animated: Bool) {
        guard count > 0, current >= 0, current < count else { return }
        let path = IndexPath(row: current, section: 0)
        table.scrollToRow(at: path, at: .middle, animated: animated)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ep", for: indexPath)
        let i = indexPath.row
        let title = i < labels.count ? labels[i] : "Episode \(i + 1)"
        let isCurrent = i == current
        let accent = UIColor(red: 1, green: 0.302, blue: 0.341, alpha: 1)

        cell.configurationUpdateHandler = { cell, state in
            var config = UIListContentConfiguration.cell()
            config.text = isCurrent ? "▶  \(title)" : title
            config.textProperties.font = .systemFont(
                ofSize: 26,
                weight: (state.isFocused || isCurrent) ? .semibold : .regular
            )
            config.textProperties.numberOfLines = 2
            if state.isFocused {
                config.textProperties.color = .black
                cell.backgroundColor = .white
            } else if isCurrent {
                config.textProperties.color = accent
                cell.backgroundColor = .clear
            } else {
                config.textProperties.color = UIColor.white.withAlphaComponent(0.82)
                cell.backgroundColor = .clear
            }
            cell.contentConfiguration = config
            cell.layer.cornerRadius = state.isFocused ? 10 : 0
            cell.clipsToBounds = state.isFocused
        }

        var config = UIListContentConfiguration.cell()
        config.text = isCurrent ? "▶  \(title)" : title
        config.textProperties.color = isCurrent ? accent : UIColor.white.withAlphaComponent(0.82)
        config.textProperties.font = .systemFont(ofSize: 26, weight: isCurrent ? .semibold : .regular)
        config.textProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.backgroundColor = .clear
        cell.layer.cornerRadius = 0
        cell.clipsToBounds = false
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onPick?(indexPath.row)
    }

    func indexPathForPreferredFocusedView(in tableView: UITableView) -> IndexPath? {
        guard count > 0 else { return nil }
        return IndexPath(row: min(max(0, current), count - 1), section: 0)
    }
}

// MARK: - Up Next proposal

final class TvUpNextProposalViewController: AVContentProposalViewController {
    var proposalTitle: String = "Up Next"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIView()
        card.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = proposalTitle
        title.textColor = .white
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.numberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false

        let play = UIButton(type: .system)
        play.setTitle("Play Now", for: .normal)
        play.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        play.setTitleColor(.black, for: .normal)
        play.backgroundColor = .white
        play.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        play.layer.cornerRadius = 22
        play.addTarget(self, action: #selector(accept), for: .primaryActionTriggered)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        cancel.setTitleColor(.white, for: .normal)
        cancel.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        cancel.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        cancel.layer.cornerRadius = 22
        cancel.addTarget(self, action: #selector(reject), for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [play, cancel])
        row.axis = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        card.addSubview(title)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -48),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),
            card.widthAnchor.constraint(equalToConstant: 520),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }

    override var preferredPlayerViewFrame: CGRect {
        guard let frame = playerViewController?.view.bounds else { return .zero }
        let w: CGFloat = 960
        let h: CGFloat = 540
        return CGRect(x: (frame.width - w) / 2, y: 40, width: w, height: h)
    }

    @objc private func accept() {
        dismissContentProposal(for: .accept, animated: true)
    }

    @objc private func reject() {
        dismissContentProposal(for: .reject, animated: true)
    }
}
