# Remote compatibility — Beta 0.7.0

## Implemented paths

The phone and TV share the version-1 authenticated JSON-line Wi-Fi protocol. The intended pairings are Android phone → Android TV, Android phone → Apple TV, iPhone/iPad → Android TV, and iPhone/iPad → Apple TV. Local protocol tests cover the Apple Dart receiver/client and the Android-compatible handshake; this is not a claim of Apple device verification.

Android keeps its existing Bluetooth HID and RFCOMM paths, with Wi-Fi companion fallback. Apple uses Wi-Fi, Bonjour discovery, QR/manual pairing and Keychain-backed remembered credentials. No private Apple Bluetooth APIs or background silent audio are used.

## Platform limits

- iPhone/iPad controls the TV while Zangetsu is open. Android HID system Home/Power and whole-TV navigation are not provided by iOS. Apple TV's native AVKit playback uses the explicit playback controls; native AVKit D-pad navigation is disabled in the companion UI. Flutter catalogue/settings navigation remains available.
- Apple TV reports player volume, not television-speaker/HDMI volume. It is unavailable when no player is open; the volume controls remain visible but disabled. Adaptive quality stays automatic in AVKit; Sources can still select an alternate stream. Audio categories and embedded/provider subtitles are exposed.
- Android publishes an actual remote MediaSession with title, episode, duration, position, play/pause, seek, next/previous and remote volume. Compatible system media panels or manufacturer islands may display it. Manufacturer presentation is not guaranteed and has not yet been checked on the user's Honor.
- iOS 16.2+ has a WidgetKit Live Activity/Dynamic Island **quick-access** extension. It shows the TV title/episode and opens the app. It does not offer background inline playback buttons. Snapshots become stale after two minutes without updates; the UI tells the user to reconnect. No APNs service is added, so it does not promise uninterrupted updates while iOS suspends the app.
- All Apple runner, AVKit, Bonjour, camera, Keychain, signing and Live Activity changes remain source-only and unbuilt. The user explicitly requested no Apple SDK/toolchain downloads or Apple package builds. Community members must select their signing team for the app and extension and build/test on macOS/Xcode before claiming support.

## Android/shared checks performed

- 40 focused Flutter tests passed: six viewport sizes; safe insets and larger text; shortcut routing; identical D-pad sizes across entry routes; tab playback anchored above the dock; rapid multi-touch taps; connection-failure handling; TV focus navigation; proxy/navigation preferences; HMAC, fragmented frames, sequence failures, oversized-frame rejection and remembered pairing.
- Release Kotlin/Java compilation passed, including the new Android media-session implementation.
- Dart analysis found informational style lints only, with no errors or warnings at the recorded check.
- A native MediaSession instrumentation regression was added for metadata, remote volume routing and playing/paused/stopped state. Compilation/execution status must be recorded separately; adding the test is not proof it ran.

## Community verification before release

1. Build iOS and tvOS, including the BetaRemoteActivity extension; resolve any compiler/signing differences with the project's tvOS Flutter toolchain.
2. Exercise each of the four phone/TV combinations: QR/manual pairing, reject wrong secrets, reconnect, changed IP/Bonjour, disconnect, forget, sleep/wake and local-network permission denial.
3. Check catalogue D-pad/OK/Back, remote-mode search and playback, Next/Previous, seek, source/audio/subtitle changes, settings-linked skips, phone/TV handoff, and stale option rejection.
4. Check iOS Live Activity permission, foreground/background transitions, stale state, tapping back into the app, and ending the activity on disconnect.
5. Check Android system media controls and the manufacturer's island with real TV playback, including other music apps and local phone playback. Do not infer OEM support from successful compilation.

Beta identity remains separate from upstream: com.serenity.zangetsu.beta; Live Activity extension com.serenity.zangetsu.beta.remoteactivity. This fork is published separately from the upstream project. No upstream pull request is implied.

Platform references: https://developer.android.com/reference/android/media/session/MediaSession ; https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy ; https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities .

Additional check: Android instrumentation-test compilation could not finish offline because a Firebase test dependency is not cached. The device test has not been executed.
