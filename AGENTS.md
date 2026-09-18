# Zangetsu Beta prototype

- User-required display name: **Zangetsu Beta**, on TV and phone.
- Android application ID: `com.serenity.zangetsu.beta`. Never install experimental builds over `com.spyou.watch_app`.
- Keep the upstream namespace for existing Kotlin classes; Android application ID provides installation/data separation.
- Disable upstream APK updates in this fork. Preserve license and attribution files.
- User-authorized extension: system remote keys use Bluetooth HID; the companion also exposes allowlisted TV speaker volume/mute. Other companion commands remain app-scoped and allowlisted. Do not add shell, ADB, arbitrary intents, file access, or arbitrary URL execution to the protocol.
- Wi-Fi and Bluetooth share the same receiver/player actions. The TV resolves sources.
- Real-device verification is required before claiming connectivity or playback works. Distinguish compiled, installed, and verified features.
- Do not publish a PR or contact upstream maintainers unless the user requests it.
