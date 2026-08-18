import '../environment.dart';

/// Encodes the TV pairing QR as an HTTPS URL (iPhone Camera rejects custom
/// schemes with "No usable data found") and parses incoming pair links from
/// either the website or the `zangetsu://pair` redirect it fires.
class PairLink {
  const PairLink({this.code, this.nonce, this.trackers = false});

  final String? code;
  final String? nonce;

  /// When true this is the trackers-only QR (Flow B), not account sign-in.
  final bool trackers;

  /// Payload printed in the TV QR. An http(s) URL so iPhone Camera treats it
  /// as a link instead of "No usable data found".
  static String qrData({
    required String code,
    String? nonce,
    bool trackers = false,
  }) {
    return Uri.parse(Environment.sitePairUrl).replace(
      queryParameters: _query(code: code, nonce: nonce, trackers: trackers),
    ).toString();
  }

  /// Custom-scheme link the `/pair/` landing page (and Android intent-filters)
  /// hand off to [OpenLinkService].
  static String deepLink({
    required String code,
    String? nonce,
    bool trackers = false,
  }) {
    return Uri(
      scheme: Environment.trackerRedirectScheme,
      host: Environment.pairLinkHost,
      queryParameters: _query(code: code, nonce: nonce, trackers: trackers),
    ).toString();
  }

  static Map<String, String> _query({
    required String code,
    String? nonce,
    bool trackers = false,
  }) =>
      {
        'code': code,
        if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
        if (trackers) 'trackers': '1',
      };

  /// Accepts `zangetsu://pair?…` and the configured [Environment.sitePairUrl].
  static PairLink? parse(Uri uri) {
    if (!_isPairUri(uri)) return null;
    final q = uri.queryParameters;
    return PairLink(
      code: q['code'],
      nonce: q['nonce'],
      trackers: q['trackers'] == '1',
    );
  }

  static bool _isPairUri(Uri uri) {
    if (uri.scheme == Environment.trackerRedirectScheme &&
        uri.host == Environment.pairLinkHost) {
      return true;
    }
    final site = Uri.parse(Environment.sitePairUrl);
    if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host == site.host) {
      final path = uri.path.replaceAll(RegExp(r'/+$'), '');
      final sitePath = site.path.replaceAll(RegExp(r'/+$'), '');
      return path == sitePath;
    }
    return false;
  }
}
