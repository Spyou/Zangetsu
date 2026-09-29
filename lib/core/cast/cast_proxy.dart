import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
String _rewriteUriAttr(
  String line,
  Uri base,
  String Function(Uri) proxify,
) {
  return line.replaceAllMapped(
    _uriAttr,
    (m) => 'URI="${proxify(base.resolve(m.group(1)!))}"',
  );
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
  String? _basePrefix; // http://ip:port/p/<token>?u=
  Map<String, String> _headers = const {};

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  bool get isRunning => _server != null;

  /// Start (if needed) and configure the proxy for [headers], then return the
  /// proxy URL the Chromecast should load for [upstreamUrl]. Returns null when
  /// no usable LAN address is available (caller should fall back to the direct
  /// URL — casting will then only work for un-protected streams).
  Future<String?> serve(String upstreamUrl, Map<String, String>? headers) async {
    _headers = headers ?? const {};
    await _ensureStarted();
    final server = _server;
    if (server == null) return null;
    final ip = await _lanIp();
    if (ip == null) return null;
    _basePrefix = 'http://$ip:${server.port}/p/$_token?u=';
    return proxify(upstreamUrl);
  }

  /// Wrap any upstream URL (e.g. a subtitle track) in the running proxy so it
  /// too is fetched with the session headers. Null if the proxy isn't running.
  String? proxify(String upstreamUrl) {
    final prefix = _basePrefix;
    if (prefix == null) return null;
    return '$prefix${base64Url.encode(utf8.encode(upstreamUrl))}';
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
    try {
      // Token gate — never act as an open proxy for other LAN devices.
      final segs = req.uri.pathSegments;
      if (segs.length < 2 || segs[0] != 'p' || segs[1] != _token) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      final u = req.uri.queryParameters['u'];
      if (u == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      final target = Uri.parse(utf8.decode(base64Url.decode(u)));

      final upReq = await _client.getUrl(target);
      _headers.forEach(upReq.headers.set);
      // Forward Range so the Chromecast can seek / byte-range segments + mp4.
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) upReq.headers.set(HttpHeaders.rangeHeader, range);
      final upRes = await upReq.close();

      final ctype = upRes.headers.contentType?.mimeType.toLowerCase() ?? '';
      final isHls =
          target.path.toLowerCase().endsWith('.m3u8') ||
          ctype.contains('mpegurl');

      res.headers.set('Access-Control-Allow-Origin', '*');

      if (isHls) {
        final body = await upRes.transform(utf8.decoder).join();
        final rewritten = rewriteHlsPlaylist(
          body,
          target,
          // Relative form: the Chromecast resolves it against the playlist's
          // own proxied URL, so no host needed here.
          (abs) => '/p/$_token?u=${base64Url.encode(utf8.encode(abs.toString()))}',
        );
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        res.write(rewritten);
        await res.close();
      } else {
        res.statusCode = upRes.statusCode; // 200 or 206 (partial content)
        final ct = upRes.headers.contentType;
        if (ct != null) res.headers.contentType = ct;
        final cr = upRes.headers.value(HttpHeaders.contentRangeHeader);
        if (cr != null) res.headers.set(HttpHeaders.contentRangeHeader, cr);
        if (upRes.headers.contentLength > 0) {
          res.headers.contentLength = upRes.headers.contentLength;
        }
        res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        await res.addStream(upRes);
        await res.close();
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
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
        if (!isUsableCastInterface(i.name) || !_isWifiInterface(i.name)) continue;
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
  const bad = ['tun', 'tap', 'ppp', 'rmnet', 'wg', 'utun', 'ipsec', 'vpn', 'pdp'];
  return !bad.any(n.startsWith);
}
