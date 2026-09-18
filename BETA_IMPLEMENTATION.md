# Zangetsu Beta companion development history

Historical entries describe each iteration at that time. README.md and REMOTE_COMPATIBILITY.md describe the current 0.7.0 status. Version 0.7.0 was built and installed on an Android phone and Android TV; installation is not full feature verification.

Experimental fork of Spyou/Zangetsu. Display name Zangetsu Beta; Android application ID com.serenity.zangetsu.beta. Original app/data remain separate. No upstream submission has been made.

## Version 0.3.0

Phone Remote tab sits immediately before Profile. The main remote has a circular D-pad in the existing dark/coral theme, Back, Search and playback options, with compact transport and volume controls during playback. Main controls do not scroll; pairing and track selections use separate sheets. Search supports text and Android voice recognition.

Remote mode is optional. The phone retains normal browsing and detail pages; opening a title reports its name to the TV. Selecting playback sends a canonical catalogue identifier or a source/title/episode selection for resolution on the TV. The normal D-pad remains available. A missing source or ambiguous title requires selection through Search TV sources.

Pair once using a six-digit, five-minute code or the QR in TV remote settings. The phone scanner uses Google Play services; manual pairing remains available if the scanner module is unavailable. Bluetooth requires Android-level pairing. Saved per-device credentials support reconnect without another code. The connection belongs to the app rather than the Remote screen. A foreground connection service keeps native keepalives running when browsing or backgrounded; an OS process kill requires reopening the app. Disconnect disables automatic reconnect; Forget removes local pairing. TV Forget paired phones revokes clients. Pairing preferences are excluded from backup.

Continue on phone now uses the actual playing TV stream and required headers, exposing it through a token-gated TV proxy. The proxy rewrites HLS children, preserves range requests and rejects unregistered targets. This supports TV-local streams and header-locked sources without separately resolving a mobile provider. DRM is explicitly rejected. Phone and TV need a shared reachable LAN for video handoff, even if controls use Bluetooth. Continue on TV resumes the matching session and position. Stopping the receiver or forgetting phones stops the sharing proxy.

## Protocol and scope

BetaLink receives bounded JSON over local TCP or secure Bluetooth RFCOMM. Discovery uses NSD plus bounded UDP broadcast on port 41285. Initial PIN authentication uses a nonce/HMAC challenge and provisions a random per-client credential. Future connections authenticate with that credential. Wi-Fi control is a local TCP prototype without TLS; it is not an Internet-facing service.

Requests have increasing connection-local IDs and app-scoped allowlisted actions. Commands are serialized, rate limited and never automatically replayed after connection loss. No shell, ADB, arbitrary intents or peer-provided stream URL execution. TV source installation remains separate from the original app. Native TV playback is the supported receiver; other playback engines are not controlled. Bluetooth performance depends on actual hardware.

## Validation

0.2.0 release was installed on both devices; user confirmed fast controls and working discovery.

0.3.0: 35 Flutter tests passed, including 320x640 and 360x800 non-scrolling remote layout, D-pad/player commands, dock migration, request serialization, and a local HTTP handoff test covering TV headers, redirected HLS, byte-range seeking and unknown-target rejection. Full Dart lib analysis completed with informational lints and no errors or warnings. Isolated native transport/service compilation passed against Android 35 with Flutter/scanner stubs; the release build validates actual dependencies.

Pending on-device verification for 0.3.0: saved reconnect after page changes and app restart, QR scanning, Bluetooth reconnect, Continue on phone with the user's source and resume back to TV, voice search and Remote mode playback. Build success does not establish these as verified.

## Build

Run tool/build_beta.ps1 for optimized release 0.3.0 build 3, ARMv7 and ARM64. Existing caches and eight Gradle workers are used. Output is outputs/Zangetsu-Beta-0.3.0.apk in the workspace. Install to your own authorized phone and TV using their ADB device identifiers. Never replace the original package.

## Version 0.4.0 — Bluetooth-first combined remote

User approved the Drift feature list and reversed transport preference: Bluetooth is primary, Wi-Fi is fallback. Standard Android TV keys use a Bluetooth HID service adapted from the user's Drift source. Companion RPC maintains independent authenticated Bluetooth RFCOMM and Wi-Fi sockets, independent sequence counters, Bluetooth-first selection, and read-only standby keepalives. A failed command is never replayed over the other transport; subsequent commands use the available route. Switching TVs releases the previous HID target. Automatic Bluetooth association uses an existing verified device mapping, or a unique matching bonded name validated against the companion's device ID before saving the association. Ambiguous/missing mappings use Manage > Bluetooth remote once.

The notification and phone volume keys route through the same controller. Added TV Home/Menu/Power, speaker volume/mute, alternate Back/Escape, general media controls and Stop. D-pad commands send on pointer-down and release on pointer-up/cancel; HID preserves real held-key behaviour. Phone volume keys are scoped to the visible Remote screen so the manga reader and ordinary phone volume retain their behaviour elsewhere. Artificial per-tap delays and the receiver's "Please slow down" response are removed. Whole-TV commands require HID; Wi-Fi fallback supports companion navigation/playback and TV speaker volume, not system Home/Power outside the app.

Receiver activity lifecycle state distinguishes the foreground Zangetsu app/player from a background process. The phone presents Zangetsu controls only when available. Skip Intro uses the same episode intervals as the TV button. Mega Skip uses the existing enabled setting and jump duration. TV setting changes update the native player; phone skip-setting edits while the app is running are forwarded when the companion reconnects. Remote buttons render the receiver's current settings. No separate remote skip configuration.

QR credentials persist until Forget paired phones; the QR and optional manual code no longer expire. Initial manual-code guessing has a resetting attempt window; it does not throttle remote controls. Forget rotates the QR credential and revokes companion clients. Android Bluetooth pairing remains a one-time OS setup when the devices are not already paired. Android allows one HID app owner, so users must disconnect Drift before enabling Beta HID; Beta reports this instead of taking over silently.

Validation: native Kotlin and the Java HID service compiled against actual dependencies. Twenty-five Flutter tests cover compact layout (including both skip controls), touch-down dispatch/release, settings-driven button changes, hiding rich controls outside the TV app, release bypassing pending RPC, dock migration, and stream-proxy behaviour. Device behaviour remains pending: HID registration/coexistence, automatic radio association, Bluetooth-first RPC, Wi-Fi fallback, notification and volume-key controls, QR persistence and skip settings. No power/standby claim is made without TV testing.

## Version 0.5.0 remote corrections

- Compact contextual remote: D-pad, Back, Home and volume outside the app; Search while browsing; episode/progress, playback and settings-linked skips only during TV playback. Management holds power and pairing. Removed Menu, Stop and Alternate Back from the remote UI.
- HID taps release natively after 25 ms. Only deliberate holds repeat after 450 ms. Pointer ownership prevents secondary touches from issuing duplicate commands; no rate limit on separate taps.
- Next/Previous and 10-second seeks always use explicit companion playback commands rather than generic HID media keys. Background companion failures preserve a live HID connection and do not produce the old connection-change banner.
- Notification offers volume down/up, rewind 10 seconds, current play/pause and forward 10 seconds; playback actions disappear outside TV playback. Background state refresh is bounded to one pending probe.
- TV settings retain focusable rows when scrolled and reveal the QR section on focus.
- Validation: 25 existing focused Flutter tests passed; 8 remote regression tests passed, including rapid multi-touch taps and background connection failure; TV settings down/up focus regression passed separately. Native release Kotlin/Java compilation passed; companion Dart analysis found informational style lints only. Render reviewed at phone size and layout checked at 320x640 and 360x800.
- Not installed or verified on physical devices yet. TV/phone playback and Bluetooth behaviour require testing after installation. Bluetooth remains primary, Wi-Fi companion fallback.

## Version 0.6.0 responsive remote layout

- Replaced the playback options menu with six labelled square shortcuts under Back/Home: Phone, Episodes, Sources, Quality, Audio, Subtitles. Each opens its existing action directly. Continue on TV remains available in Manage when opened from phone playback.
- Shared portrait height budget across dock and full-screen routes keeps the D-pad consistent on the same phone. Width and available height still constrain the layout; a short wide viewport uses two columns. Safe insets remain handled by the screen. Playback-only actions stay contextual and volume remains visible.
- Fifteen remote Flutter checks passed, including 320x640, 360x800, 390x844, 430x932, 800x600 and 800x400, equivalent D-pad sizes between routes, 1.3x text with top/bottom insets, direct shortcut callbacks, and prior pointer/connection/TV focus regressions. Golden phone preview inspected. Targeted Dart analysis has informational style lints only, no errors or warnings.
- Release build started; no scheduled checks, per user instruction. This version is not installed or verified on physical devices yet. No transport changes in this version.

## 0.7.0
Remote-tab playback controls now use the space above the dock while preserving a common D-pad budget. Added Android remote MediaSession integration and Apple shared Wi-Fi receiver/client source plus iOS Live Activity quick access. Apple packages are intentionally unbuilt and untested on devices; see REMOTE_COMPATIBILITY.md. Forty Flutter checks pass; Android release native compilation passes. Device instrumentation requires an uncached test dependency and has not run.
