# WATCH_APP Plan 2A — AllAnime provider + crypto bridge

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `getVideoSources(...)` on a real **AllAnime** provider return real, playable `.m3u8`/`.mp4` URLs — which requires adding a SHA-256 + AES-256-CTR crypto capability to the QuickJS runtime (AllAnime AES-encrypts its source list).

**Architecture:** Reuse the P0/P1 runtime unchanged. Add a **Dart-backed async crypto bridge** (mirrors the existing `fetch` bridge): JS host helpers `sha256Hex` / `aesCtrDecrypt` route through a new `crypto` message channel to Dart (`crypto` + `pointycastle`), with the Node harness mirroring them via `node:crypto`. The bundled `providers/allanime.js` uses these to decrypt the API's `tobeparsed` blob, then hex-decodes the `--`-prefixed source links and resolves them through AllAnime's `clock.json` endpoint.

**Tech Stack:** Dart 3, `pointycastle` (AES-CTR), `crypto` (SHA-256, already a dep), `flutter_js`, Node ≥18 (`node:crypto`).

**Scope note:** This is Plan **2A** of the playback vertical (spec: `docs/superpowers/specs/2026-05-30-watch-app-playback-vertical-design.md`). It delivers the data layer only — no player, no UI (that's Plan 2B). Deliverable is verifiable with `flutter test`, `node --test`, and a network-gated live test.

**Verified facts (live, 2026-05-30):**
- API: `https://api.allanime.day/api`; headers `Referer: https://youtu-chan.com`, `Origin: https://youtu-chan.com`, desktop Firefox UA.
- Search/episodes = plain POST; **sources = persisted-query GET** (hash `d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec`) returning `data.tobeparsed` (base64, AES-256-CTR).
- Decrypt: `key = SHA256("Xot36i3lK3:v1")` = `a254aa27c410f297bd04ba33a0c0df7ff4e706bf3ae27271c6703f84e750f552`; `iv = blob[1..13]`; `counter = iv ‖ 0x00000002`; `ciphertext = blob[13 .. len-16]`.
- Decrypted `episode.sourceUrls[]`: `--`-prefixed entries hex-decode (ani-cli table) → `/apivtwo/clock.json?id=…`; fetch `https://allanime.day<path>` → `links[]` (`link`,`resolutionStr`,`hls`). Direct `https://` entries (e.g. `Yt-mp4`) emit as-is. Embed hosts (`Ok`/`Ss-Hls`/`Mp4`/`Sl-mp4`) skipped in v1.

---

## File structure (this plan)

```
pubspec.yaml                                  # MODIFY: + pointycastle; + providers/allanime.js asset
lib/core/provider/
  crypto_ops.dart                             # NEW: pure-Dart sha256Hex + aesCtrDecryptToString
  js_bootstrap.dart                           # MODIFY: + crypto host helpers (sha256Hex/aesCtrDecrypt) + base64/hex JS utils
  provider_manager.dart                       # MODIFY: + onMessage('crypto', _onCrypto) handler
  ../di/injector.dart                         # MODIFY: load bundled allanime provider
test/provider/crypto_ops_test.dart            # NEW: Dart crypto unit tests
js_harness/
  host.mjs                                    # MODIFY: mirror crypto bridge via node:crypto
  crypto.test.mjs                             # NEW: harness crypto matches the vectors
  allanime.test.mjs                           # NEW: decode unit tests + network-gated live test
providers/allanime.js                         # NEW: the AllAnime provider
```

---

## Task 1: Dart crypto ops (`crypto_ops.dart`) — TDD

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/provider/crypto_ops.dart`
- Test: `test/provider/crypto_ops_test.dart`

- [ ] **Step 1: Add `pointycastle` to `pubspec.yaml`**

Under `dependencies:` add:
```yaml
  # AES-256-CTR for decrypting source lists from providers (e.g. AllAnime).
  pointycastle: ^3.9.1
```
Run: `cd "/Users/krishnavishwakarma/Programming Playground/watch_app" && flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 2: Write the failing test**

`test/provider/crypto_ops_test.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/crypto_ops.dart';

void main() {
  test('sha256Hex matches the AllAnime key vector', () {
    expect(
      sha256Hex('Xot36i3lK3:v1'),
      'a254aa27c410f297bd04ba33a0c0df7ff4e706bf3ae27271c6703f84e750f552',
    );
  });

  test('aesCtrDecryptToString decrypts a known CTR vector', () {
    final data = base64Decode('3t9fAEwGPNSaDqg4RX6JzX8rIZ/1Vpw=');
    final out = aesCtrDecryptToString(
      keyHex: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      counterHex: 'aabbccddeeff00112233445566778899',
      data: Uint8List.fromList(data),
    );
    expect(out, 'hello-watch_app-aes-ctr');
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `flutter test test/provider/crypto_ops_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '...crypto_ops.dart'`.

- [ ] **Step 4: Write `lib/core/provider/crypto_ops.dart`**

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Lowercase hex SHA-256 of [message] (UTF-8).
String sha256Hex(String message) =>
    crypto.sha256.convert(utf8.encode(message)).toString();

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// AES-256-CTR decrypt [data] with [keyHex] (32 bytes) and the 16-byte initial
/// counter [counterHex]; returns the plaintext decoded as UTF-8. Matches
/// OpenSSL/Node `aes-256-ctr` (full 128-bit big-endian counter increment).
String aesCtrDecryptToString({
  required String keyHex,
  required String counterHex,
  required Uint8List data,
}) {
  final cipher = CTRStreamCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(_hexToBytes(keyHex)),
        _hexToBytes(counterHex)));
  final out = cipher.process(data);
  return utf8.decode(out, allowMalformed: true);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/provider/crypto_ops_test.dart`
Expected: PASS (2 tests). If the AES test fails (wrong counter semantics), replace `CTRStreamCipher` with `SICStreamCipher` — both are in `pointycastle/export.dart`; the vector confirms which matches.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/core/provider/crypto_ops.dart test/provider/crypto_ops_test.dart
git commit -m "feat(2a): pure-Dart sha256Hex + AES-256-CTR decrypt (crypto_ops)"
```

---

## Task 2: Crypto bridge into the JS runtime

Adds promise-returning `sha256Hex` / `aesCtrDecrypt` host helpers (mirroring the `fetch` bridge) plus pure-JS base64/hex utilities, and the Dart `crypto` message handler. No unit test here (logic is in Task 1 + exercised by the harness in Task 3 and the provider in Task 5); verified by `flutter analyze`.

**Files:**
- Modify: `lib/core/provider/js_bootstrap.dart`
- Modify: `lib/core/provider/provider_manager.dart`

- [ ] **Step 1: Add crypto helpers to `kJsBootstrap`**

In `lib/core/provider/js_bootstrap.dart`, inside the `kJsBootstrap` raw string, immediately AFTER the `globalThis.__rejectFetch = function ...};` block, insert:

```javascript

var __pendingCrypto = {};
var __cryptoSeq = 0;
function __nextCryptoId() { __cryptoSeq += 1; return 'c' + __cryptoSeq; }
globalThis.__resolveCrypto = function(id, value) {
  var p = __pendingCrypto[id]; if (!p) return;
  delete __pendingCrypto[id]; p.resolve(value);
};
globalThis.__rejectCrypto = function(id, reason) {
  var p = __pendingCrypto[id]; if (!p) return;
  delete __pendingCrypto[id]; p.reject(reason);
};
function __crypto(op, payload) {
  var id = __nextCryptoId();
  var msg = { id: id, op: op };
  for (var k in payload) { if (payload.hasOwnProperty(k)) msg[k] = payload[k]; }
  var promise = new Promise(function(resolve, reject) {
    __pendingCrypto[id] = { resolve: resolve, reject: reject };
  });
  sendMessage('crypto', JSON.stringify(msg));
  return promise;
}
// Provider/extractor-facing crypto helpers (Promise-returning).
globalThis.sha256Hex = function(message) { return __crypto('sha256', { message: String(message) }); };
globalThis.aesCtrDecrypt = function(opts) {
  return __crypto('aesCtrDecrypt', { keyHex: opts.keyHex, counterHex: opts.counterHex, dataB64: opts.dataB64 });
};
// Pure-JS byte utilities (no host round-trip).
globalThis.base64ToBytes = function(b64) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var lookup = {}; for (var i = 0; i < chars.length; i++) lookup[chars.charAt(i)] = i;
  var s = String(b64).replace(/[^A-Za-z0-9+/]/g, '');
  var out = []; var n = s.length;
  for (var j = 0; j < n; j += 4) {
    var e1 = lookup[s.charAt(j)], e2 = lookup[s.charAt(j + 1)];
    var e3 = lookup[s.charAt(j + 2)], e4 = lookup[s.charAt(j + 3)];
    out.push((e1 << 2) | (e2 >> 4));
    if (j + 2 < n) out.push(((e2 & 15) << 4) | (e3 >> 2));
    if (j + 3 < n) out.push(((e3 & 3) << 6) | e4);
  }
  return out;
};
globalThis.bytesToHex = function(bytes) {
  var h = ''; for (var i = 0; i < bytes.length; i++) { var x = (bytes[i] & 255).toString(16); h += x.length === 1 ? '0' + x : x; } return h;
};
globalThis.bytesToB64 = function(bytes) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '', i = 0;
  while (i < bytes.length) {
    var c1 = bytes[i++] & 255, c2 = i < bytes.length ? bytes[i++] & 255 : NaN, c3 = i < bytes.length ? bytes[i++] & 255 : NaN;
    out += chars.charAt(c1 >> 2) + chars.charAt(((c1 & 3) << 4) | (c2 >> 4))
        + (isNaN(c2) ? '=' : chars.charAt(((c2 & 15) << 2) | (c3 >> 6)))
        + (isNaN(c3) ? '=' : chars.charAt(c3 & 63));
  }
  return out;
};
```

- [ ] **Step 2: Expose the crypto helpers to providers/extractors**

The helpers live on `globalThis`, so wrapped providers already see them. No wrapper change needed. (Confirm by re-reading `wrapProviderSource`: it does not shadow `sha256Hex`/`aesCtrDecrypt`/`base64ToBytes`.)

- [ ] **Step 3: Add the Dart `_onCrypto` handler in `provider_manager.dart`**

In `lib/core/provider/provider_manager.dart`:

(a) Add the import at the top, after the existing `import 'js_bootstrap.dart';`:
```dart
import 'crypto_ops.dart';
```
(b) In `_JsHost`'s constructor, after `_runtime.onMessage('console', _onConsole);`, add:
```dart
    _runtime.onMessage('crypto', _onCrypto);
```
(c) Add this method to `_JsHost` (next to `_onFetch`):
```dart
  void _onCrypto(dynamic raw) {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final op = payload['op'] as String;
      String result;
      if (op == 'sha256') {
        result = sha256Hex(payload['message'] as String);
      } else if (op == 'aesCtrDecrypt') {
        final data = base64Decode(payload['dataB64'] as String);
        result = aesCtrDecryptToString(
          keyHex: payload['keyHex'] as String,
          counterHex: payload['counterHex'] as String,
          data: Uint8List.fromList(data),
        );
      } else {
        throw FormatException('Unknown crypto op: $op');
      }
      _runtime.evaluate('__resolveCrypto(${jsonEncode(id)}, ${jsonEncode(result)});');
    } catch (e) {
      if (id != null) {
        _runtime.evaluate('__rejectCrypto(${jsonEncode(id)}, ${jsonEncode(e.toString())});');
      }
    }
  }
```
(d) Ensure these imports exist at the top of `provider_manager.dart` (add any missing):
```dart
import 'dart:convert';      // jsonEncode/base64Decode (jsonEncode already imported)
import 'dart:typed_data';   // Uint8List
```

- [ ] **Step 4: Verify it analyzes**

Run: `flutter analyze lib/core/provider/`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/core/provider/js_bootstrap.dart lib/core/provider/provider_manager.dart
git commit -m "feat(2a): Dart-backed crypto bridge (sha256Hex/aesCtrDecrypt) in the JS runtime"
```

---

## Task 3: Mirror the crypto bridge in the Node harness — TDD

So providers run identically offline. Uses `node:crypto` (already proven to decrypt the live AllAnime blob).

**Files:**
- Modify: `js_harness/host.mjs`
- Create: `js_harness/crypto.test.mjs`

- [ ] **Step 1: Write the failing test**

`js_harness/crypto.test.mjs`:
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import './host.mjs';

test('sha256Hex matches the AllAnime key vector', async () => {
  assert.equal(await globalThis.sha256Hex('Xot36i3lK3:v1'),
    'a254aa27c410f297bd04ba33a0c0df7ff4e706bf3ae27271c6703f84e750f552');
});

test('aesCtrDecrypt decrypts the known CTR vector', async () => {
  const out = await globalThis.aesCtrDecrypt({
    keyHex: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    counterHex: 'aabbccddeeff00112233445566778899',
    dataB64: '3t9fAEwGPNSaDqg4RX6JzX8rIZ/1Vpw=',
  });
  assert.equal(out, 'hello-watch_app-aes-ctr');
});

test('base64ToBytes + bytesToHex round-trip', () => {
  assert.equal(globalThis.bytesToHex(globalThis.base64ToBytes('AAEC')), '000102');
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test js_harness/crypto.test.mjs`
Expected: FAIL — `globalThis.sha256Hex is not a function`.

- [ ] **Step 3: Add the crypto mirror to `js_harness/host.mjs`**

At the top of `js_harness/host.mjs`, after `import fs from 'node:fs';`, add:
```js
import nodeCrypto from 'node:crypto';
```
Then, after the existing `globalThis.absUrl = ...;` assignment, add:
```js
globalThis.sha256Hex = async function (message) {
  return nodeCrypto.createHash('sha256').update(String(message)).digest('hex');
};
globalThis.aesCtrDecrypt = async function (opts) {
  const key = Buffer.from(opts.keyHex, 'hex');
  const ctr = Buffer.from(opts.counterHex, 'hex');
  const data = Buffer.from(opts.dataB64, 'base64');
  const d = nodeCrypto.createDecipheriv('aes-256-ctr', key, ctr);
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
};
globalThis.base64ToBytes = (b64) => Array.from(Buffer.from(String(b64), 'base64'));
globalThis.bytesToHex = (bytes) => Buffer.from(bytes).toString('hex');
globalThis.bytesToB64 = (bytes) => Buffer.from(bytes).toString('base64');
```

- [ ] **Step 4: Run to verify it passes**

Run: `node --test js_harness/crypto.test.mjs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add js_harness/host.mjs js_harness/crypto.test.mjs
git commit -m "test(2a): mirror crypto bridge in node harness via node:crypto"
```

---

## Task 4: AllAnime provider — search + episodes — TDD (live, network-gated)

**Files:**
- Create: `providers/allanime.js`
- Create: `js_harness/allanime.test.mjs`

- [ ] **Step 1: Write the failing test**

`js_harness/allanime.test.mjs`:
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

loadProvider('allanime', new URL('../providers/allanime.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (name, fn) => test(name, { skip: LIVE ? false : 'set RUN_LIVE=1 to run network test' }, fn);

test('getInfo reports an anime provider', async () => {
  const info = JSON.parse(await callProvider('allanime', 'getInfo', []));
  assert.equal(info.type, 'anime');
  assert.equal(info.name, 'AllAnime');
});

live('search returns results for "one piece"', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0, 'expected results');
  assert.ok(rows[0].id && rows[0].title && rows[0].url);
  assert.equal(rows[0].type, 'anime');
});

live('getEpisodes returns a non-empty list for the first result', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  const detail = JSON.parse(await callProvider('allanime', 'getDetail', [rows[0].url]));
  assert.ok(detail.episodes.length > 0, 'expected episodes');
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test js_harness/allanime.test.mjs`
Expected: FAIL — `Cannot find module '.../providers/allanime.js'` (the `getInfo` test errors at load).

- [ ] **Step 3: Write `providers/allanime.js` (getInfo/search/getDetail/getEpisodes)**

```js
// AllAnime provider — https://allanime.to (API: https://api.allanime.day/api)
// Sources are AES-encrypted; getVideoSources is added in the next task.

var API = 'https://api.allanime.day/api';
var REFERER = 'https://youtu-chan.com';
var ORIGIN = 'https://youtu-chan.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0';
var SOURCE_ID = 'allanime';

var SEARCH_GQL = 'query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name thumbnail availableEpisodes __typename } }}';
var SHOW_GQL = 'query ($showId: String!) { show( _id: $showId ) { _id name thumbnail description availableEpisodesDetail }}';

function _headers() { return { 'Referer': REFERER, 'Origin': ORIGIN, 'User-Agent': UA, 'Content-Type': 'application/json' }; }

function _post(query, variables) {
  return fetch(API, { method: 'POST', headers: _headers(), body: JSON.stringify({ variables: variables, query: query }) })
    .then(function (r) { try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('AllAnime: bad JSON (' + r.status + ')'); } });
}

function getInfo() {
  return { name: 'AllAnime', lang: 'en', baseUrl: 'https://allanime.to', logo: 'https://allanime.to/favicon.ico', type: 'anime', version: '1.0.0' };
}

// A show "url" we round-trip is just the show id (AllAnime has no page URL we need).
function _mode(opts) { var m = (opts && opts.category) || 'sub'; return (m === 'dub') ? 'dub' : 'sub'; }

function search(query, page, opts) {
  var vars = { search: { allowAdult: false, allowUnknown: false, query: String(query || '') }, limit: 26, page: page || 1, translationType: _mode(opts), countryOrigin: 'ALL' };
  return _post(SEARCH_GQL, vars).then(function (j) {
    var edges = (j && j.data && j.data.shows && j.data.shows.edges) || [];
    var out = [];
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      out.push({ id: e._id, title: e.name, cover: e.thumbnail || null, url: e._id, type: 'anime', sourceId: SOURCE_ID });
    }
    return out;
  });
}

function _episodesFromDetail(detailNode) {
  var d = (detailNode && detailNode.availableEpisodesDetail) || {};
  var sub = (d.sub || []).slice();
  var dub = (d.dub || []).slice();
  // Build Episode list (sub preferred; mark dub-only numbers too). Numeric sort asc.
  var nums = {};
  sub.forEach(function (n) { nums[n] = true; });
  dub.forEach(function (n) { nums[n] = true; });
  var keys = Object.keys(nums).sort(function (a, b) { return parseFloat(a) - parseFloat(b); });
  var eps = [];
  for (var i = 0; i < keys.length; i++) {
    var n = keys[i];
    eps.push({ id: n, title: 'Episode ' + n, number: parseFloat(n), url: 'ep://' + n });
  }
  return eps;
}

function getDetail(url) {
  var showId = String(url);
  return _post(SHOW_GQL, { showId: showId }).then(function (j) {
    var show = (j && j.data && j.data.show) || {};
    return {
      id: showId, title: show.name || showId, cover: show.thumbnail || null,
      url: showId, description: show.description || '', status: 'unknown',
      genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID,
      episodes: _episodesFromDetail(show)
    };
  });
}

function getEpisodes(url) {
  return getDetail(url).then(function (d) { return d.episodes; });
}
```

- [ ] **Step 4: Run the offline test to verify `getInfo` passes (live tests skip)**

Run: `node --test js_harness/allanime.test.mjs`
Expected: PASS for `getInfo`; the two `live(...)` tests report **skipped** (`set RUN_LIVE=1 to run network test`).

- [ ] **Step 5: Run the live tests once to confirm the real API works**

Run: `RUN_LIVE=1 node --test js_harness/allanime.test.mjs`
Expected: PASS — search returns results, episodes non-empty. (If these 400, AllAnime rotated something; re-pull current values from ani-cli `master` and update `providers/allanime.js`.)

- [ ] **Step 6: Commit**

```bash
git add providers/allanime.js js_harness/allanime.test.mjs
git commit -m "feat(2a): AllAnime provider search + episodes (live-verified)"
```

---

## Task 5: AllAnime `getVideoSources` — decrypt + decode + clock resolve — TDD

**Files:**
- Modify: `providers/allanime.js`
- Modify: `js_harness/allanime.test.mjs`

- [ ] **Step 1: Add the failing tests**

Append to `js_harness/allanime.test.mjs`:
```js
test('decodeSourceUrl maps the hex-substitution table', async () => {
  // The provider exposes its decoder as a test hook on globalThis.
  const dec = globalThis.__allanimeDecodeSourceUrl;
  assert.equal(typeof dec, 'function', 'decoder hook missing');
  assert.equal(dec('--175948514e4c4f57'), '/apivtwo');     // / a p i v t w o
  assert.equal(dec('--175b54575b53'), '/clock.json');       // /clock -> /clock.json
  assert.equal(dec('https://x/y.m3u8'), 'https://x/y.m3u8'); // non -- passthrough
});

live('getVideoSources returns a playable stream for One Piece ep 1', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  const detail = JSON.parse(await callProvider('allanime', 'getDetail', [rows[0].url]));
  const ep1 = detail.episodes.find(function (e) { return e.number === 1; }) || detail.episodes[0];
  // episodeUrl encodes (showId, mode, number); see provider.
  const epUrl = 'allanime://' + rows[0].url + '/sub/' + ep1.number;
  const sources = JSON.parse(await callProvider('allanime', 'getVideoSources', [epUrl]));
  assert.ok(sources.length > 0, 'expected sources');
  assert.ok(sources.some(function (s) { return /\.m3u8|\.mp4|fast4speed|wixmp/.test(s.url); }),
    'expected a playable url');
  assert.ok(sources.every(function (s) { return s.headers && s.headers.Referer; }), 'headers present');
});
```

Also update the episode `url` shape so `getVideoSources` has what it needs. In `providers/allanime.js`, change the `eps.push(...)` line inside `_episodesFromDetail` — BUT `_episodesFromDetail` doesn't know the showId/mode. Instead, set the episode url in `getDetail` after building. Replace `getDetail`'s `episodes: _episodesFromDetail(show)` by post-processing (done in Step 2).

- [ ] **Step 2: Run to verify the decode test fails**

Run: `node --test js_harness/allanime.test.mjs`
Expected: FAIL — `decoder hook missing` (and the live source test skipped).

- [ ] **Step 3: Implement `getVideoSources` + decoder in `providers/allanime.js`**

(a) Add the persisted-query constant near the top constants:
```js
var SOURCES_HASH = 'd405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec';
var ALLANIME_KEY_SEED = 'Xot36i3lK3:v1';
```

(b) Add the hex-decode table + decoder + test hook anywhere after the constants:
```js
var _HEXMAP = {"79":"A","7a":"B","7b":"C","7c":"D","7d":"E","7e":"F","7f":"G","70":"H","71":"I","72":"J","73":"K","74":"L","75":"M","76":"N","77":"O","68":"P","69":"Q","6a":"R","6b":"S","6c":"T","6d":"U","6e":"V","6f":"W","60":"X","61":"Y","62":"Z","59":"a","5a":"b","5b":"c","5c":"d","5d":"e","5e":"f","5f":"g","50":"h","51":"i","52":"j","53":"k","54":"l","55":"m","56":"n","57":"o","48":"p","49":"q","4a":"r","4b":"s","4c":"t","4d":"u","4e":"v","4f":"w","40":"x","41":"y","42":"z","08":"0","09":"1","0a":"2","0b":"3","0c":"4","0d":"5","0e":"6","0f":"7","00":"8","01":"9","15":"-","16":".","67":"_","46":"~","02":":","17":"/","07":"?","1b":"#","63":"[","65":"]","78":"@","19":"!","1c":"$","1e":"&","10":"(","11":")","12":"*","13":"+","14":",","03":";","05":"=","1d":"%"};

function decodeSourceUrl(s) {
  s = String(s);
  if (s.indexOf('--') !== 0) return s;
  var body = s.slice(2), out = '';
  for (var i = 0; i + 1 < body.length; i += 2) { var ch = _HEXMAP[body.substr(i, 2)]; out += (ch == null ? '' : ch); }
  return out.replace('/clock', '/clock.json');
}
globalThis.__allanimeDecodeSourceUrl = decodeSourceUrl; // test hook
```

(c) Give episodes a self-describing url. In `getDetail`, replace the return's
`episodes: _episodesFromDetail(show)` with a post-processed list:
```js
    var eps = _episodesFromDetail(show);
    for (var k = 0; k < eps.length; k++) {
      eps[k].url = 'allanime://' + showId + '/sub/' + eps[k].number;
    }
    return {
      id: showId, title: show.name || showId, cover: show.thumbnail || null,
      url: showId, description: show.description || '', status: 'unknown',
      genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID, episodes: eps
    };
```
(remove the old single `return { ... episodes: _episodesFromDetail(show) }` object — there must be exactly one return).

(d) Add the sources query + decrypt + resolve functions and `getVideoSources`:
```js
var SOURCES_GQL = 'query ($showId: String!, $translationType: VaildTranslationTypeEnumType!, $episodeString: String!) { episode( showId: $showId translationType: $translationType episodeString: $episodeString ) { episodeString sourceUrls }}';

// Persisted-query GET; response is AES-encrypted under data.tobeparsed.
function _fetchSourceUrls(showId, mode, epNo) {
  var variables = encodeURIComponent(JSON.stringify({ showId: showId, translationType: mode, episodeString: String(epNo) }));
  var extensions = encodeURIComponent(JSON.stringify({ persistedQuery: { version: 1, sha256Hash: SOURCES_HASH } }));
  var url = API + '?variables=' + variables + '&extensions=' + extensions;
  return fetch(url, { headers: { 'Referer': REFERER, 'Origin': ORIGIN, 'User-Agent': UA } })
    .then(function (r) {
      var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { throw new Error('AllAnime sources: bad JSON'); }
      var data = j && j.data;
      if (data && data.tobeparsed) return _decryptTobeparsed(data.tobeparsed);
      if (data && data.episode && data.episode.sourceUrls) return data.episode.sourceUrls;
      throw new Error('AllAnime: no sources in response');
    });
}

// AES-256-CTR decrypt of the tobeparsed blob -> sourceUrls[].
function _decryptTobeparsed(b64) {
  return sha256Hex(ALLANIME_KEY_SEED).then(function (keyHex) {
    var bytes = base64ToBytes(b64);
    var iv = bytes.slice(1, 13);
    var counterHex = bytesToHex(iv) + '00000002';
    var ct = bytes.slice(13, bytes.length - 16);
    return aesCtrDecrypt({ keyHex: keyHex, counterHex: counterHex, dataB64: bytesToB64(ct) })
      .then(function (plain) {
        var obj; try { obj = JSON.parse(plain); } catch (e) { throw new Error('AllAnime: decrypt parse failed'); }
        return (obj.episode && obj.episode.sourceUrls) || obj.sourceUrls || [];
      });
  });
}

// Resolve a clock.json path into VideoSource objects.
function _resolveClock(path, mode) {
  return fetch('https://allanime.day' + path, { headers: { 'Referer': REFERER, 'User-Agent': UA } })
    .then(function (r) {
      var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { return []; }
      var links = (j && j.links) || [];
      var out = [];
      for (var i = 0; i < links.length; i++) {
        var lk = links[i]; var u = lk.link || lk.url; if (!u) continue;
        var isHls = lk.hls === true || /\.m3u8/.test(u) || /repackager\.wixmp/.test(u);
        out.push({ url: u, quality: lk.resolutionStr || '', container: isHls ? 'hls' : 'mp4',
          headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja', subtitles: [] });
      }
      return out;
    });
}

function getVideoSources(episodeUrl) {
  // episodeUrl: allanime://<showId>/<mode>/<number>
  var m = String(episodeUrl).replace('allanime://', '').split('/');
  var showId = m[0], mode = (m[1] === 'dub') ? 'dub' : 'sub', epNo = m[2];
  return _fetchSourceUrls(showId, mode, epNo).then(function (sourceUrls) {
    var EMBED = { 'Ok': 1, 'Ss-Hls': 1, 'Mp4': 1, 'Sl-mp4': 1 }; // skipped in v1 (need extractors)
    var jobs = [];
    for (var i = 0; i < sourceUrls.length; i++) {
      var su = sourceUrls[i]; var name = su.sourceName || ''; var raw = String(su.sourceUrl || '');
      if (EMBED[name]) continue;
      if (raw.indexOf('--') === 0) {
        var path = decodeSourceUrl(raw);
        if (path.indexOf('/apivtwo/clock') !== -1) jobs.push(_resolveClock(path, mode));
      } else if (/^https?:\/\//.test(raw)) {
        jobs.push(Promise.resolve([{ url: raw, quality: '', container: /\.m3u8/.test(raw) ? 'hls' : 'mp4',
          headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja', subtitles: [] }]));
      }
    }
    return Promise.all(jobs).then(function (lists) {
      var all = []; for (var k = 0; k < lists.length; k++) all = all.concat(lists[k]);
      if (all.length === 0) throw new Error('AllAnime: no playable sources');
      return all;
    });
  });
}
```

- [ ] **Step 4: Run the offline decode test**

Run: `node --test js_harness/allanime.test.mjs`
Expected: PASS for `getInfo` + `decodeSourceUrl` (3 assertions); live tests skipped.

- [ ] **Step 5: Run the live source test**

Run: `RUN_LIVE=1 node --test js_harness/allanime.test.mjs`
Expected: PASS — `getVideoSources` returns ≥1 source whose url matches `.m3u8|.mp4|fast4speed|wixmp`, all with `headers.Referer`. This exercises the full path: persisted GET → AES decrypt (crypto bridge) → hex decode → clock resolve.

- [ ] **Step 6: Commit**

```bash
git add providers/allanime.js js_harness/allanime.test.mjs
git commit -m "feat(2a): AllAnime getVideoSources — AES decrypt + hex decode + clock resolve (live-verified)"
```

---

## Task 6: Bundle the AllAnime provider into the app

Makes the provider loadable in-app alongside the example. Verified by `flutter analyze` + `flutter test`; on-device load is part of Plan 2B.

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/core/di/injector.dart`

- [ ] **Step 1: Declare the asset in `pubspec.yaml`**

Under `flutter: assets:` add the line (keep the existing two):
```yaml
    - providers/allanime.js
```
Run: `flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 2: Load it in `initDependencies()`**

In `lib/core/di/injector.dart`, after the existing `manager.load(sourceId: 'example', ...)` block, add:
```dart
  final allanimeJs = await rootBundle.loadString('providers/allanime.js');
  manager.load(
    sourceId: 'allanime',
    jsSource: allanimeJs,
    originRepoUrl: 'bundled://',
    displayName: 'Bundled',
  );
```

- [ ] **Step 3: Verify analyze + existing tests still pass**

Run: `flutter analyze`
Expected: `No issues found!`
Run: `flutter test`
Expected: all pass (10 model + 2 crypto_ops = 12).

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml lib/core/di/injector.dart
git commit -m "feat(2a): bundle AllAnime provider into the app runtime"
```

---

## Self-review (spec coverage)

- **§1 AllAnime provider** (search/episodes/sources, persisted GET, AES decrypt, hex decode, clock resolve, embed-skip, headers) → Tasks 4, 5. ✓
- **§1.5 crypto capability** (`sha256Hex`/`aesCtrDecrypt`, Dart `crypto`+`pointycastle`, Node mirror) → Tasks 1, 2, 3. ✓
- **§6 testing** (decode unit tests, network-gated live test, no-flaky-default) → Tasks 4, 5 (`RUN_LIVE` gate); crypto unit tests Tasks 1, 3. ✓
- **§7 Plan 2A deliverable** (`getVideoSources` returns real `.m3u8`/`.mp4`) → Task 5 live test. ✓
- Player/UI/resume/autoplay → **Plan 2B** (out of scope here). ✓

**Type/name consistency:** crypto helpers named identically across Dart (`sha256Hex`, `aesCtrDecryptToString`), JS bootstrap (`sha256Hex`, `aesCtrDecrypt`), Node harness, and provider use. Episode `url` shape `allanime://<showId>/<mode>/<number>` is produced in `getDetail` and parsed in `getVideoSources`. `container`/`kind`/`subtitles`/`headers` match the Task-4 `VideoSource` model from P1.

**Placeholder scan:** no TBD/TODO; every code step has full code; crypto vectors and the persisted-query hash are real, live-verified values; the one contingency (`CTRStreamCipher`→`SICStreamCipher`) is gated by a deterministic test, not left open.

## Notes / risks

- **AllAnime drift:** the persisted-query hash, `Referer` host, and AES key seed change over time. The live tests catch it; the fix is editing constants in `providers/allanime.js` (re-derive from ani-cli `master`). This is the expected hosted-provider maintenance.
- **Live tests are network-gated** (`RUN_LIVE=1`) so the default `node --test js_harness/` stays deterministic and offline-green.
