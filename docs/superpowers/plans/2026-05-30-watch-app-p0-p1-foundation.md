# WATCH_APP Foundation (P0 + P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the new WATCH_APP Flutter project with the ported, source-agnostic JS provider runtime and a video-native data model, proven end-to-end by a bundled example provider + extractor that flow `search → getDetail → getEpisodes → getVideoSources → extractVideo`.

**Architecture:** Port Sozo Read's single-QuickJS-runtime provider system (one runtime hosting every provider at `__providers[sourceId]`, fetch bridged to Dart Dio) into a fresh project. Replace the manga leaf (`getPages` → image URLs) with the video leaf (`getEpisodes` + `getVideoSources` → `VideoSource[]`) and add a hosted **extractor** layer (`__extractors[host]` + a shared `extractVideo(url)` dispatcher). The JS contract is validated offline/deterministically in a Node test harness; Dart models are validated with `flutter test`.

**Tech Stack:** Flutter (Dart 3.11), `flutter_js` (QuickJS), `dio`, `hive`/`hive_flutter`, `equatable`, `json_serializable`/`json_annotation`, `get_it`. Node ≥ 18 for the JS contract harness. (`media_kit`, `supabase`, downloads, etc. arrive in later phase plans.)

**Scope note:** This is Plan 1 of the phased build (see the design spec, §"Build phasing"). It delivers P0 (scaffold) + P1 (content runtime + models + bundled provider). P2 (more extractors), P3 (`media_kit` player), P4 (repos UI), P5–P7 (library/history/downloads/sync) are separate plans.

**Refinement vs spec:** `VideoSource`'s container field is named **`container`** (`'hls'`/`'mp4'`) in both the JS wire shape and Dart, not `type` — to avoid overloading `type`, which already means `'anime'`/`'movie'` on `MediaItem`. `kind` (`'sub'`/`'dub'`) is unchanged. All else matches the spec.

---

## File structure (created by this plan)

```
watch_app/
  pubspec.yaml                                    # MODIFY: add deps + asset entries
  lib/
    core/
      app_config.dart                             # kAppName single rename point + constants
      error/exceptions.dart                       # ported exception types
      models/
        provider_info.dart  (+ .g.dart)           # ProviderInfo + ProviderType
        media_item.dart     (+ .g.dart)           # MediaItem
        media_detail.dart   (+ .g.dart)           # MediaDetail + MediaStatus
        episode.dart        (+ .g.dart)           # Episode
        video_source.dart   (+ .g.dart)           # VideoSource + Subtitle + enums
      provider/
        base_provider.dart                        # Dart mirror of the video JS contract
        js_bootstrap.dart                         # kJsBootstrap + wrapProviderSource + wrapExtractorSource
        provider_manager.dart                     # _JsHost + JsProvider + ProviderManager
        provider_downloader.dart                  # JS file download + Hive cache
      di/injector.dart                            # get_it wiring + Hive init
    dev/dev_slice_screen.dart                     # throwaway screen that runs the vertical slice
    main.dart                                     # MODIFY: init + launch dev slice
  providers/
    _template.js                                  # provider authoring template
    example.js                                    # bundled deterministic example provider
  extractors/
    _template.js                                  # extractor authoring template
    example_embed.js                              # bundled deterministic example extractor
  js_harness/
    host.mjs                                      # Node mirror of the runtime (bootstrap + wrap)
    contract.test.mjs                             # node:test suite exercising the full slice
  test/
    models/
      provider_info_test.dart
      media_item_test.dart
      video_source_test.dart
      episode_test.dart
      media_detail_test.dart
```

---

## Task 1: Project dependencies, app config, and folders (P0)

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/app_config.dart`
- Create: `lib/core/error/exceptions.dart`

- [ ] **Step 1: Add dependencies to `pubspec.yaml`**

Replace the `dependencies:` and `dev_dependencies:` blocks with:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8

  # State / value equality
  equatable: ^2.0.7

  # DI
  get_it: ^8.0.3

  # Network
  dio: ^5.8.0+1

  # Local storage
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  path_provider: ^2.1.5

  # JS engine (QuickJS bridge)
  flutter_js: ^0.8.0

  # JSON
  json_annotation: ^4.11.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  build_runner: ^2.4.13
  json_serializable: ^6.9.0
```

Under the `flutter:` section, add the bundled JS assets:

```yaml
flutter:
  uses-material-design: true
  assets:
    - providers/example.js
    - extractors/example_embed.js
```

- [ ] **Step 2: Fetch packages**

Run: `cd "/Users/krishnavishwakarma/Programming Playground/watch_app" && flutter pub get`
Expected: `Got dependencies!` with no version-solve errors.

- [ ] **Step 3: Create `lib/core/app_config.dart`**

```dart
/// Single source of truth for the product name. Final rename = one
/// find/replace on the token `WATCH_APP` across the repo, plus a bundle-id
/// rename (`flutter pub run rename` or manual android/ios edits).
const String kAppName = 'WATCH_APP';

/// Stable application id embedded in default provider-repo manifests and
/// checked by the repo guard so a manga-only (Sozo) repo can't be added.
const String kAppId = 'watch_app';

/// Manifest schema version this app speaks. Repos below this are rejected.
const int kManifestSchemaVersion = 2;
```

- [ ] **Step 4: Create `lib/core/error/exceptions.dart`**

```dart
/// Thrown when the JS runtime or a provider call fails.
class ProviderException implements Exception {
  ProviderException(this.message);
  final String message;
  @override
  String toString() => 'ProviderException: $message';
}

/// Thrown when the embedded QuickJS runtime rejects an eval or a call.
class JsRuntimeException implements Exception {
  JsRuntimeException(this.message);
  final String message;
  @override
  String toString() => 'JsRuntimeException: $message';
}

/// Thrown when a network download (provider/extractor JS, manifest) fails.
class NetworkException implements Exception {
  NetworkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'NetworkException($statusCode): $message';
}
```

- [ ] **Step 5: Verify the project still analyzes**

Run: `flutter analyze lib/core/app_config.dart lib/core/error/exceptions.dart`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/core/app_config.dart lib/core/error/exceptions.dart
git commit -m "chore(p0): add content-layer deps, app config, exceptions"
```

---

## Task 2: ProviderInfo + ProviderType model (TDD)

**Files:**
- Create: `lib/core/models/provider_info.dart`
- Test: `test/models/provider_info_test.dart`

- [ ] **Step 1: Write the failing test**

`test/models/provider_info_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('ProviderInfo round-trips anime type', () {
    final json = {
      'name': 'Example',
      'lang': 'en',
      'baseUrl': 'https://example.test',
      'logo': 'https://example.test/logo.png',
      'type': 'anime',
      'version': '1.0.0',
    };
    final info = ProviderInfo.fromJson(json);
    expect(info.name, 'Example');
    expect(info.type, ProviderType.anime);
    expect(info.toJson()['type'], 'anime');
  });

  test('ProviderInfo defaults unknown type to anime-safe parse', () {
    final info = ProviderInfo.fromJson({
      'name': 'X', 'lang': 'en', 'baseUrl': 'https://x.test', 'type': 'movie',
    });
    expect(info.type, ProviderType.movie);
    expect(info.logo, isNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/models/provider_info_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:watch_app/core/models/provider_info.dart'`.

- [ ] **Step 3: Write the model**

`lib/core/models/provider_info.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'provider_info.g.dart';

/// Content kind a provider serves. `anime` ships now; `movie` is reserved
/// so the catalog can grow without a model change.
enum ProviderType {
  @JsonValue('anime')
  anime,
  @JsonValue('movie')
  movie,
}

@JsonSerializable()
class ProviderInfo extends Equatable {
  final String name;
  final String lang;
  final String baseUrl;
  final String? logo;
  final ProviderType type;
  final String? version;

  const ProviderInfo({
    required this.name,
    required this.lang,
    required this.baseUrl,
    this.logo,
    required this.type,
    this.version,
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) =>
      _$ProviderInfoFromJson(json);
  Map<String, dynamic> toJson() => _$ProviderInfoToJson(this);

  @override
  List<Object?> get props => [name, lang, baseUrl, logo, type, version];
}
```

- [ ] **Step 4: Generate the serializer**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: builds `provider_info.g.dart` with `succeeded`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/models/provider_info_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/provider_info.dart lib/core/models/provider_info.g.dart test/models/provider_info_test.dart
git commit -m "feat(p1): ProviderInfo model with anime/movie type"
```

---

## Task 3: MediaItem model (TDD)

**Files:**
- Create: `lib/core/models/media_item.dart`
- Test: `test/models/media_item_test.dart`

- [ ] **Step 1: Write the failing test**

`test/models/media_item_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('MediaItem parses a search row and injects sourceId', () {
    final item = MediaItem.fromJson({
      'id': 'one-piece',
      'title': 'One Piece',
      'cover': 'https://cdn.test/op.jpg',
      'coverHeaders': {'Referer': 'https://example.test/'},
      'url': 'https://example.test/anime/one-piece',
      'type': 'anime',
      'sourceId': 'example',
    });
    expect(item.id, 'one-piece');
    expect(item.type, ProviderType.anime);
    expect(item.coverHeaders!['Referer'], 'https://example.test/');
    expect(item.sourceId, 'example');
  });

  test('MediaItem tolerates a missing cover', () {
    final item = MediaItem.fromJson({
      'id': 'x', 'title': 'X', 'url': 'https://x.test',
      'type': 'anime', 'sourceId': 'example',
    });
    expect(item.cover, isNull);
    expect(item.englishTitle, isNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/models/media_item_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write the model**

`lib/core/models/media_item.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'provider_info.dart';

part 'media_item.g.dart';

/// One row in a search / browse listing. The video-native analogue of
/// Sozo Read's `BookItem`.
@JsonSerializable()
class MediaItem extends Equatable {
  final String id;
  final String title;

  /// Optional romanized / English alternative title. Null when the source
  /// doesn't provide one; UI falls back to [title].
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final ProviderType type;
  final String sourceId;

  const MediaItem({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    required this.url,
    required this.type,
    required this.sourceId,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) =>
      _$MediaItemFromJson(json);
  Map<String, dynamic> toJson() => _$MediaItemToJson(this);

  MediaItem copyWith({String? sourceId}) => MediaItem(
        id: id,
        title: title,
        englishTitle: englishTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        url: url,
        type: type,
        sourceId: sourceId ?? this.sourceId,
      );

  @override
  List<Object?> get props =>
      [id, title, englishTitle, cover, coverHeaders, url, type, sourceId];
}
```

- [ ] **Step 4: Generate the serializer**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: builds `media_item.g.dart`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/models/media_item_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/media_item.dart lib/core/models/media_item.g.dart test/models/media_item_test.dart
git commit -m "feat(p1): MediaItem model"
```

---

## Task 4: VideoSource + Subtitle models (TDD)

**Files:**
- Create: `lib/core/models/video_source.dart`
- Test: `test/models/video_source_test.dart`

- [ ] **Step 1: Write the failing test**

`test/models/video_source_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('VideoSource parses an HLS sub source with soft subtitles', () {
    final src = VideoSource.fromJson({
      'url': 'https://cdn.test/master.m3u8',
      'quality': '1080p',
      'container': 'hls',
      'headers': {'Referer': 'https://embed.test/'},
      'kind': 'sub',
      'audioLang': 'ja',
      'subtitles': [
        {'url': 'https://cdn.test/en.vtt', 'lang': 'en', 'label': 'English',
         'format': 'vtt', 'default': true},
      ],
    });
    expect(src.container, SourceContainer.hls);
    expect(src.kind, AudioKind.sub);
    expect(src.headers!['Referer'], 'https://embed.test/');
    expect(src.subtitles.single.isDefault, true);
    expect(src.subtitles.single.lang, 'en');
  });

  test('VideoSource defaults unknown enums and empty subtitles', () {
    final src = VideoSource.fromJson({'url': 'https://cdn.test/v.mp4'});
    expect(src.container, SourceContainer.unknown);
    expect(src.kind, AudioKind.unknown);
    expect(src.subtitles, isEmpty);
    expect(src.toJson()['url'], 'https://cdn.test/v.mp4');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/models/video_source_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write the model**

`lib/core/models/video_source.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'video_source.g.dart';

/// Stream container. `unknown` lets a provider omit the hint; the player
/// then sniffs by URL extension.
enum SourceContainer {
  @JsonValue('hls')
  hls,
  @JsonValue('mp4')
  mp4,
  @JsonValue('unknown')
  unknown,
}

/// Audio track intent for a source. Drives the sub/dub picker.
enum AudioKind {
  @JsonValue('sub')
  sub,
  @JsonValue('dub')
  dub,
  @JsonValue('raw')
  raw,
  @JsonValue('unknown')
  unknown,
}

@JsonSerializable()
class Subtitle extends Equatable {
  final String url;
  final String lang;
  final String? label;

  /// `'vtt'` or `'srt'`. Free-form so a source can pass through anything
  /// the player accepts.
  final String? format;

  @JsonKey(name: 'default', defaultValue: false)
  final bool isDefault;

  const Subtitle({
    required this.url,
    required this.lang,
    this.label,
    this.format,
    this.isDefault = false,
  });

  factory Subtitle.fromJson(Map<String, dynamic> json) =>
      _$SubtitleFromJson(json);
  Map<String, dynamic> toJson() => _$SubtitleToJson(this);

  @override
  List<Object?> get props => [url, lang, label, format, isDefault];
}

/// A single playable stream for an episode. The video-native analogue of
/// Sozo Read's `PageContent`. A provider returns a LIST of these; the UI
/// filters by [kind]/[audioLang]/[quality].
@JsonSerializable(explicitToJson: true)
class VideoSource extends Equatable {
  final String url;
  final String? quality;

  @JsonKey(unknownEnumValue: SourceContainer.unknown,
      defaultValue: SourceContainer.unknown)
  final SourceContainer container;

  final Map<String, String>? headers;

  @JsonKey(unknownEnumValue: AudioKind.unknown, defaultValue: AudioKind.unknown)
  final AudioKind kind;

  final String? audioLang;

  @JsonKey(defaultValue: <Subtitle>[])
  final List<Subtitle> subtitles;

  const VideoSource({
    required this.url,
    this.quality,
    this.container = SourceContainer.unknown,
    this.headers,
    this.kind = AudioKind.unknown,
    this.audioLang,
    this.subtitles = const [],
  });

  factory VideoSource.fromJson(Map<String, dynamic> json) =>
      _$VideoSourceFromJson(json);
  Map<String, dynamic> toJson() => _$VideoSourceToJson(this);

  @override
  List<Object?> get props =>
      [url, quality, container, headers, kind, audioLang, subtitles];
}
```

- [ ] **Step 4: Generate the serializer**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: builds `video_source.g.dart`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/models/video_source_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/video_source.dart lib/core/models/video_source.g.dart test/models/video_source_test.dart
git commit -m "feat(p1): VideoSource + Subtitle models with tagged sub/dub + tracks"
```

---

## Task 5: Episode model (TDD)

**Files:**
- Create: `lib/core/models/episode.dart`
- Test: `test/models/episode_test.dart`

- [ ] **Step 1: Write the failing test**

`test/models/episode_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';

void main() {
  test('Episode parses number, thumbnail, and filler flag', () {
    final ep = Episode.fromJson({
      'id': 'ep-1', 'title': 'Episode 1', 'number': 1.0,
      'url': 'https://example.test/watch/ep-1',
      'date': '2020-01-01', 'thumbnail': 'https://cdn.test/1.jpg',
      'filler': true,
    });
    expect(ep.number, 1.0);
    expect(ep.filler, true);
    expect(ep.thumbnail, 'https://cdn.test/1.jpg');
  });

  test('Episode defaults filler to false and tolerates missing number', () {
    final ep = Episode.fromJson({
      'id': 'ep-2', 'title': 'Episode 2', 'url': 'https://example.test/2',
    });
    expect(ep.number, isNull);
    expect(ep.filler, false);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/models/episode_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write the model**

`lib/core/models/episode.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'episode.g.dart';

/// One episode within a series. The video-native analogue of Sozo Read's
/// `Chapter` — same wire keys (`id/title/number/url/date`) plus two video
/// extras.
@JsonSerializable()
class Episode extends Equatable {
  final String id;
  final String title;
  final double? number;
  final String url;
  final String? date;
  final String? thumbnail;

  @JsonKey(defaultValue: false)
  final bool filler;

  const Episode({
    required this.id,
    required this.title,
    this.number,
    required this.url,
    this.date,
    this.thumbnail,
    this.filler = false,
  });

  factory Episode.fromJson(Map<String, dynamic> json) =>
      _$EpisodeFromJson(json);
  Map<String, dynamic> toJson() => _$EpisodeToJson(this);

  @override
  List<Object?> get props => [id, title, number, url, date, thumbnail, filler];
}
```

- [ ] **Step 4: Generate the serializer**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: builds `episode.g.dart`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/models/episode_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/episode.dart lib/core/models/episode.g.dart test/models/episode_test.dart
git commit -m "feat(p1): Episode model"
```

---

## Task 6: MediaDetail model (TDD)

**Files:**
- Create: `lib/core/models/media_detail.dart`
- Test: `test/models/media_detail_test.dart`

- [ ] **Step 1: Write the failing test**

`test/models/media_detail_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  test('MediaDetail parses status, studios, and nested episodes', () {
    final detail = MediaDetail.fromJson({
      'id': 'one-piece',
      'title': 'One Piece',
      'url': 'https://example.test/anime/one-piece',
      'description': 'Pirates.',
      'status': 'ongoing',
      'genres': ['Action', 'Adventure'],
      'studios': ['Toei'],
      'type': 'anime',
      'sourceId': 'example',
      'episodes': [
        {'id': 'ep-1', 'title': 'Episode 1', 'number': 1.0,
         'url': 'https://example.test/watch/ep-1'},
      ],
    });
    expect(detail.status, MediaStatus.ongoing);
    expect(detail.studios, ['Toei']);
    expect(detail.episodes.single.id, 'ep-1');
    expect(detail.type, ProviderType.anime);
  });

  test('MediaDetail defaults status unknown and empty lists', () {
    final detail = MediaDetail.fromJson({
      'id': 'x', 'title': 'X', 'url': 'https://x.test',
      'type': 'anime', 'sourceId': 'example',
    });
    expect(detail.status, MediaStatus.unknown);
    expect(detail.genres, isEmpty);
    expect(detail.episodes, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/models/media_detail_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write the model**

`lib/core/models/media_detail.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'episode.dart';
import 'provider_info.dart';

part 'media_detail.g.dart';

enum MediaStatus {
  @JsonValue('ongoing')
  ongoing,
  @JsonValue('completed')
  completed,
  @JsonValue('hiatus')
  hiatus,
  @JsonValue('cancelled')
  cancelled,
  @JsonValue('unknown')
  unknown,
}

/// Full series detail. The video-native analogue of Sozo Read's
/// `BookDetail` (chapters → episodes, authors → studios).
@JsonSerializable(explicitToJson: true)
class MediaDetail extends Equatable {
  final String id;
  final String title;
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final String? description;

  @JsonKey(unknownEnumValue: MediaStatus.unknown,
      defaultValue: MediaStatus.unknown)
  final MediaStatus status;

  @JsonKey(defaultValue: <String>[])
  final List<String> genres;

  @JsonKey(defaultValue: <String>[])
  final List<String> studios;

  @JsonKey(defaultValue: <Episode>[])
  final List<Episode> episodes;

  final ProviderType type;
  final String sourceId;

  const MediaDetail({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    required this.url,
    this.description,
    this.status = MediaStatus.unknown,
    this.genres = const [],
    this.studios = const [],
    this.episodes = const [],
    required this.type,
    required this.sourceId,
  });

  factory MediaDetail.fromJson(Map<String, dynamic> json) =>
      _$MediaDetailFromJson(json);
  Map<String, dynamic> toJson() => _$MediaDetailToJson(this);

  @override
  List<Object?> get props => [
        id, title, englishTitle, cover, coverHeaders, url, description,
        status, genres, studios, episodes, type, sourceId,
      ];
}
```

- [ ] **Step 4: Generate the serializer**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: builds `media_detail.g.dart`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/models/media_detail_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/media_detail.dart lib/core/models/media_detail.g.dart test/models/media_detail_test.dart
git commit -m "feat(p1): MediaDetail model with nested episodes"
```

---

## Task 7: Node harness + bundled example provider (TDD, pure JS)

This validates the JS **contract** (the exact shape the Dart host will call) offline and deterministically, before wiring the native QuickJS runtime. The harness mirrors `kJsBootstrap` + `wrapProviderSource`.

**Files:**
- Create: `js_harness/host.mjs`
- Create: `providers/_template.js`
- Create: `providers/example.js`
- Create: `js_harness/contract.test.mjs`

- [ ] **Step 1: Write the failing test**

`js_harness/contract.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

loadProvider('example', new URL('../providers/example.js', import.meta.url));

test('getInfo reports an anime provider', async () => {
  const info = JSON.parse(await callProvider('example', 'getInfo', []));
  assert.equal(info.type, 'anime');
  assert.equal(info.name, 'Example Anime');
});

test('search returns MediaItem rows', async () => {
  const rows = JSON.parse(await callProvider('example', 'search', ['one', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0);
  assert.equal(rows[0].type, 'anime');
  assert.ok(rows[0].id && rows[0].url && rows[0].title);
});

test('getDetail returns episodes', async () => {
  const detail = JSON.parse(
    await callProvider('example', 'getDetail', ['https://example.test/anime/one-piece']));
  assert.equal(detail.status, 'ongoing');
  assert.ok(detail.episodes.length >= 1);
  assert.equal(detail.episodes[0].id, 'ep-1');
});

test('getEpisodes returns the same episode list shape', async () => {
  const eps = JSON.parse(
    await callProvider('example', 'getEpisodes', ['https://example.test/anime/one-piece']));
  assert.ok(Array.isArray(eps));
  assert.equal(eps[0].number, 1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test js_harness/`
Expected: FAIL — `Cannot find module '.../js_harness/host.mjs'`.

- [ ] **Step 3: Write the Node host mirror**

`js_harness/host.mjs`:

```js
// Pure-Node mirror of kJsBootstrap + wrapProviderSource + wrapExtractorSource.
// Lets provider/extractor contracts be tested without Flutter/QuickJS.
import fs from 'node:fs';

globalThis.__providers = globalThis.__providers || {};
globalThis.__extractors = globalThis.__extractors || {};

globalThis.__fetch = async function (src, u, opts) {
  opts = opts || {};
  const headers = Object.assign(
    { 'User-Agent': 'Mozilla/5.0 Chrome/120.0', Accept: '*/*' },
    opts.headers || {});
  const r = await fetch(u, { method: opts.method || 'GET', headers, body: opts.body });
  const text = await r.text();
  return {
    ok: r.ok, status: r.status, statusText: r.statusText,
    headers: Object.fromEntries(r.headers.entries()), url: r.url, body: text,
    text: async () => text, json: async () => JSON.parse(text),
  };
};

globalThis.__console = function (src, level, args) {
  const parts = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    parts.push(typeof a === 'string' ? a : JSON.stringify(a));
  }
  console.log('[' + src + '/js ' + level + ']', parts.join(' '));
};

globalThis.htmlText = (s) => String(s || '')
  .replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").trim();

globalThis.absUrl = (h, b) => /^https?:\/\//i.test(h) ? h
  : h.startsWith('//') ? 'https:' + h
  : b ? (h.startsWith('/') ? b.match(/^(https?:\/\/[^/]+)/)[1] + h : b.replace(/\/$/, '') + '/' + h)
  : h;

// Shared extractor dispatcher (mirrors the runtime helper). Parses the host
// from `embedUrl` and routes to the registered extractor.
globalThis.extractVideo = function (embedUrl, opts) {
  const m = String(embedUrl).match(/^https?:\/\/([^/]+)/i);
  const host = m ? m[1].toLowerCase().replace(/^www\./, '') : '';
  const ex = globalThis.__extractors[host];
  if (!ex) return Promise.reject('No extractor for host: ' + host);
  return Promise.resolve(ex.extract(embedUrl, opts || {}));
};

globalThis.__callProvider = function (sourceId, method, argsJson) {
  let args;
  try { args = JSON.parse(argsJson || '[]'); } catch (e) { return Promise.reject('bad args'); }
  const ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('not loaded: ' + sourceId);
  const fn = ns[method];
  if (typeof fn !== 'function') return Promise.reject('missing method: ' + method);
  try { return Promise.resolve(fn.apply(null, args)).then((v) => JSON.stringify(v == null ? null : v)); }
  catch (e) { return Promise.reject(String(e.message || e)); }
};

function wrapProvider(sourceId, src) {
  return `(function(){
    var __SOURCE_ID='${sourceId}';
    var fetch=function(u,o){return globalThis.__fetch(__SOURCE_ID,u,o);};
    var extractVideo=function(u,o){return globalThis.extractVideo(u,o);};
    var console={log:function(){globalThis.__console(__SOURCE_ID,'log',arguments);},
      warn:function(){globalThis.__console(__SOURCE_ID,'warn',arguments);},
      error:function(){globalThis.__console(__SOURCE_ID,'error',arguments);}};
    ${src}
    globalThis.__providers['${sourceId}']={
      getInfo:typeof getInfo==='function'?getInfo:null,
      search:typeof search==='function'?search:null,
      getDetail:typeof getDetail==='function'?getDetail:null,
      getEpisodes:typeof getEpisodes==='function'?getEpisodes:null,
      getVideoSources:typeof getVideoSources==='function'?getVideoSources:null,
      getSettings:typeof getSettings==='function'?getSettings:null
    };
  })();`;
}

function wrapExtractor(src) {
  return `(function(){
    var fetch=function(u,o){return globalThis.__fetch('extractor',u,o);};
    var console={log:function(){globalThis.__console('extractor','log',arguments);},
      warn:function(){globalThis.__console('extractor','warn',arguments);},
      error:function(){globalThis.__console('extractor','error',arguments);}};
    ${src}
    var __info=getInfo();
    var __hosts=(__info.hosts||[]).slice();
    for (var i=0;i<__hosts.length;i++){
      globalThis.__extractors[String(__hosts[i]).toLowerCase().replace(/^www\\./,'')]=
        { info:__info, extract:extract };
    }
  })();`;
}

export function loadProvider(sourceId, fileUrl) {
  const src = fs.readFileSync(fileUrl, 'utf8');
  (0, eval)(wrapProvider(sourceId, src));
}

export function loadExtractor(fileUrl) {
  const src = fs.readFileSync(fileUrl, 'utf8');
  (0, eval)(wrapExtractor(src));
}

export function callProvider(sourceId, method, args) {
  return globalThis.__callProvider(sourceId, method, JSON.stringify(args));
}
```

- [ ] **Step 4: Write the provider authoring template**

`providers/_template.js`:

```js
// WATCH_APP provider template. Copy to <id>.js, fill in the functions.
// The host gives you: fetch(url,opts)->{status,body,headers,json,text},
// extractVideo(embedUrl,opts)->[VideoSource], htmlText(), absUrl(), console.

var SOURCE_ID = 'mysource';
var SITE = 'https://example.com';

function getInfo() {
  return { name: 'My Source', lang: 'en', baseUrl: SITE,
           logo: SITE + '/favicon.ico', type: 'anime', version: '1.0.0' };
}

function search(query, page, opts) {
  // return [{ id, title, url, cover, coverHeaders?, type:'anime', sourceId: SOURCE_ID }]
  return [];
}

function getDetail(url) {
  // return { id, title, url, cover?, description?, status, genres:[], studios:[],
  //          type:'anime', sourceId: SOURCE_ID, episodes:[Episode] }
  return null;
}

function getEpisodes(seriesUrl) {
  // Optional if getDetail already returns episodes. return [Episode].
  return [];
}

function getVideoSources(episodeUrl) {
  // return [VideoSource], OR resolve an embed via extractVideo():
  //   return extractVideo('https://embed.host/v/ID', { headers: { Referer: SITE + '/' } });
  return [];
}
```

- [ ] **Step 5: Write the bundled example provider**

`providers/example.js`:

```js
// Deterministic, offline example provider. Proves the contract + the
// extractVideo dispatch path end-to-end without hitting the network.

var SOURCE_ID = 'example';
var SITE = 'https://example.test';
var REFERER = SITE + '/';

function getInfo() {
  return { name: 'Example Anime', lang: 'en', baseUrl: SITE,
           logo: SITE + '/logo.png', type: 'anime', version: '1.0.0' };
}

function _catalog() {
  return [{
    id: 'one-piece', title: 'One Piece',
    cover: SITE + '/op.jpg', coverHeaders: { Referer: REFERER },
    url: SITE + '/anime/one-piece', type: 'anime', sourceId: SOURCE_ID,
  }];
}

function search(query, page, opts) {
  var q = String(query || '').toLowerCase();
  return _catalog().filter(function (m) {
    return q === '' || m.title.toLowerCase().indexOf(q) !== -1;
  });
}

function _episodes() {
  return [
    { id: 'ep-1', title: 'Episode 1', number: 1,
      url: SITE + '/watch/one-piece/1', date: '1999-10-20' },
    { id: 'ep-2', title: 'Episode 2', number: 2,
      url: SITE + '/watch/one-piece/2', date: '1999-10-27' },
  ];
}

function getDetail(url) {
  return {
    id: 'one-piece', title: 'One Piece', url: url,
    cover: SITE + '/op.jpg', coverHeaders: { Referer: REFERER },
    description: 'A pirate adventure.', status: 'ongoing',
    genres: ['Action', 'Adventure'], studios: ['Toei Animation'],
    type: 'anime', sourceId: SOURCE_ID, episodes: _episodes(),
  };
}

function getEpisodes(seriesUrl) {
  return _episodes();
}

function getVideoSources(episodeUrl) {
  // Return an embed and let the shared extractor resolve it — this is the
  // path real providers use.
  var id = episodeUrl.split('/').pop();
  return extractVideo('https://embed.test/e/' + id,
                      { headers: { Referer: REFERER } });
}
```

- [ ] **Step 6: Run the test to verify provider tests pass (extractor tests come in Task 8)**

Run: `node --test js_harness/contract.test.mjs`
Expected: PASS for the 4 provider tests. (The `getVideoSources` path is exercised in Task 8 once the extractor is registered.)

- [ ] **Step 7: Commit**

```bash
git add js_harness/host.mjs js_harness/contract.test.mjs providers/_template.js providers/example.js
git commit -m "test(p1): node contract harness + bundled example anime provider"
```

---

## Task 8: extractVideo dispatch + bundled example extractor (TDD, pure JS)

**Files:**
- Create: `extractors/_template.js`
- Create: `extractors/example_embed.js`
- Modify: `js_harness/contract.test.mjs` (add extractor + end-to-end source test)

- [ ] **Step 1: Write the failing test (extend the suite)**

Append to `js_harness/contract.test.mjs`:

```js
import { loadExtractor } from './host.mjs';

loadExtractor(new URL('../extractors/example_embed.js', import.meta.url));

test('extractVideo resolves an embed host to VideoSources', async () => {
  const sources = await globalThis.extractVideo('https://embed.test/e/1', {
    headers: { Referer: 'https://example.test/' },
  });
  assert.ok(Array.isArray(sources) && sources.length > 0);
  assert.equal(sources[0].container, 'hls');
  assert.equal(sources[0].kind, 'sub');
  assert.match(sources[0].url, /\.m3u8$/);
});

test('provider.getVideoSources flows through extractVideo end-to-end', async () => {
  const sources = JSON.parse(
    await callProvider('example', 'getVideoSources', ['https://example.test/watch/one-piece/1']));
  assert.ok(sources.length > 0);
  assert.equal(sources[0].kind, 'sub');
  assert.equal(sources[0].headers.Referer, 'https://example.test/');
  assert.ok(sources[0].subtitles.length >= 1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test js_harness/contract.test.mjs`
Expected: FAIL — `No extractor for host: embed.test` until the extractor file exists and is loaded.

- [ ] **Step 3: Write the extractor authoring template**

`extractors/_template.js`:

```js
// WATCH_APP extractor template. Copy to <host>.js, fill in extract().
// getInfo().hosts lists every domain this extractor claims; the runtime
// registers it under each one and routes extractVideo(url) by URL host.

function getInfo() {
  return { id: 'myhost', name: 'MyHost', version: '1.0.0',
           hosts: ['myhost.com', 'myhost.to'] };
}

function extract(url, opts) {
  // Resolve the embed page to one or more playable VideoSource objects.
  // return [{ url, quality, container:'hls'|'mp4', headers, kind:'sub'|'dub',
  //           audioLang, subtitles:[{url,lang,label,format,default}] }]
  return [];
}
```

- [ ] **Step 4: Write the bundled example extractor**

`extractors/example_embed.js`:

```js
// Deterministic example extractor for the fake host `embed.test`. Performs
// a pure URL transform (no network) so the contract test stays offline.

function getInfo() {
  return { id: 'example_embed', name: 'Example Embed', version: '1.0.0',
           hosts: ['embed.test'] };
}

function extract(url, opts) {
  opts = opts || {};
  var headers = opts.headers || { Referer: 'https://example.test/' };
  var id = url.split('/').pop();
  return [{
    url: 'https://cdn.test/' + id + '/master.m3u8',
    quality: '1080p', container: 'hls', headers: headers,
    kind: 'sub', audioLang: 'ja',
    subtitles: [
      { url: 'https://cdn.test/' + id + '/en.vtt', lang: 'en',
        label: 'English', format: 'vtt', default: true },
    ],
  }];
}
```

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `node --test js_harness/contract.test.mjs`
Expected: PASS for all tests (provider contract + extractor + end-to-end).

- [ ] **Step 6: Commit**

```bash
git add extractors/_template.js extractors/example_embed.js js_harness/contract.test.mjs
git commit -m "test(p1): extractVideo dispatch + bundled example extractor, end-to-end slice green"
```

---

## Task 9: Dart JS bootstrap (kJsBootstrap + wrappers)

Port Sozo's `js_bootstrap.dart`, extended for the video contract + extractors. No native test here (flutter_js needs a device/emulator); correctness of this string is proven by the Node harness (same logic) and by the Task 13 smoke run.

**Files:**
- Create: `lib/core/provider/js_bootstrap.dart`

- [ ] **Step 1: Create the bootstrap file**

`lib/core/provider/js_bootstrap.dart`:

```dart
/// Shared JS bootstrap loaded once into a single QuickJS runtime that hosts
/// every provider as `__providers[sourceId]` and every extractor as
/// `__extractors[host]`. flutter_js binds each message channel to one
/// runtime (last writer wins), so this design uses ONE runtime and routes
/// by sourceId / host inside the payload.
const String kJsBootstrap = r'''
var __pendingFetches = {};
var __fetchSeq = 0;
globalThis.__providers = globalThis.__providers || {};
globalThis.__extractors = globalThis.__extractors || {};
globalThis.__settings = globalThis.__settings || {};

function __nextFetchId() { __fetchSeq += 1; return 'f' + __fetchSeq; }

globalThis.__resolveFetch = function(id, responseJson) {
  var p = __pendingFetches[id]; if (!p) return;
  delete __pendingFetches[id];
  try { p.resolve(JSON.parse(responseJson)); }
  catch (e) { p.reject('Invalid fetch response JSON: ' + e); }
};

globalThis.__rejectFetch = function(id, reason) {
  var p = __pendingFetches[id]; if (!p) return;
  delete __pendingFetches[id]; p.reject(reason);
};

globalThis.__fetch = function(src, url, opts) {
  opts = opts || {};
  var id = __nextFetchId();
  var payload = {
    __src: src, id: id, url: url,
    method: (opts.method || 'GET').toUpperCase(),
    headers: opts.headers || {},
    body: opts.body == null ? null : (typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body)),
    responseType: opts.responseType || 'text'
  };
  var promise = new Promise(function(resolve, reject) {
    __pendingFetches[id] = { resolve: resolve, reject: reject };
  });
  sendMessage('fetch', JSON.stringify(payload));
  return promise.then(function(res) {
    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status, statusText: res.statusText || '',
      headers: res.headers || {}, url: res.url || url,
      text: function() { return Promise.resolve(res.body || ''); },
      json: function() {
        try { return Promise.resolve(JSON.parse(res.body || 'null')); }
        catch (e) { return Promise.reject('Invalid JSON: ' + e); }
      },
      body: res.body || ''
    };
  });
};

globalThis.__console = function(src, level, args) {
  try {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      parts.push(typeof a === 'string' ? a : JSON.stringify(a));
    }
    sendMessage('console', JSON.stringify({ __src: src, level: level, message: parts.join(' ') }));
  } catch (e) {}
};

// Shared extractor dispatcher. Parses the host from `embedUrl` and routes
// to the registered extractor's extract(url, opts).
globalThis.extractVideo = function(embedUrl, opts) {
  var m = String(embedUrl).match(/^https?:\/\/([^\/]+)/i);
  var host = m ? m[1].toLowerCase().replace(/^www\./, '') : '';
  var ex = globalThis.__extractors[host];
  if (!ex) return Promise.reject('No extractor for host: ' + host);
  try { return Promise.resolve(ex.extract(embedUrl, opts || {})); }
  catch (e) { return Promise.reject(String((e && e.message) || e)); }
};

globalThis.__callProvider = function(sourceId, method, argsJson) {
  var args;
  try { args = JSON.parse(argsJson || '[]'); }
  catch (e) { return Promise.reject('Bad argsJson: ' + e); }
  var ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('Provider not loaded: ' + sourceId);
  var fn = ns[method];
  if (typeof fn !== 'function') return Promise.reject('Provider ' + sourceId + ' missing method: ' + method);
  function stringifyErr(e) {
    if (!e) return 'unknown error';
    if (typeof e === 'string') return e;
    if (e instanceof Error) return e.message || String(e);
    if (typeof e === 'object' && e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (_) { return String(e); }
  }
  try {
    var r = fn.apply(null, args);
    return Promise.resolve(r)
      .then(function(v) { return JSON.stringify(v == null ? null : v); })
      .catch(function(e) { return Promise.reject(stringifyErr(e)); });
  } catch (e) { return Promise.reject(stringifyErr(e)); }
};

globalThis.htmlText = function(html) {
  if (!html) return '';
  return String(html).replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
};

globalThis.absUrl = function(href, base) {
  if (!href) return '';
  if (/^https?:\/\//i.test(href)) return href;
  if (href.startsWith('//')) return 'https:' + href;
  if (!base) return href;
  if (href.startsWith('/')) {
    var m = base.match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + href : href;
  }
  return base.replace(/\/$/, '') + '/' + href;
};
''';

/// Wraps a provider's JS so it lives in its own namespace with a local
/// `fetch`/`console`/`extractVideo` carrying its sourceId.
String wrapProviderSource(String sourceId, String providerJs) {
  final src = sourceId.replaceAll("'", r"\'");
  return '''
(function(){
  var __SOURCE_ID = '$src';
  var fetch = function(url, opts) { return globalThis.__fetch(__SOURCE_ID, url, opts); };
  var extractVideo = function(url, opts) { return globalThis.extractVideo(url, opts); };
  var console = {
    log:   function() { globalThis.__console(__SOURCE_ID, 'log', arguments); },
    warn:  function() { globalThis.__console(__SOURCE_ID, 'warn', arguments); },
    error: function() { globalThis.__console(__SOURCE_ID, 'error', arguments); },
    info:  function() { globalThis.__console(__SOURCE_ID, 'info', arguments); },
    debug: function() { globalThis.__console(__SOURCE_ID, 'debug', arguments); }
  };
  $providerJs
  globalThis.__providers['$src'] = {
    getInfo:         typeof getInfo === 'function' ? getInfo : null,
    search:          typeof search === 'function' ? search : null,
    getDetail:       typeof getDetail === 'function' ? getDetail : null,
    getEpisodes:     typeof getEpisodes === 'function' ? getEpisodes : null,
    getVideoSources: typeof getVideoSources === 'function' ? getVideoSources : null,
    getSettings:     typeof getSettings === 'function' ? getSettings : null
  };
})();
''';
}

/// Wraps an extractor's JS and registers it under every host in its
/// getInfo().hosts list as `__extractors[host]`.
String wrapExtractorSource(String extractorId, String extractorJs) {
  final src = extractorId.replaceAll("'", r"\'");
  return '''
(function(){
  var __EX_ID = '$src';
  var fetch = function(url, opts) { return globalThis.__fetch('ex:' + __EX_ID, url, opts); };
  var extractVideo = function(url, opts) { return globalThis.extractVideo(url, opts); };
  var console = {
    log:   function() { globalThis.__console('ex:' + __EX_ID, 'log', arguments); },
    warn:  function() { globalThis.__console('ex:' + __EX_ID, 'warn', arguments); },
    error: function() { globalThis.__console('ex:' + __EX_ID, 'error', arguments); }
  };
  $extractorJs
  var __info = (typeof getInfo === 'function') ? getInfo() : { hosts: [] };
  var __hosts = (__info && __info.hosts) ? __info.hosts : [];
  for (var i = 0; i < __hosts.length; i++) {
    var __h = String(__hosts[i]).toLowerCase().replace(/^www\\./, '');
    globalThis.__extractors[__h] = { info: __info, extract: (typeof extract === 'function' ? extract : null) };
  }
})();
''';
}
```

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/core/provider/js_bootstrap.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/core/provider/js_bootstrap.dart
git commit -m "feat(p1): Dart JS bootstrap with video contract + extractor registry"
```

---

## Task 10: base_provider.dart (Dart mirror of the video contract)

**Files:**
- Create: `lib/core/provider/base_provider.dart`

- [ ] **Step 1: Create the file**

`lib/core/provider/base_provider.dart`:

```dart
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';

/// Dart-side mirror of the JS provider contract. Every JS provider in
/// `providers/*.js` exports these globals:
///   - getInfo()
///   - search(query, page, opts)
///   - getDetail(url)
///   - getEpisodes(url)
///   - getVideoSources(episodeUrl)   // returns playable streams
abstract class BaseProvider {
  String get sourceId;

  Future<ProviderInfo> getInfo();

  /// `category` is an optional listing hint (e.g. 'popular', 'latest').
  Future<List<MediaItem>> search(String query, int page, {String category = ''});

  Future<MediaDetail> getDetail(String url);

  Future<List<Episode>> getEpisodes(String url);

  /// The video leaf — returns one or more playable [VideoSource]s for an
  /// episode (the UI filters by kind/quality/lang).
  Future<List<VideoSource>> getVideoSources(String episodeUrl);
}
```

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/core/provider/base_provider.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/core/provider/base_provider.dart
git commit -m "feat(p1): BaseProvider video contract"
```

---

## Task 11: provider_manager.dart (_JsHost + JsProvider + ProviderManager)

Port of Sozo's `provider_manager.dart`, adapted to the video models + the
extractor-loading path. Single shared QuickJS runtime, fetch bridged to Dio,
per-source health, 15s timeout, no host mutex.

**Files:**
- Create: `lib/core/provider/provider_manager.dart`

- [ ] **Step 1: Create the file**

`lib/core/provider/provider_manager.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

import '../error/exceptions.dart';
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';
import 'js_bootstrap.dart';

enum ProviderHealthStatus { healthy, degraded, broken }

class _ProviderHealth {
  _ProviderHealth({required this.failures, required this.lastError, required this.status});
  final int failures;
  final String lastError;
  final ProviderHealthStatus status;
}

/// Single shared QuickJS runtime hosting every provider as
/// `__providers[sourceId]` and every extractor as `__extractors[host]`.
class _JsHost {
  _JsHost({required this.dio}) {
    _runtime = getJavascriptRuntime();
    _runtime.enableHandlePromises();
    _runtime.onMessage('fetch', _onFetch);
    _runtime.onMessage('console', _onConsole);
    final r = _runtime.evaluate(kJsBootstrap);
    if (r.isError) {
      throw JsRuntimeException('Bootstrap failed: ${r.stringResult}');
    }
  }

  final Dio dio;
  late final JavascriptRuntime _runtime;
  final Map<String, JsProvider> providers = {};
  final Map<String, _ProviderHealth> _health = {};

  ProviderHealthStatus healthFor(String sourceId) =>
      _health[sourceId]?.status ?? ProviderHealthStatus.healthy;
  String? lastErrorFor(String sourceId) => _health[sourceId]?.lastError;
  int failuresFor(String sourceId) => _health[sourceId]?.failures ?? 0;
  void resetHealth(String sourceId) => _health.remove(sourceId);

  void loadProvider(String sourceId, String jsSource) {
    final r = _runtime.evaluate(wrapProviderSource(sourceId, jsSource));
    if (r.isError) {
      throw JsRuntimeException('Provider eval failed for $sourceId: ${r.stringResult}');
    }
  }

  void loadExtractor(String extractorId, String jsSource) {
    final r = _runtime.evaluate(wrapExtractorSource(extractorId, jsSource));
    if (r.isError) {
      throw JsRuntimeException('Extractor eval failed for $extractorId: ${r.stringResult}');
    }
  }

  void removeProvider(String sourceId) {
    _runtime.evaluate('delete globalThis.__providers[${jsonEncode(sourceId)}];');
  }

  Future<String> call(String sourceId, String method, List<Object?> args) async {
    try {
      final v = await _runCall(sourceId, method, args);
      _health.remove(sourceId);
      return v;
    } catch (e) {
      final failures = (_health[sourceId]?.failures ?? 0) + 1;
      _health[sourceId] = _ProviderHealth(
        failures: failures,
        lastError: e.toString(),
        status: failures >= 3 ? ProviderHealthStatus.broken : ProviderHealthStatus.degraded,
      );
      rethrow;
    }
  }

  Future<String> _runCall(String sourceId, String method, List<Object?> args) async {
    final argsJson = jsonEncode(args);
    final expr =
        '__callProvider(${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})';
    final asyncResult = await _runtime.evaluateAsync(expr);
    final resolved = await _runtime
        .handlePromise(asyncResult)
        .timeout(const Duration(seconds: 15), onTimeout: () {
      throw JsRuntimeException('$method timed out after 15s');
    });
    if (resolved.isError) {
      var msg = resolved.stringResult;
      if (msg.startsWith('"') && msg.endsWith('"')) {
        try { final unq = jsonDecode(msg); if (unq is String) msg = unq; } catch (_) {}
      }
      throw JsRuntimeException(msg);
    }
    var s = resolved.stringResult;
    if (s.isEmpty || s == 'null') {
      throw JsRuntimeException('$sourceId.$method returned null');
    }
    if (s.startsWith('"') && s.endsWith('"')) {
      try { final u = jsonDecode(s); if (u is String) s = u; } catch (_) {}
    }
    return s;
  }

  Map<String, dynamic> _coerceMap(dynamic raw) {
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw FormatException('Unexpected message payload type: ${raw.runtimeType}');
  }

  Future<void> _onFetch(dynamic raw) async {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final url = payload['url'] as String;
      final method = (payload['method'] as String?) ?? 'GET';
      final headers = (payload['headers'] as Map?)?.cast<String, dynamic>() ?? {};
      final body = payload['body'];
      final resp = await dio.requestUri<dynamic>(
        Uri.parse(url),
        data: body,
        options: Options(
          method: method,
          headers: headers.map((k, v) => MapEntry(k, v.toString())),
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );
      final responseHeaders = <String, String>{};
      resp.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));
      final responseJson = jsonEncode({
        'status': resp.statusCode ?? 0,
        'statusText': resp.statusMessage ?? '',
        'headers': responseHeaders,
        'url': resp.realUri.toString(),
        'body': resp.data?.toString() ?? '',
      });
      _runtime.evaluate('__resolveFetch(${jsonEncode(id)}, ${jsonEncode(responseJson)});');
    } catch (e) {
      if (id != null) {
        _runtime.evaluate('__rejectFetch(${jsonEncode(id)}, ${jsonEncode(e.toString())});');
      }
    }
  }

  void _onConsole(dynamic raw) {
    try {
      final map = _coerceMap(raw);
      final src = (map['__src'] ?? '?').toString();
      final level = (map['level'] ?? 'log').toString();
      final message = (map['message'] ?? '').toString();
      // ignore: avoid_print
      print('[$src/js $level] $message');
    } catch (_) {}
  }

  void dispose() => _runtime.dispose();
}

/// Thin per-source wrapper. Calls route through the shared _JsHost and
/// deserialize into the video models.
class JsProvider implements BaseProvider {
  JsProvider._({
    required this.sourceId,
    required this.originRepoUrl,
    required this.displayName,
    required _JsHost host,
  }) : _host = host;

  @override
  final String sourceId;
  final String originRepoUrl;
  final String displayName;
  final _JsHost _host;

  ProviderHealthStatus get healthStatus => _host.healthFor(sourceId);
  String? get lastError => _host.lastErrorFor(sourceId);

  Future<String> _call(String method, List<Object?> args) =>
      _host.call(sourceId, method, args);

  ProviderInfo? _infoCache;

  @override
  Future<ProviderInfo> getInfo() async {
    final cached = _infoCache;
    if (cached != null) return cached;
    final raw = await _call('getInfo', const []);
    final info = ProviderInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    _infoCache = info;
    return info;
  }

  @override
  Future<List<MediaItem>> search(String query, int page, {String category = ''}) async {
    final raw = await _call('search', [query, page, {'category': category}]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId})).toList();
  }

  @override
  Future<MediaDetail> getDetail(String url) async {
    final raw = await _call('getDetail', [url]);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return MediaDetail.fromJson({...map, 'sourceId': sourceId});
  }

  @override
  Future<List<Episode>> getEpisodes(String url) async {
    final raw = await _call('getEpisodes', [url]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(Episode.fromJson).toList();
  }

  @override
  Future<List<VideoSource>> getVideoSources(String episodeUrl) async {
    final raw = await _call('getVideoSources', [episodeUrl]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(VideoSource.fromJson).toList();
  }
}

/// Public manager. Owns the single shared QuickJS runtime + registered
/// providers and extractors.
class ProviderManager {
  ProviderManager({required Dio dio}) : _host = _JsHost(dio: dio);

  final _JsHost _host;

  Iterable<String> get installedIds => _host.providers.keys;
  List<JsProvider> get all => _host.providers.values.toList();
  JsProvider? get(String id) => _host.providers[id];

  /// Loads [jsSource] as a provider under [sourceId]. One provider per
  /// sourceId is live at a time; reloading replaces it.
  JsProvider load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {
    _host.loadProvider(sourceId, jsSource);
    final provider = JsProvider._(
      sourceId: sourceId,
      originRepoUrl: originRepoUrl,
      displayName: displayName,
      host: _host,
    );
    _host.providers[sourceId] = provider;
    return provider;
  }

  /// Loads [jsSource] as an extractor; it registers itself under each host
  /// in its getInfo().hosts list and is reachable via extractVideo().
  void loadExtractor({required String extractorId, required String jsSource}) {
    _host.loadExtractor(extractorId, jsSource);
  }

  void remove(String id) {
    _host.removeProvider(id);
    _host.providers.remove(id);
    _host.resetHealth(id);
  }

  void disposeAll() {
    _host.providers.clear();
    _host.dispose();
  }
}
```

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/core/provider/`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/core/provider/provider_manager.dart
git commit -m "feat(p1): ProviderManager (shared QuickJS runtime, video calls, extractor loading)"
```

---

## Task 12: provider_downloader.dart (JS download + Hive cache)

Straight port of Sozo's downloader (used later to fetch hosted provider/extractor JS; included now so the registry layer in P4 has it).

**Files:**
- Create: `lib/core/provider/provider_downloader.dart`

- [ ] **Step 1: Create the file**

`lib/core/provider/provider_downloader.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

import '../error/exceptions.dart';

class CachedProvider {
  final String name;
  final String jsCode;
  final String url;
  final DateTime fetchedAt;

  CachedProvider({
    required this.name,
    required this.jsCode,
    required this.url,
    required this.fetchedAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'jsCode': jsCode,
        'url': url,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory CachedProvider.fromJson(Map<String, dynamic> j) => CachedProvider(
        name: j['name'] as String,
        jsCode: j['jsCode'] as String,
        url: j['url'] as String,
        fetchedAt: DateTime.parse(j['fetchedAt'] as String),
      );
}

/// Downloads provider / extractor JS from raw URLs and caches them in Hive.
class ProviderDownloader {
  static const String boxName = 'provider_js_cache';
  static const Duration maxAge = Duration(hours: 24);

  ProviderDownloader({required Dio dio}) : _dio = dio;
  final Dio _dio;

  Box<Map> get _box => Hive.box<Map>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async {
    final cached = _read(name);
    if (!force && cached != null &&
        DateTime.now().difference(cached.fetchedAt) < maxAge) {
      return cached;
    }
    try {
      final resp = await _dio.getUri<String>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 500,
          // raw.githubusercontent.com sits behind a ~5 min Fastly edge
          // cache; force a revalidation so "Update" actually pulls fresh JS.
          headers: force ? {'Cache-Control': 'no-cache'} : null,
        ),
      );
      if (resp.statusCode == null || resp.statusCode! >= 400) {
        if (cached != null) return cached;
        throw NetworkException('Failed to download $name', statusCode: resp.statusCode);
      }
      final js = resp.data ?? '';
      if (js.trim().isEmpty) {
        if (cached != null) return cached;
        throw ProviderException('Downloaded provider $name is empty');
      }
      final entry = CachedProvider(name: name, jsCode: js, url: url, fetchedAt: DateTime.now());
      await _box.put(name, entry.toJson());
      return entry;
    } on DioException catch (e) {
      if (cached != null) return cached;
      throw NetworkException('Dio error: ${e.message}', statusCode: e.response?.statusCode);
    }
  }

  CachedProvider? _read(String name) {
    final raw = _box.get(name);
    if (raw == null) return null;
    return CachedProvider.fromJson(Map<String, dynamic>.from(raw));
  }

  CachedProvider? readCached(String name) => _read(name);
  Future<void> remove(String name) async => _box.delete(name);
  Future<void> clear() async => _box.clear();
}
```

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/core/provider/provider_downloader.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/core/provider/provider_downloader.dart
git commit -m "feat(p1): ProviderDownloader (raw JS fetch + Hive cache)"
```

---

## Task 13: DI wiring + dev slice screen + smoke run

Wires Hive + `get_it`, loads the bundled `example.js` provider and
`example_embed.js` extractor from assets into the real QuickJS runtime, and
renders the vertical slice (search → detail → episodes → sources) so the port
is verified on a device/emulator.

**Files:**
- Create: `lib/core/di/injector.dart`
- Create: `lib/dev/dev_slice_screen.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: Create the injector**

`lib/core/di/injector.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';

final GetIt sl = GetIt.instance;

/// One-time app bootstrap: Hive boxes, Dio, the shared provider runtime, and
/// the bundled example provider + extractor loaded from assets.
Future<void> initDependencies() async {
  await Hive.initFlutter();
  await ProviderDownloader.init();

  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': 'Mozilla/5.0 (WATCH_APP) Chrome/120.0'},
  ));
  sl.registerSingleton<Dio>(dio);

  final manager = ProviderManager(dio: dio);
  sl.registerSingleton<ProviderManager>(manager);
  sl.registerSingleton<ProviderDownloader>(ProviderDownloader(dio: dio));

  // Load bundled extractor BEFORE the provider so getVideoSources can resolve.
  final extractorJs = await rootBundle.loadString('extractors/example_embed.js');
  manager.loadExtractor(extractorId: 'example_embed', jsSource: extractorJs);

  final providerJs = await rootBundle.loadString('providers/example.js');
  manager.load(
    sourceId: 'example',
    jsSource: providerJs,
    originRepoUrl: 'bundled://',
    displayName: 'Bundled',
  );
}
```

- [ ] **Step 2: Create the dev slice screen**

`lib/dev/dev_slice_screen.dart`:

```dart
import 'package:flutter/material.dart';

import '../core/di/injector.dart';
import '../core/models/episode.dart';
import '../core/models/media_detail.dart';
import '../core/models/media_item.dart';
import '../core/models/video_source.dart';
import '../core/provider/provider_manager.dart';

/// Throwaway screen that runs the full content-runtime slice against the
/// bundled example provider and prints the result. Replaced by real UI in P3+.
class DevSliceScreen extends StatefulWidget {
  const DevSliceScreen({super.key});
  @override
  State<DevSliceScreen> createState() => _DevSliceScreenState();
}

class _DevSliceScreenState extends State<DevSliceScreen> {
  String _log = 'Running slice…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final p = sl<ProviderManager>().get('example')!;
    final buf = StringBuffer();
    try {
      final info = await p.getInfo();
      buf.writeln('provider: ${info.name} (${info.type.name})');

      final List<MediaItem> results = await p.search('one', 1);
      buf.writeln('search("one") -> ${results.length} result(s): '
          '${results.map((r) => r.title).join(", ")}');

      final MediaDetail detail = await p.getDetail(results.first.url);
      buf.writeln('detail: ${detail.title} • ${detail.status.name} • '
          '${detail.episodes.length} eps • studios=${detail.studios.join(",")}');

      final List<Episode> eps = await p.getEpisodes(detail.url);
      buf.writeln('episodes: ${eps.map((e) => e.title).join(", ")}');

      final List<VideoSource> sources = await p.getVideoSources(eps.first.url);
      final s = sources.first;
      buf.writeln('sources for "${eps.first.title}": ${sources.length} • '
          'first=${s.quality}/${s.container.name}/${s.kind.name} '
          'url=${s.url} subs=${s.subtitles.length} '
          'referer=${s.headers?['Referer']}');
      buf.writeln('\n✅ SLICE OK');
    } catch (e) {
      buf.writeln('\n❌ SLICE FAILED: $e');
    }
    setState(() => _log = buf.toString());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('WATCH_APP dev slice')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Text(_log, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ),
      );
}
```

- [ ] **Step 3: Rewrite `lib/main.dart`**

```dart
import 'package:flutter/material.dart';

import 'core/app_config.dart';
import 'core/di/injector.dart';
import 'dev/dev_slice_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDependencies();
  runApp(const WatchApp());
}

class WatchApp extends StatelessWidget {
  const WatchApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: kAppName,
        theme: ThemeData.dark(useMaterial3: true),
        home: const DevSliceScreen(),
      );
}
```

- [ ] **Step 4: Verify the whole project analyzes**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Smoke-run on a device/emulator**

Run: `flutter run -d <device>` (or launch from IDE). On screen, expect:

```
provider: Example Anime (anime)
search("one") -> 1 result(s): One Piece
detail: One Piece • ongoing • 2 eps • studios=Toei Animation
episodes: Episode 1, Episode 2
sources for "Episode 1": 1 • first=1080p/hls/sub url=https://cdn.test/1/master.m3u8 subs=1 referer=https://example.test/
✅ SLICE OK
```

This confirms the QuickJS runtime, the provider wrap, the extractor registry, and `extractVideo` dispatch all work natively — the same flow the Node harness proved offline.

- [ ] **Step 6: Commit**

```bash
git add lib/core/di/injector.dart lib/dev/dev_slice_screen.dart lib/main.dart
git commit -m "feat(p1): DI wiring + dev slice screen; bundled provider+extractor run natively"
```

---

## Task 14: README + plan-completion notes

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md`**

```markdown
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
flutter test          # Dart model tests
node --test js_harness/   # JS provider/extractor contract (offline, deterministic)
```

## Authoring sources

Copy `providers/_template.js` → `providers/<id>.js` (fill the five functions),
or `extractors/_template.js` → `extractors/<host>.js` (fill `extract`). The
contract is defined in `lib/core/provider/base_provider.dart`.
```

- [ ] **Step 2: Run both test suites one final time**

Run: `flutter test && node --test js_harness/`
Expected: all Dart model tests PASS; all Node contract tests PASS.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(p1): README with status, testing, and source-authoring notes"
```

---

## Self-review (spec coverage)

- **§1 identity/rename** → Task 1 (`app_config.dart`, `kAppName`). ✓
- **§2 provider contract** → Tasks 9–11 (`getEpisodes`, `getVideoSources`). ✓
- **§3 data models** → Tasks 2–6 (Media/Episode/VideoSource/Subtitle + enums). ✓
- **§4 extractor subsystem** → Tasks 8, 9, 11 (`__extractors`, `extractVideo`, `wrapExtractorSource`, `loadExtractor`). ✓
- **§5 manifest v2** → constants seeded in Task 1 (`kAppId`, `kManifestSchemaVersion`); the registry/guard UI is **P4 (separate plan)** — out of scope here by design. ✓ (deferred, not missed)
- **§6 player** → P3 (separate plan). Not in this plan. ✓
- **§7 ported subsystems** → P5–P7 (separate plans). ✓
- **§8 GitHub repo** → P4; the bundled provider/extractor + templates here are the local stand-in. ✓
- **§9 hard parts** → headers carried through `VideoSource.headers` end-to-end (Tasks 4, 8, 13); DRM-skip + obfuscated-m3u8 land with real extractors in P2/P3. ✓

**Type consistency:** `getEpisodes`/`getVideoSources`/`extractVideo` names match across JS wrappers (Task 9), Node host (Task 7), Dart contract (Task 10), and manager (Task 11). `container`/`kind`/`subtitles` field names match across the Dart model (Task 4), example extractor (Task 8), and dev screen (Task 13). `SourceContainer`/`AudioKind`/`MediaStatus`/`ProviderType` enums are defined once and reused.

**Placeholder scan:** no TBD/TODO/"handle errors appropriately"; every code step contains full code; every run step has an expected result.
```
