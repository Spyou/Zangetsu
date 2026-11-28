import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../download/hls_downloader.dart';
import '../logging/app_logger.dart';

/// Rewrites an HLS playlist so every URI it references — variant playlists,
/// media segments, encryption keys, alternate audio/subtitle renditions and
/// init maps — routes back through the local cast proxy instead of being
/// fetched directly by the Chromecast.
///
/// [base] is the absolute URL the playlist was fetched from (used to resolve
/// relative URIs). [proxify] maps an absolute upstream URL to a proxy URL.
///
/// Pure + side-effect-free so it can be unit-tested without a live server.
String rewriteHlsPlaylist(
  String body,
  Uri base,
  String Function(Uri absolute) proxify,
) {
  final out = StringBuffer();
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      out.writeln();
      continue;
    }
    if (line.startsWith('#')) {
      // Tag lines may embed a URI="..." attribute (EXT-X-KEY, EXT-X-MEDIA,
      // EXT-X-MAP, EXT-X-I-FRAME-STREAM-INF). Rewrite it in place; other tags
      // pass through untouched.
      out.writeln(_rewriteUriAttr(line, base, proxify));
      continue;
    }
    // A bare URI line — a segment or a variant playlist.
    out.writeln(proxify(base.resolve(line)));
  }
  return out.toString();
}

final _uriAttr = RegExp(r'URI="([^"]*)"');
String _rewriteUriAttr(String line, Uri base, String Function(Uri) proxify) {
  return line.replaceAllMapped(
    _uriAttr,
    (m) => 'URI="${proxify(base.resolve(m.group(1)!))}"',
  );
}

/// HLS container the Cast receiver must be told about. CAF defaults to
/// MPEG-TS; an fMP4/CMAF playlist then loads for a second and dies with
/// `Invalid Request` / status 2001.
enum CastHlsContainer { ts, fmp4 }

/// Peek a playlist (master or media) and decide TS vs fMP4. Null when the
/// body is a master with no segment hints — caller should fetch a variant.
CastHlsContainer? sniffHlsContainer(String body) {
  final lower = body.toLowerCase();
  if (lower.contains('#ext-x-map') ||
      RegExp(r'\.m4s(\?|"|\s|$)').hasMatch(lower) ||
      RegExp(r'\.cmfv(\?|"|\s|$)').hasMatch(lower)) {
    return CastHlsContainer.fmp4;
  }
  if (RegExp(r'\.ts(\?|"|\s|$)').hasMatch(lower)) {
    return CastHlsContainer.ts;
  }
  return null;
}

/// Decode a playlist body that may still be gzip/deflate compressed.
///
/// The streaming [HttpClient] keeps `autoUncompress = false` so TS/fMP4
/// segments stay byte-accurate. HLS CDNs (nexabloom, …) often still send
/// playlists as gzip (`1f 8b`); UTF-8-decoding that throws
/// `FormatException: Unexpected extension byte (at offset 1)` and the
/// Chromecast sees a 502 → Invalid Request / 2001.
String decodePossiblyCompressedUtf8(List<int> raw, {String? contentEncoding}) {
  if (raw.isEmpty) return '';
  final enc = contentEncoding?.toLowerCase();
  final gzipMagic = raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b;
  List<int> payload = raw;
  if (enc == 'gzip' || gzipMagic) {
    payload = gzip.decode(raw);
  } else if (enc == 'deflate') {
    payload = zlib.decode(raw);
  }
  return utf8.decode(payload);
}

/// First `#EXT-X-STREAM-INF` variant URI, resolved against [base]. Null when
/// [body] is not a master playlist.
String? firstHlsVariantUri(String body, Uri base) {
  var pending = false;
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      pending = true;
      continue;
    }
    if (pending && line.isNotEmpty && !line.startsWith('#')) {
      return base.resolve(line).toString();
    }
  }
  return null;
}

/// How many `#EXT-X-STREAM-INF` variants a master lists. Used to flatten a
/// single-variant master (nexabloom's 257-byte playlists) so CAF never has
/// to follow a proxied child playlist.
int hlsVariantCount(String body) =>
    RegExp(r'^#EXT-X-STREAM-INF', multiLine: true).allMatches(body).length;

/// Caption files the proxy must serve as text (never unwrap-as-media).
bool looksSubtitleUri(String uri) {
  final path = uri.toLowerCase().split('?').first;
  return path.endsWith('.vtt') ||
      path.endsWith('.srt') ||
      path.endsWith('.ass') ||
      path.endsWith('.ssa');
}

/// True when [text] looks like SubRip (comma timestamps), not WebVTT.
bool looksLikeSrt(String text) {
  final t = text.trimLeft();
  if (t.toUpperCase().startsWith('WEBVTT')) return false;
  return RegExp(
    r'\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}',
  ).hasMatch(t);
}

/// Convert SubRip to WebVTT. The Default Media Receiver rejects SRT.
String srtToWebVtt(String srt) {
  final text = srt.replaceFirst(RegExp(r'^\uFEFF'), '');
  if (text.trimLeft().toUpperCase().startsWith('WEBVTT')) return text;
  final converted = text.replaceAllMapped(
    RegExp(r'(\d{2}:\d{2}:\d{2}),(\d{3})'),
    (m) => '${m[1]}.${m[2]}',
  );
  return 'WEBVTT\n\n$converted';
}

/// CDNs that hide HLS segments behind decoy extensions (nexabloom `.jpg`,
/// later segments `.ico`, some hosts `.js`/`.css`). Anything that isn't a
/// real media suffix is treated as a decoy — an allowlist kept missing `.ico`
/// and CAF got an icon file as "segment 26".
bool looksDisguisedHlsSegment(String uri) {
  final path = uri.toLowerCase().split('?').first;
  const real = [
    '.ts',
    '.m4s',
    '.mp4',
    '.m4v',
    '.aac',
    '.m4a',
    '.cmfv',
    '.cmfa',
  ];
  return !real.any(path.endsWith);
}

/// Pull the base64url payload out of `/p/<token>/<encoded>/name` or `?u=`.
String? castProxyEncodedPayload(List<String> segs, String? queryU) {
  if (queryU != null && queryU.isNotEmpty) return queryU;
  if (segs.length >= 3 && segs[0] == 'p') return segs[2];
  return null;
}

/// A tiny on-device HTTP server that lets a Chromecast play header-locked
/// streams. The Chromecast can't send custom request headers (Referer /
/// User-Agent / cookies), so it 403s on the origin. This server sits on the
/// phone's LAN address, fetches the real stream WITH the headers, and re-serves
/// it — rewriting HLS playlists so segments are proxied too. The Chromecast
/// only ever sees a plain `http://<phone-lan-ip>:<port>/…` URL.
///
/// Pure Dart (`dart:io`), no external dependency, no hosting. One session at a
/// time (we only cast one thing at once); [serve] replaces the previous.
///
// ponytail: proxying runs on the app isolate — fine for I/O-bound streaming;
// move to a background isolate only if a 4K cast measurably janks the UI.
class CastProxyServer {
  HttpServer? _server;
  String? _token;
  String? _basePrefix; // http://ip:port/p/<token>
  Map<String, String> _headers = const {};

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  bool get isRunning => _server != null;

  /// CAF `hlsSegmentFormat` for the last [serve] (`ts` / `fmp4`).
  String? lastHlsSegmentFormat;

  /// CAF `hlsVideoSegmentFormat` for the last [serve] (`mpeg2_ts` / `fmp4`).
  String? lastHlsVideoSegmentFormat;

  /// Upstream URL actually advertised to the receiver (media playlist when we
  /// flattened a single-variant master).
  String? lastUpstreamUrl;

  /// Start (if needed) and configure the proxy for [headers], then return the
  /// proxy URL the Chromecast should load for [upstreamUrl]. Returns null when
  /// no usable LAN address is available (caller should fall back to the direct
  /// URL — casting will then only work for un-protected streams).
  Future<String?> serve(
    String upstreamUrl,
    Map<String, String>? headers,
  ) async {
    _headers = headers ?? const {};
    lastHlsSegmentFormat = null;
    lastHlsVideoSegmentFormat = null;
    lastUpstreamUrl = upstreamUrl;
    await _ensureStarted();
    final server = _server;
    if (server == null) return null;
    final ip = await _lanIp();
    if (ip == null) return null;
    _basePrefix = 'http://$ip:${server.port}/p/$_token';
    await _sniffFormats(upstreamUrl);
    return proxify(lastUpstreamUrl ?? upstreamUrl);
  }

  /// Wrap any upstream URL (e.g. a subtitle track) in the running proxy so it
  /// too is fetched with the session headers. Null if the proxy isn't running.
  String? proxify(String upstreamUrl) {
    final prefix = _basePrefix;
    if (prefix == null) return null;
    final encoded = base64Url.encode(utf8.encode(upstreamUrl));
    // Path-only — CAF is unreliable following `?u=` on HLS playlists.
    // Caption URLs keep a `.vtt` suffix so the receiver treats them as text
    // tracks (the proxy converts SRT → VTT before serving).
    final lower = upstreamUrl.toLowerCase();
    final name = lower.contains('.m3u8')
        ? 'master.m3u8'
        : (looksSubtitleUri(upstreamUrl) ? 'subs.vtt' : 'seg');
    return '$prefix/$encoded/$name';
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _token = _randomToken();
    // anyIPv4 so the Chromecast can reach it on the phone's LAN address; port 0
    // picks a free ephemeral port.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen(_handle, onError: (_) {});
    _server = server;
  }

  Future<void> stop() async {
    _basePrefix = null;
    _token = null;
    final s = _server;
    _server = null;
    try {
      await s?.close(force: true);
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    _applyCors(res);
    try {
      // Cast default receiver preflights with OPTIONS (Range / Origin).
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        await res.close();
        return;
      }
      // Token gate — never act as an open proxy for other LAN devices.
      final segs = req.uri.pathSegments;
      if (segs.length < 2 || segs[0] != 'p' || segs[1] != _token) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      final encoded = castProxyEncodedPayload(
        segs,
        req.uri.queryParameters['u'],
      );
      if (encoded == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      final target = Uri.parse(utf8.decode(base64Url.decode(encoded)));

      final upReq = await _client.getUrl(target);
      _headers.forEach(upReq.headers.set);
      // Playlists are text; ask for identity so we don't have to gunzip.
      // Segments keep whatever the CDN sends (usually uncompressed).
      final looksHls = target.path.toLowerCase().endsWith('.m3u8');
      if (looksHls) {
        upReq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      }
      // Never forward Range onto a segment. Decoy-wrapped files must be read
      // whole so we can peel JPEG/ICO/… and then range the unwrapped media.
      final upRes = await upReq.close();

      final ctype = upRes.headers.contentType?.mimeType.toLowerCase() ?? '';
      final isHls = looksHls || ctype.contains('mpegurl');

      final destName = segs.isNotEmpty ? segs.last.toLowerCase() : '';
      final isSub = looksSubtitleUri(target.path) || destName == 'subs.vtt';

      if (isHls) {
        final body = await _readPlaylistText(upRes);
        final rewritten = rewriteHlsPlaylist(
          body,
          target,
          // Absolute URLs — CAF is unreliable at resolving path-absolute
          // `/p/…?u=` variants against a playlist that itself has a query.
          (abs) => proxify(abs.toString()) ?? abs.toString(),
        );
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        res.write(rewritten);
        await res.close();
      } else if (isSub) {
        // Never unwrap captions as TS/fMP4. DMR only accepts WebVTT.
        final raw = await _readBytes(upRes);
        var text = decodePossiblyCompressedUtf8(
          raw,
          contentEncoding: upRes.headers.value(
            HttpHeaders.contentEncodingHeader,
          ),
        );
        if (looksLikeSrt(text) || target.path.toLowerCase().endsWith('.srt')) {
          text = srtToWebVtt(text);
        }
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
        res.write(text);
        await res.close();
      } else {
        // Every media URI — `.jpg`, `.ico`, `.ts`, keys — goes through unwrap.
        // An allowlist missed nexabloom's `.ico` segments and CAF got an icon.
        final raw = await _readBytes(upRes);
        final media = hlsUnwrapSegment(raw) ?? raw;
        final mime = _mediaMime(media);
        await _writeMedia(
          res,
          media,
          mime: mime,
          rangeHeader: req.headers.value(HttpHeaders.rangeHeader),
        );
      }
    } catch (e) {
      _log('[cast-proxy] error: $e', level: 'E');
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
  }

  void _log(String message, {String level = 'I'}) {
    AppLogger.instance.log(message, level: level);
  }

  void _applyCors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    res.headers.set(
      'Access-Control-Allow-Headers',
      'Range, Origin, Accept, Content-Type',
    );
    res.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Length, Content-Range, Accept-Ranges, Content-Type',
    );
  }

  Future<String> _readPlaylistText(HttpClientResponse res) async {
    final raw = await _readBytes(res);
    return decodePossiblyCompressedUtf8(
      raw,
      contentEncoding: res.headers.value(HttpHeaders.contentEncodingHeader),
    );
  }

  Future<Uint8List> _readBytes(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    final raw = builder.takeBytes();
    final enc = res.headers
        .value(HttpHeaders.contentEncodingHeader)
        ?.toLowerCase();
    final gzipMagic = raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b;
    if (enc == 'gzip' || gzipMagic) {
      return Uint8List.fromList(gzip.decode(raw));
    }
    if (enc == 'deflate') {
      return Uint8List.fromList(zlib.decode(raw));
    }
    return raw;
  }

  String _mediaMime(Uint8List media) {
    if (media.isNotEmpty && media[0] == 0x47) return 'video/mp2t';
    if (isoLooksLikeFmp4(media)) return 'video/mp4';
    return 'application/octet-stream';
  }

  Future<void> _writeMedia(
    HttpResponse res,
    Uint8List data, {
    required String mime,
    String? rangeHeader,
  }) async {
    res.headers.contentType = ContentType.parse(mime);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = _byteRange(rangeHeader, data.length);
    if (range != null) {
      final end = range.$2;
      final slice = data.sublist(range.$1, end + 1);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.$1}-$end/${data.length}',
      );
      res.contentLength = slice.length;
      res.add(slice);
    } else {
      res.statusCode = HttpStatus.ok;
      res.contentLength = data.length;
      res.add(data);
    }
    await res.close();
  }

  /// Parses `Range: bytes=start-end` against [length]. Null if absent/invalid.
  (int, int)? _byteRange(String? header, int length) {
    if (header == null || length <= 0) return null;
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!) ?? 0;
    final rawEnd = m.group(2);
    final end = (rawEnd == null || rawEnd.isEmpty)
        ? length - 1
        : (int.tryParse(rawEnd) ?? length - 1);
    if (start >= length || start > end) return null;
    return (start, end.clamp(start, length - 1));
  }

  Future<Uint8List?> _fetchBytes(String url) async {
    final req = await _client.getUrl(Uri.parse(url));
    _headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final res = await req.close();
    if (res.statusCode >= 400) {
      await res.drain<void>();
      return null;
    }
    return _readBytes(res);
  }

  Future<String?> _fetchText(String url) async {
    final req = await _client.getUrl(Uri.parse(url));
    _headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final res = await req.close();
    if (res.statusCode >= 400) {
      await res.drain<void>();
      return null;
    }
    return _readPlaylistText(res);
  }

  Future<void> _sniffFormats(String upstreamUrl) async {
    // CAF defaults to MPEG-TS. fMP4 without an explicit hint is the usual
    // "title + spinner for 2s → Invalid Request / 2001" failure on Shield.
    void apply(CastHlsContainer c) {
      switch (c) {
        case CastHlsContainer.fmp4:
          lastHlsSegmentFormat = 'fmp4';
          lastHlsVideoSegmentFormat = 'fmp4';
        case CastHlsContainer.ts:
          lastHlsSegmentFormat = 'ts';
          lastHlsVideoSegmentFormat = 'mpeg2_ts';
      }
    }

    try {
      if (!upstreamUrl.toLowerCase().contains('.m3u8')) return;
      var body = await _fetchText(upstreamUrl);
      if (body == null) return;
      var container = sniffHlsContainer(body);
      if (container == null) {
        final variant = firstHlsVariantUri(body, Uri.parse(upstreamUrl));
        if (variant != null) {
          // Single-variant masters: hand CAF the media playlist directly so
          // it never has to follow a proxied child URI.
          if (hlsVariantCount(body) == 1) lastUpstreamUrl = variant;
          body = await _fetchText(variant);
          if (body != null) container = sniffHlsContainer(body);
        }
      }
      // nexabloom-style `.jpg` segments have no .ts/.m4s hint in the playlist.
      // Fetch the first one and peel the decoy so CAF gets ts vs fmp4 right.
      if (body != null && container == null) {
        final first = hlsFirstUriLine(body);
        if (first != null) {
          final abs = Uri.parse(lastUpstreamUrl ?? upstreamUrl).resolve(first);
          if (looksDisguisedHlsSegment(abs.path)) {
            final bytes = await _fetchBytes(abs.toString());
            if (bytes != null) {
              final media = hlsUnwrapSegment(bytes) ?? bytes;
              if (media.isNotEmpty && media[0] == 0x47) {
                container = CastHlsContainer.ts;
              } else if (isoLooksLikeFmp4(media)) {
                container = CastHlsContainer.fmp4;
              }
              _log(
                '[cast-proxy] sniff segment ${hlsSegmentMagic(bytes)} → '
                '${container ?? "unknown"}',
              );
            }
          }
        }
      }
      apply(container ?? CastHlsContainer.ts);
      _log(
        '[cast-proxy] sniff ${lastHlsSegmentFormat ?? "none"} '
        '(${container == null ? "defaulted" : "playlist"}'
        '${lastUpstreamUrl != upstreamUrl ? ", flattened" : ""})',
      );
    } catch (e) {
      apply(CastHlsContainer.ts);
      _log('[cast-proxy] sniff failed: $e', level: 'W');
    }
  }

  /// The phone's LAN IPv4 the Chromecast can actually reach. Prefers the Wi-Fi
  /// interface, skips VPN/virtual/cellular interfaces whose private IP the
  /// Chromecast can't route to (a common cause of "cast connects but nothing
  /// plays"). Null if the device isn't on a reachable network.
  Future<String?> _lanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Pass 1: a real Wi-Fi interface with a private LAN IP.
      for (final i in ifaces) {
        if (!isUsableCastInterface(i.name) || !_isWifiInterface(i.name))
          continue;
        for (final a in i.addresses) {
          if (isPrivateLanIp(a.address)) return a.address;
        }
      }
      // Pass 2: any usable (non-VPN/virtual) interface with a private LAN IP.
      for (final i in ifaces) {
        if (!isUsableCastInterface(i.name)) continue;
        for (final a in i.addresses) {
          if (isPrivateLanIp(a.address)) return a.address;
        }
      }
      // Pass 3: last resort — first non-loopback IPv4.
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _isWifiInterface(String name) {
    final n = name.toLowerCase();
    return n.startsWith('wlan') || n.startsWith('ap') || n.startsWith('en');
  }

  String _randomToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}

/// Whether [ip] is an RFC-1918 private LAN address (the range a Chromecast on
/// the same Wi-Fi shares). Top-level + pure so it's unit-testable.
bool isPrivateLanIp(String ip) {
  if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
  if (ip.startsWith('172.')) {
    final second = int.tryParse(ip.split('.')[1]) ?? 0;
    return second >= 16 && second <= 31;
  }
  return false;
}

/// Whether a network interface should be used to advertise the cast proxy.
/// Excludes VPN / virtual / cellular interfaces (tun/ppp/rmnet/wireguard/…)
/// whose address a Chromecast on the LAN can't reach. Pure/unit-testable.
bool isUsableCastInterface(String name) {
  final n = name.toLowerCase();
  const bad = [
    'tun',
    'tap',
    'ppp',
    'rmnet',
    'wg',
    'utun',
    'ipsec',
    'vpn',
    'pdp',
  ];
  return !bad.any(n.startsWith);
}
