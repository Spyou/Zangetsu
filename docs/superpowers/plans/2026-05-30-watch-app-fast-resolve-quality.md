# WATCH_APP Plan — Fast source resolution + HLS resolution picker

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make episode playback start fast (no ~20s "Resolving sources…" stall) and let the user pick 1080p/720p/etc. from the HLS stream.

**Architecture:** Two runtime primitives (per-request fetch `timeoutMs`; a guarded Dart-backed `setTimeout` bridge), a soft-deadline rewrite of AllAnime `getVideoSources` (return fast sources within ~5s, drop stragglers), a pure Dart HLS-master parser, and player-side lazy quality expansion (parse the master after playback starts; pick a variant to switch resolution at the current position).

**Tech Stack:** flutter_js (QuickJS) runtime, `dio`, `media_kit`, Node harness; Dart for the HLS parser.

**Spec:** `docs/superpowers/specs/2026-05-30-watch-app-fast-resolve-quality-design.md`. Builds on 2A/2B/P2 (on `main`).

**Test seams:** the soft-deadline collector and the HLS parser are pure/isolated and unit-tested; the `setTimeout` bridge + player UI are verified by `flutter analyze` + an on-device smoke (Node has native `setTimeout`, so the deadline logic is testable there).

---

## File structure

```
lib/core/provider/js_bootstrap.dart      # MODIFY: __fetch carries timeoutMs; guarded setTimeout/clearTimeout + __fireTimer + __timers
lib/core/provider/provider_manager.dart  # MODIFY: _onFetch honors timeoutMs; onMessage('timer', _onTimer)
providers/allanime.js                     # MODIFY: soft-deadline getVideoSources + timeoutMs on clock fetch + test hook
js_harness/allanime.test.mjs              # MODIFY: unit-test the soft-deadline collector hook
lib/core/playback/hls.dart                # NEW: HlsVariant + parseHlsMaster (pure) + fetchHlsVariants
test/playback/hls_test.dart               # NEW
lib/features/player/player_controller.dart# MODIFY: Dio + qualities/activeQuality + lazy expand + selectQuality
lib/features/player/player_screen.dart    # MODIFY: Dio pass-through + Quality section in picker + status line
```

---

## Task 1: Runtime primitives — fetch `timeoutMs` + `setTimeout` bridge

**Files:** Modify `lib/core/provider/js_bootstrap.dart`, `lib/core/provider/provider_manager.dart`. Verified by `flutter analyze` (behavior exercised in Task 2 / on-device).

- [ ] **Step 1: `js_bootstrap.dart` — carry `timeoutMs` in `__fetch`.** In the `kJsBootstrap` raw string, in `globalThis.__fetch`'s `payload` object literal, add a `timeoutMs` field. Change:
```javascript
    responseType: opts.responseType || 'text'
  };
```
to:
```javascript
    responseType: opts.responseType || 'text',
    timeoutMs: (typeof opts.timeoutMs === 'number' && opts.timeoutMs > 0) ? opts.timeoutMs : 0
  };
```

- [ ] **Step 2: `js_bootstrap.dart` — add the timer bridge.** In `kJsBootstrap`, immediately AFTER the `globalThis.absUrl = function(...) { ... };` definition, add:
```javascript
var __timers = {};
var __timerSeq = 0;
function __nextTimerId() { __timerSeq += 1; return 't' + __timerSeq; }
globalThis.__fireTimer = function(id) {
  var fn = __timers[id];
  if (!fn) return;
  delete __timers[id];
  try { fn(); } catch (e) {}
};
// Guarded: keep a host-provided setTimeout if one exists; otherwise bridge to Dart.
if (typeof globalThis.setTimeout !== 'function') {
  globalThis.setTimeout = function(fn, ms) {
    var id = __nextTimerId();
    __timers[id] = fn;
    sendMessage('timer', JSON.stringify({ id: id, ms: ms || 0 }));
    return id;
  };
  globalThis.clearTimeout = function(id) { delete __timers[id]; };
}
```

- [ ] **Step 3: `provider_manager.dart` — honor `timeoutMs` in `_onFetch`.** In `_onFetch`, after reading `body`, read the timeout and apply it to the Dio `Options`. Change the `dio.requestUri` `options:` to include the per-request timeouts:
```dart
      final body = payload['body'];
      final tMs = (payload['timeoutMs'] as num?)?.toInt() ?? 0;
      // ignore: avoid_print
      print('[fetch] $method $url');
      final resp = await dio.requestUri<dynamic>(
        Uri.parse(url),
        data: body,
        options: Options(
          method: method,
          headers: headers.map((k, v) => MapEntry(k, v.toString())),
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (_) => true,
          receiveTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
          sendTimeout: tMs > 0 ? Duration(milliseconds: tMs) : null,
        ),
      );
```
(Keep the existing `print('[fetch] <- ...')` line after.)

- [ ] **Step 4: `provider_manager.dart` — register + handle the `timer` channel.** In `_JsHost`'s constructor, after `_runtime.onMessage('crypto', _onCrypto);`, add:
```dart
    _runtime.onMessage('timer', _onTimer);
```
Add this method to `_JsHost` (next to `_onCrypto`):
```dart
  void _onTimer(dynamic raw) {
    try {
      final payload = _coerceMap(raw);
      final id = payload['id'] as String;
      final ms = (payload['ms'] as num?)?.toInt() ?? 0;
      Future<void>.delayed(Duration(milliseconds: ms < 0 ? 0 : ms), () {
        _runtime.evaluate('__fireTimer(${jsonEncode(id)});');
      });
    } catch (_) {}
  }
```

- [ ] **Step 5: Verify** `flutter analyze lib/core/provider/` → `No issues found!`.

- [ ] **Step 6: Commit**
```bash
git add lib/core/provider/js_bootstrap.dart lib/core/provider/provider_manager.dart
git commit -m "feat: per-request fetch timeoutMs + Dart-backed setTimeout bridge in the JS runtime"
```

---

## Task 2: Soft-deadline `getVideoSources` (AllAnime) — TDD

**Files:** Modify `providers/allanime.js`, `js_harness/allanime.test.mjs`.

- [ ] **Step 1: Add the failing test.** Append to `js_harness/allanime.test.mjs`:
```js
test('settleWithDeadline returns resolved jobs without waiting for hung ones', async () => {
  const settle = globalThis.__allanimeSettleWithDeadline;
  assert.equal(typeof settle, 'function');
  const fast = Promise.resolve([{ url: 'a' }]);
  const hung = new Promise(() => {}); // never resolves
  const t0 = Date.now();
  const out = await settle([fast, hung], 150);
  const dt = Date.now() - t0;
  assert.deepEqual(out, [{ url: 'a' }]);
  assert.ok(dt < 1000, 'should resolve at the ~150ms deadline, not wait for hung');
});
```

- [ ] **Step 2: Run → FAIL** `node --test js_harness/allanime.test.mjs` (`__allanimeSettleWithDeadline` undefined).

- [ ] **Step 3: Add the collector + hook in `providers/allanime.js`** (place it near `getVideoSources`):
```js
// Resolve [Promise<[VideoSource]>] concurrently; return the results collected by
// the time either all settle or `deadlineMs` elapses (stragglers dropped). Keeps
// source resolution fast even when one backend is dead/slow.
function _settleWithDeadline(jobs, deadlineMs) {
  return new Promise(function (resolve) {
    var results = [];
    var pending = jobs.length;
    var done = false;
    function finish() { if (!done) { done = true; resolve(results); } }
    if (pending === 0) { resolve(results); return; }
    for (var i = 0; i < jobs.length; i++) {
      Promise.resolve(jobs[i])
        .then(function (arr) { if (arr && arr.length) results = results.concat(arr); })
        .catch(function () {})
        .then(function () { pending -= 1; if (pending === 0) finish(); });
    }
    setTimeout(finish, deadlineMs);
  });
}
globalThis.__allanimeSettleWithDeadline = _settleWithDeadline; // test hook
```

- [ ] **Step 4: Use it in `getVideoSources`.** Replace the final `Promise.all(jobs)` block:
```js
    return Promise.all(jobs).then(function (lists) {
      var all = []; for (var k = 0; k < lists.length; k++) all = all.concat(lists[k]);
      if (all.length === 0) throw new Error('AllAnime: no playable sources');
      return all;
    });
```
with:
```js
    var deadline = (typeof globalThis.__allanimeDeadlineMs === 'number') ? globalThis.__allanimeDeadlineMs : 5000;
    return _settleWithDeadline(jobs, deadline).then(function (all) {
      if (all.length === 0) throw new Error('AllAnime: no playable sources');
      return all;
    });
```

- [ ] **Step 5: Bound the clock fetch.** In `_resolveClock`, add a per-request timeout so a dead backend fails fast. Change its `fetch(...)` to include `timeoutMs`:
```js
function _resolveClock(path, mode) {
  return fetch('https://allanime.day' + path, { headers: { 'Referer': REFERER, 'User-Agent': UA }, timeoutMs: 8000 })
```
(rest of `_resolveClock` unchanged).

- [ ] **Step 6: Run → PASS** `node --test js_harness/allanime.test.mjs` (the new collector test passes in ~150ms; existing tests still pass; live skipped).

- [ ] **Step 7: Commit**
```bash
git add providers/allanime.js js_harness/allanime.test.mjs
git commit -m "feat: AllAnime getVideoSources soft-deadline (~5s) + 8s clock timeout — fast resolution"
```

---

## Task 3: HLS master parser (`hls.dart`) — TDD

**Files:** Create `lib/core/playback/hls.dart`, `test/playback/hls_test.dart`.

- [ ] **Step 1: Failing test** `test/playback/hls_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/hls.dart';

void main() {
  test('parseHlsMaster returns variants sorted high→low with absolute urls', () {
    const master = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480\n'
        '480/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\n'
        'https://cdn.test/1080/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\n'
        '720/index.m3u8\n';
    final out = parseHlsMaster(master, 'https://cdn.test/hls/master.m3u8');
    expect(out.map((v) => v.quality).toList(), ['1080p', '720p', '480p']);
    expect(out[0].url, 'https://cdn.test/1080/index.m3u8'); // absolute kept
    expect(out[1].url, 'https://cdn.test/hls/720/index.m3u8'); // relative resolved
  });

  test('parseHlsMaster returns empty for a non-master playlist', () {
    const media = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXTINF:6.0,\nseg1.ts\n';
    expect(parseHlsMaster(media, 'https://cdn.test/x/index.m3u8'), isEmpty);
  });
}
```

- [ ] **Step 2: Run → FAIL** `flutter test test/playback/hls_test.dart`.

- [ ] **Step 3: Write `lib/core/playback/hls.dart`:**
```dart
import 'package:dio/dio.dart';

/// One selectable quality from an HLS master playlist.
class HlsVariant {
  HlsVariant({required this.quality, required this.url});
  final String quality; // e.g. '1080p'
  final String url;
}

/// Resolves [ref] (which may be relative) against the directory of [base].
String _resolve(String ref, String base) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  final b = Uri.parse(base);
  return b.resolve(ref).toString();
}

/// Parses an HLS master playlist into its variant streams, sorted highest
/// resolution first. Returns `[]` if [playlist] has no `#EXT-X-STREAM-INF`
/// (i.e. it's a media playlist, not a master).
List<HlsVariant> parseHlsMaster(String playlist, String masterUrl) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  final out = <HlsVariant>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    // find the next non-comment, non-empty line — the variant URI
    String? uri;
    for (var j = i + 1; j < lines.length; j++) {
      final cand = lines[j].trim();
      if (cand.isEmpty || cand.startsWith('#')) continue;
      uri = cand;
      break;
    }
    if (uri == null) continue;
    final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    final String quality;
    final int rank;
    if (res != null) {
      final h = int.parse(res.group(2)!);
      quality = '${h}p';
      rank = h;
    } else {
      final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
      final kbps = bw != null ? (int.parse(bw.group(1)!) ~/ 1000) : 0;
      quality = kbps > 0 ? '${kbps}k' : 'auto';
      rank = kbps; // bandwidth-ranked, sorts below resolution-tagged ones if 0
    }
    out.add(_RankedVariant(quality: quality, url: _resolve(uri, masterUrl), rank: rank));
  }
  out.sort((a, b) => (b as _RankedVariant).rank.compareTo((a as _RankedVariant).rank));
  return out;
}

class _RankedVariant extends HlsVariant {
  _RankedVariant({required super.quality, required super.url, required this.rank});
  final int rank;
}

/// Fetches [masterUrl] and parses it into variants. Returns `[]` on any error or
/// if it's not a master playlist.
Future<List<HlsVariant>> fetchHlsVariants(
    String masterUrl, Map<String, String>? headers, Dio dio) async {
  try {
    final resp = await dio.getUri<String>(
      Uri.parse(masterUrl),
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final body = resp.data ?? '';
    return parseHlsMaster(body, masterUrl);
  } catch (_) {
    return const [];
  }
}
```

- [ ] **Step 4: Run → PASS** `flutter test test/playback/hls_test.dart` (2 tests).

- [ ] **Step 5: Commit**
```bash
git add lib/core/playback/hls.dart test/playback/hls_test.dart
git commit -m "feat: parseHlsMaster + fetchHlsVariants (HLS master → resolution variants)"
```

---

## Task 4: PlayerController — quality list + variant switching + Dio

**Files:** Modify `lib/features/player/player_controller.dart`.

- [ ] **Step 1: Imports + ctor Dio.** Add to imports:
```dart
import 'package:dio/dio.dart';

import '../../core/playback/hls.dart';
```
Change the constructor to accept a `Dio` and store it. Add `required Dio dio` to the ctor params and `this._dio = dio` style — concretely, add a field `final Dio _dio;` and a `required Dio dio` parameter, assigning it in the initializer list alongside `_resolveSources`.

- [ ] **Step 2: Quality state.** Add fields near `sources`:
```dart
  List<HlsVariant> qualities = const [];
  HlsVariant? activeQuality; // null = Auto (the master)
```

- [ ] **Step 3: Populate qualities after an HLS source opens.** At the END of `_open` (after the subtitle block, still inside `_open`, guarded by the generation check that already exists — i.e. only when `g == _gen`), add a background expansion:
```dart
    // Lazy HLS quality expansion — does not block playback start.
    qualities = const [];
    activeQuality = null;
    if (s.container == SourceContainer.hls) {
      final masterUrl = s.url;
      fetchHlsVariants(masterUrl, s.headers, _dio).then((vs) {
        if (g == _gen && vs.length > 1) {
          qualities = vs;
          notifyListeners();
        }
      });
    }
```
(`SourceContainer` is already imported via the video_source model; if not, add `import '../../core/models/video_source.dart';` — it is already imported.)

- [ ] **Step 4: `selectQuality`.** Add this method:
```dart
  /// Switch the active HLS resolution. [v] == null → Auto (re-open the master).
  Future<void> selectQuality(HlsVariant? v) async {
    final a = active;
    if (a == null) return;
    activeQuality = v;
    final url = v?.url ?? a.url; // Auto uses the master url
    // Re-open at the live position, keeping kind/headers from the active source.
    await _open(
      VideoSource(url: url, quality: v?.quality ?? a.quality, container: a.container,
          headers: a.headers, kind: a.kind, audioLang: a.audioLang, subtitles: a.subtitles),
      seekTo: _lastPos,
    );
    // Keep the expanded quality list (don't let the re-open clear it for a variant).
    notifyListeners();
  }
```
NOTE: `_open` resets `qualities`/`activeQuality` (Step 3). To avoid the variant re-open wiping the menu, guard the reset in Step 3 so it only runs for a master, not a variant: change the Step-3 reset to skip when the opened url is a known variant. Simplest: in `selectQuality`, after `await _open(...)`, restore the menu — set `qualities` back and `activeQuality = v`:
```dart
    // (restore after _open cleared them)
    // qualities is unchanged in memory only if _open didn't null it; re-assert:
```
To keep this unambiguous, implement Step 3's reset as: only reset when opening a NEW source via `openEpisode`/`switchSource`, NOT via `selectQuality`. Add a bool param to `_open`: `_open(s, {Duration? seekTo, int? gen, bool keepQualities = false})`; `selectQuality` calls `_open(..., keepQualities: true)`; in `_open`, wrap the Step-3 block in `if (!keepQualities) { ... }`.

- [ ] **Step 5: Verify** `flutter analyze lib/features/player/player_controller.dart` → `No issues found!`.

- [ ] **Step 6: Commit**
```bash
git add lib/features/player/player_controller.dart
git commit -m "feat: PlayerController HLS quality list + selectQuality (variant switch at position)"
```

---

## Task 5: PlayerScreen — Quality section in the picker

**Files:** Modify `lib/features/player/player_screen.dart`.

- [ ] **Step 1: Pass Dio into the controller.** Add `import 'package:dio/dio.dart';` and `import '../../core/di/injector.dart';` (if not present), and in `initState` where `PlayerController(...)` is constructed, add `dio: sl<Dio>(),` to its arguments.

- [ ] **Step 2: Add the Quality section to `_openPicker`.** Inside the bottom-sheet `ListView`'s `children:`, BEFORE the existing sub/dub source rows, add a quality block when variants exist:
```dart
              if (_c.qualities.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('Quality', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(_c.activeQuality == null ? Icons.check : null),
                  title: const Text('Auto'),
                  onTap: () { Navigator.pop(context); _c.selectQuality(null); },
                ),
                for (final v in _c.qualities)
                  ListTile(
                    dense: true,
                    leading: Icon(_c.activeQuality?.url == v.url ? Icons.check : null),
                    title: Text(v.quality),
                    onTap: () { Navigator.pop(context); _c.selectQuality(v); },
                  ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('Source', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
```

- [ ] **Step 3: Status line shows active quality.** In the bottom controls `Row`, change the episode/quality label `Text(...)` so it shows `_c.activeQuality?.quality ?? (_c.active?.quality ?? '')` for the quality portion — concretely replace `'${_c.active?.quality ?? ''}'` in that Text with `'${_c.activeQuality?.quality ?? _c.active?.quality ?? ''}'`.

- [ ] **Step 4: Verify** `flutter analyze` (whole project) → `No issues found!`; `flutter test` → all pass (20 + 2 hls = 22).

- [ ] **Step 5: Commit**
```bash
git add lib/features/player/player_screen.dart
git commit -m "feat: PlayerScreen Quality section (Auto + resolutions) + active-quality label"
```

---

## Task 6: On-device smoke (controller-driven, manual)

- [ ] **Step 1:** `env -u GEM_HOME -u GEM_PATH PATH="/opt/homebrew/bin:$PATH" flutter run -d "iPhone 15 Pro Max"`.
- [ ] **Step 2:** Search → open an episode. Confirm: (a) playback starts noticeably faster (no ~20s spinner — watch the `[fetch]` logs: the dead clock now times out at ~8s and the call returns at the ~5s deadline); (b) once playing on the HLS source, the quality icon shows **Auto / 1080p / 720p / …**; selecting a resolution switches it and resumes at the same position; (c) Auto returns to adaptive.
- [ ] **Step 3:** Record result.

---

## Self-review

**Spec coverage:** §1a fetch timeoutMs → Task 1 (steps 1,3). §1b setTimeout bridge → Task 1 (steps 2,4). §2 soft-deadline + 8s clock → Task 2. §3 hls.dart → Task 3. §3 PlayerController quality + Dio → Task 4. §3 player_screen + status → Task 5. §5 testing → Tasks 2,3 unit + Task 6 on-device. ✓

**Type/name consistency:** `__allanimeSettleWithDeadline` (Task 2 hook) used only in its test. `HlsVariant{quality,url}`, `parseHlsMaster`, `fetchHlsVariants` (Task 3) used in Task 4. `PlayerController` gains `dio`, `qualities`, `activeQuality`, `selectQuality` — all referenced in Task 5. `_open` gains `keepQualities` param (Task 4) used by `selectQuality`. `sl<Dio>()` is registered (2A injector). `SourceContainer.hls`/`VideoSource` are existing models.

**Placeholder scan:** every step has concrete code; the only prose-instruction (Task 4 ctor Dio wiring) is unambiguous (add field + required param + initializer). The Task-4 `keepQualities` guard is spelled out to resolve the reset-vs-restore interaction. No TBD/TODO.

## Risks / notes
- **setTimeout bridge correctness** is only fully exercised on-device (Node uses native setTimeout for the Task-2 test). The on-device smoke (faster start) is the proof. If the bridge mis-fires, the per-fetch `timeoutMs` (Task 2 step 5) still bounds the call to ~8s, so latency is improved regardless.
- **Variant switch** re-opens the player at `_lastPos`; a brief rebuffer is expected (acceptable — it's an explicit user action).
- **qualities cleared on episode change:** `_open` (without `keepQualities`) resets the menu, so each episode/source re-expands correctly.
