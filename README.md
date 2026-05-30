# WATCH_APP

Standalone Flutter anime streaming app (sibling to Sozo Read). Source catalog
grows via hosted JS providers + per-host extractors — no app update needed.

> **Renaming:** the product name lives in one place — `kAppName` in
> `lib/core/app_config.dart`. Final rename = find/replace the token `WATCH_APP`
> across the repo + a bundle-id rename.

## Status

- **P0/P1 (done):** content runtime (single QuickJS runtime, video provider
  contract, extractor registry), video-native models, bundled example provider
  + extractor proving `search → getDetail → getEpisodes → getVideoSources →
  extractVideo`.
- **Next:** P2 real extractors · P3 `media_kit` player · P4 repos UI + manifest
  v2 · P5 library/history · P6 downloads · P7 sync/notifications.

## Testing

```bash
flutter test                            # Dart model tests
node --test js_harness/contract.test.mjs   # JS provider/extractor contract (offline, deterministic)
```

## Running the dev slice

`lib/dev/dev_slice_screen.dart` runs the full content-runtime slice against the
bundled `example` provider on a real device/emulator and shows the result.
Launch with `flutter run` — expect the screen to end with `✅ SLICE OK`.

## Authoring sources

Copy `providers/_template.js` → `providers/<id>.js` (fill the five functions),
or `extractors/_template.js` → `extractors/<host>.js` (fill `extract`). The
contract is defined in `lib/core/provider/base_provider.dart`.
