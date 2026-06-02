# Downloads Feature — Spec

**Goal:** Let users download episodes/movies for offline playback, choosing quality and scope (all season / range / single), with true background downloads saved to the public Downloads folder.

**Decisions (agreed):**
- **Scope:** Phase 1 = direct-file (MP4/MKV) sources only. Phase 2 = HLS (segment downloader + local playlist + AES keys). HLS-only episodes show "Not available offline yet" in phase 1.
- **Storage:** Public `Download/Zangetsu/<Show>/` (Android via MediaStore/SharedStorage). iOS = app Documents (no true public Downloads on iOS).
- **Background:** True background via `background_downloader` (progress notification, survives app close, pause/resume/cancel).
- **Quality:** User picks quality/mirror in the sheet.
- **Access point:** A "Downloads" tile in Settings.

## Architecture

- **`core/download/download_record.dart`** — model persisted in Hive box `downloads`: `taskId, sourceId, showId, showTitle, cover, coverHeaders, showUrl, episodeId, episodeNumber, episodeTitle, quality, container, status, progress, bytesTotal, filePath, error, createdAt`. `status ∈ {queued, resolving, downloading, paused, done, failed, unsupported, canceled}`.
- **`core/download/download_manager.dart`** — singleton (DI). Wraps `FileDownloader`; owns the Hive box; exposes a `ValueListenable`/stream of records for the UI. Responsibilities:
  - `enqueueEpisode(...)`: resolve provider sources → filter to direct-file → pick quality → create + enqueue a `DownloadTask` (with headers) → persist a record.
  - Listen to `FileDownloader.updates` → update record progress/status → on complete `moveToSharedStorage(SharedStorage.downloads, directory: 'Zangetsu/<Show>')` and store final path.
  - `pause/resume/cancel/delete(record)`; `recordsFor(showId)`, `all()`.
  - Source resolution reuses `SourceRepository.sources(url, sourceId, category)`; direct-file = `container == mp4` or url path ends `.mp4/.mkv/.webm` and not `.m3u8`.

## UI

- **Detail screen:** main Download button → `_DownloadSheet` (step 1: quality from a sample resolve or 1080/720/480/best; step 2: All / Range(1–N) / This episode). Per-episode download icon enqueues one episode and the row reflects status (progress ring / ✓ done / "—" unsupported).
- **Downloads library** (`features/downloads/downloads_screen.dart`): grouped by show; per item progress + pause/resume/cancel/delete; tap a `done` item → offline playback. Reached from a Settings tile.
- **Offline playback:** launch `PlayerScreen` with a `resolveSources` that returns a single `VideoSource(url: localPath, container: mp4)`. Resume + history unchanged.

## Native setup

- Android: `POST_NOTIFICATIONS` permission; background_downloader manifest hooks (mostly automatic). MediaStore Downloads needs no legacy storage permission on API 29+.
- iOS: background URLSession (plugin-managed); files surface in the Files app via Documents.
- ⚠️ Adding the native plugin requires a **full rebuild** (not hot restart).

## Build order

1. Deps + native config + permissions.
2. `download_record` + `download_manager` + DI registration.
3. Detail `_DownloadSheet` + per-episode icon wiring + row status.
4. Downloads library screen + Settings entry.
5. Offline playback.

## Out of scope (phase 1)

HLS offline; per-episode synopsis; cross-device sync of downloads (local only).
