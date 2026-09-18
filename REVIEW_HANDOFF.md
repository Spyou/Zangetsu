# Review handoff

## Disclosure
Codex substantially wrote/refactored the remote, transport bridges, platform integration, tests and documentation. Human understanding, ownership/permission confirmation and final review remain required. The contributor must accept the CLA themselves; no acceptance was posted by the assistant.

## Identity changes
Review source uses Zangetsu with upstream Android com.spyou.watch_app and Apple com.spyou.zangetsu identifiers. The extension uses com.spyou.zangetsu.remoteactivity. Standard Android authentication/share links were restored to zangetsu; the companion QR scheme remains zangetsu-beta for compatibility with the existing protocol. Upstream update behaviour is restored. No renamed/reidentified build has been installed. Maintainers must choose release version/signing and assess data migration. The development helper tool/build_beta.ps1 now uses the pubspec version and writes Zangetsu-review.apk; it does not select an official release version or signing key.

## Validation
The prior Beta 0.7.0 APK compiled and was installed on phone and TV. Forty focused Flutter checks passed previously. A full flutter analyze run during review found 310 informational findings, with no error/warning lines; it did not pass cleanly. Findings include pre-existing code and need baseline comparison before attributing them. Do not claim full lint compliance. Apple builds remain explicitly unbuilt. Android MediaSession instrumentation has not run because an offline dependency was missing. No claim of clean upstream CI is made.

## Required provenance work
NOTICE.md identifies the new Android dependencies and unresolved Drift/Sinotec HID and test-video provenance. These are merge blockers until verified, licensed compatibly, replaced or removed. No license or permission has been invented. The pubspec.lock changes also reflect the development Flutter SDK's dependency resolution and should be reconciled with upstream's chosen toolchain.

## Security review targets
- BetaLink.kt, BetaSocket.kt, companion_wire.dart and apple_companion.dart: challenge/proof verification, persistent pairing, brute-force protection, frame bounds, sequence validation and cancellation.
- BetaRemoteBridge.kt, BetaConnectionService.java and Apple AVKit bridge: capability gating, lifecycle/foreground state, system keys, duplicate/replayed actions and transport switching.
- cast_proxy.dart and beta_catalogue.dart: untrusted stream headers/URLs, redirects, token scoping, HLS rewrites, range handling and cleanup on revoke/disconnect.
- Android manifests/backup exclusions and Apple Keychain/local-network/Bonjour permissions.
Wi-Fi TCP is authenticated but not TLS-encrypted; persistent QR/PIN credentials and local-network trust assumptions need explicit maintainer approval. The above is a review checklist, not a completed security audit.

## Integration and device work
Rebase or selectively integrate against current upstream main without overwriting newer changes. Split the large contribution if requested, link the prior feature discussion, fill the PR template, disclose AI assistance and run upstream CI. Verify Android reconnect, sleep/wake, fallback, episode selection, handoff, rapid inputs, background media and OEM island presentation. Build/test iOS and tvOS on macOS, including signing and the Live Activity extension; verify all four phone/TV combinations. iOS activity currently offers quick access, not inline playback commands.

Latest review checks: all 40 focused Flutter tests passed again after the source identity changes. Android manifest and Apple plist XML parsed successfully; git diff whitespace checks passed. No native package rebuild was performed for these identity changes.
