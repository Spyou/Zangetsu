# Zangetsu Beta

A phone-and-TV companion fork of [Spyou/Zangetsu](https://github.com/Spyou/Zangetsu), developed in [Serenity-MIST/Zangetsu](https://github.com/Serenity-MIST/Zangetsu).

Zangetsu provides discovery, sources, playback, libraries, manga and novels. This fork adds connected remote control: browse on your phone, play on your TV, and continue an episode between devices. The original credits and license remain in place; see the [upstream README](UPSTREAM_README.md).

**Current prototype: Beta 0.7.0, build 7.** The Android APK was built and installed on an Android phone and Android TV. Apple support is source-only and needs community builds and device testing. This is an experimental fork, not an upstream release or a promise of universal compatibility.

## The development journey

The project started as a simple phone-to-TV remote. Real-device feedback about discovery, connection persistence, TV performance, cluttered layouts, repeated movement and playback handoff shaped each iteration.

| Stage | Changes |
| --- | --- |
| Initial prototype | Separate Beta identity, Android TV companion, phone controls, Wi-Fi discovery, Bluetooth transport and Android build/install workflow. |
| 0.3 | Remote tab before Profile, circular D-pad, remembered pairing, text/Android voice search, optional browse-on-phone Remote mode, and stream-based Continue on phone/TV. |
| 0.4 | Bluetooth first, Wi-Fi fallback; Android HID system navigation; foreground app/player detection; persistent QR pairing; settings-linked Intro/Mega Skip; artificial per-tap throttling removed. |
| 0.5 | Contextual controls, duplicate-tap and held-key corrections, explicit Next/Previous episode commands, quieter transport transitions, notification actions, and TV settings focus/scroll fixes. Menu, Stop and Alternate Back removed from the main remote. |
| 0.6 | Six labelled square shortcuts; consistent D-pad sizing across entry routes; compact portrait/landscape layouts; safe-inset and larger-text checks. |
| 0.7 | Playback/volume moved lower above the mobile dock; Android remote MediaSession; shared Apple Wi-Fi companion source; Apple TV AVKit control bridge; iOS Live Activity quick access. |

[BETA_IMPLEMENTATION.md](BETA_IMPLEMENTATION.md) records the implementation history. Its older entries describe status at that time, not the current version's verification status.

## Current remote experience

- Integrated dark/coral styling and a Remote tab between Sources and Profile in the default mobile navigation.
- Non-scrolling main controls that adapt to available phone space, with a two-column arrangement for short wide screens.
- D-pad, Back, supported Home and volume for navigation. Playback controls appear when the TV reports an active player. Volume stays visible; unsupported operations are disabled or omitted.
- Six direct shortcuts below Back/Home: Phone, Episodes, Sources, Quality, Audio and Subtitles, subject to receiver capabilities.
- Play/pause, timeline seeking, ten-second seeks and explicit episode navigation. Skip Intro follows the episode interval; Mega Skip follows the app's enabled setting and duration. No separate remote skip configuration.
- Separate fast taps are not artificially throttled. Pointer ownership, key release and deliberate-hold handling address intermittent repeated movement. Uncertain commands are never blindly replayed over another transport.
- Text search and available Android voice recognition. Optional Remote mode lets you browse normally on the phone, then asks the TV to resolve and play the selection. The traditional remote remains available.

## Pair once, reconnect later

Enable the receiver in TV remote settings and scan its QR from the phone. Discovery/manual pairing are alternatives. QR/manual credentials persist until revoked: no expiry countdown. Remembered client credentials support reconnecting without another scan. Disconnect disables automatic reconnect; Forget removes pairing. The TV can revoke paired phones.

Android prefers Bluetooth with Wi-Fi companion fallback. Bluetooth HID handles supported system navigation; authenticated companion messages carry app actions. Automatic Bluetooth association reuses a verified mapping or an unambiguous bonded-device match. Initial OS pairing and ambiguous matches still need user selection. Another HID remote app may need to disconnect first.

Connections belong to the app rather than a page. Android uses a foreground connection service; reopening can still be necessary after an OS process kill. A failed command is not replayed blindly during transport switching.

## Continue watching between phone and TV

The Android receiver shares its current stream and required headers through a token-gated local proxy. HLS rewriting and byte-range requests let the phone resume without finding an equivalent mobile source. Unregistered targets and DRM streams are rejected. Continue on TV returns the episode and playback position.

A reachable shared LAN is required for proxy handoff even when controls use Bluetooth. Apple handoff paths remain unverified and need real-provider testing. Not every source or playback engine is guaranteed to work across devices.

## Android and Apple combinations

| Phone | TV | Status |
| --- | --- | --- |
| Android | Android TV | Main development path; earlier controls confirmed working on hardware. 0.7.0 built and installed; full regression testing still needed. |
| Android | Apple TV | Shared Wi-Fi protocol and receiver source implemented; Apple build/device testing pending. |
| iPhone/iPad | Android TV | Wi-Fi client, discovery and pairing source implemented; Apple build/device testing pending. |
| iPhone/iPad | Apple TV | Client and receiver source implemented; Apple build/device testing pending. |

Apple uses Wi-Fi/Bonjour and Keychain-backed credentials. Android HID/RFCOMM is not presented as an Apple transport. iPhone does not offer Android-style whole-TV Home/Power. Apple TV AVKit uses explicit playback actions rather than companion D-pad navigation; Flutter catalogue navigation remains available. Apple TV volume is player volume, not HDMI/speaker control; quality remains adaptive/automatic.

**No iOS or tvOS packages were built during this work.** Community contributors must build/test the app, receiver and extension on macOS/Xcode, configure signing and verify permissions. See [REMOTE_COMPATIBILITY.md](REMOTE_COMPATIBILITY.md) for limitations and the four-way test checklist.

## Background controls and islands

Android notification controls include volume, ten-second seeking and play/pause. A real remote MediaSession publishes title, episode, progress and playback state for compatible system media panels or manufacturer islands. Exact Honor/Magic Capsule or other OEM presentation is not guaranteed and has not been verified for 0.7.0. No silent audio is played to imitate a music app.

iOS 16.2+ source includes Live Activity/Dynamic Island quick access showing the TV title/episode and opening the app. It does **not** include inline background playback buttons. There is no push-update service; information may become stale when iOS suspends the app and is marked stale after two minutes. This extension remains unbuilt and unverified.

## Validation and remaining work

- 40 focused Flutter checks passed: responsive layout, insets/larger text, shortcuts, rapid touches, connection failures, TV focus, proxy behaviour, pairing proofs and bounded/ordered protocol frames.
- Layouts checked at 320x640, 360x800, 390x844, 430x932, 800x600 and 800x400; rendered preview reviewed.
- Android release Kotlin/Java compilation and the APK build succeeded. Both development devices were verified installed with version 0.7.0/build 7.
- Targeted Dart analysis reported informational style lints, with no errors or warnings at the recorded check.
- A MediaSession device regression test was added but has not run: offline test compilation needed an uncached Firebase dependency.
- Installation is not full feature verification. Apple builds, mixed-device pairings, sleep/wake, background media, OEM islands and provider-specific handoff need community testing.

## Build Android

Use Flutter, Android SDK and a compatible JDK. Development used Flutter 3.44/Dart 3.12 and the Android Studio JDK. Follow the upstream setup documentation for integrations and source dependencies.

```sh
flutter pub get
flutter build apk --release --target-platform android-arm,android-arm64 --build-name 0.7.0 --build-number 7
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. The optional `tool/build_beta.ps1` helper assumes sibling Flutter/cache directories from the development workspace; they are not prerequisites for the standard command.

The name is **Zangetsu Beta**, Android ID `com.serenity.zangetsu.beta`, separate from the original app. Upstream automatic APK updates are disabled. Configure your own signing key for distribution; without release configuration the Android project falls back to debug signing. Never commit signing keys or local credentials. Updates to your own installs must use the same signing key.

## Protocol and privacy

The local companion uses bounded ordered messages, nonce/HMAC authentication and per-client credentials. Actions are allowlisted: no ADB bridge, arbitrary shell commands, intents, filesystem access or peer-supplied URL execution. Pairing data is excluded from Android backups; Apple uses Keychain. Revoking clients stops Android stream sharing.

Wi-Fi control is a local TCP prototype without TLS. Use a trusted local network and do not expose the receiver to the Internet. Authentication does not encrypt commands or stream content.

## Credits and contributing

The application, design and source ecosystem come from [Spyou/Zangetsu](https://github.com/Spyou/Zangetsu) and its contributors. Remote interaction was informed by the Drift/Sinotec prototype. Existing third-party notices and the [license](LICENSE) remain applicable.

Reports should include phone/TV OS, app version, transport and reproducible steps. Community help is especially needed with Apple builds, mixed-platform pairing and background media behaviour. Do not include pairing secrets, private stream URLs or signing material.
