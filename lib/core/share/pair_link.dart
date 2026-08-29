import '../environment.dart';

/// Encodes TV pairing links and parses incoming pair URLs from either the
/// website (`https://zangetsu.online/pair/…`) or the `zangetsu://pair` deeplink.
class PairLink {
  const PairLink({this.code, this.nonce, this.trackers = false, this.discord = false});

  final String? code;
  final String? nonce;

  /// When true this is the trackers-only QR (Flow B), not account sign-in.
  final bool trackers;

  /// When true this is a Discord token relay to a TV, not account sign-in.
  final bool discord;

  /// HTTPS pair URL for web/share links (browser → optional app handoff).
  static String qrData({
    required String code,
    String? nonce,
    bool trackers = false,
    bool discord = false,
  }) {
    return Uri.parse(Environment.sitePairUrl).replace(
      queryParameters: _query(
        code: code,
        nonce: nonce,
        trackers: trackers,
        discord: discord,
      ),
    ).toString();
  }

  /// Custom-scheme deeplink for TV "have the app" QRs and Android intent-filters.
  /// Handled by [OpenLinkService].
  static String deepLink({
    required String code,
    String? nonce,
    bool trackers = false,
    bool discord = false,
  }) {
    return Uri(
      scheme: Environment.trackerRedirectScheme,
      host: Environment.pairLinkHost,
      queryParameters: _query(
        code: code,
        nonce: nonce,
        trackers: trackers,
        discord: discord,
      ),
    ).toString();
  }

  static Map<String, String> _query({
    required String code,
    String? nonce,
    bool trackers = false,
    bool discord = false,
  }) =>
      {
        'code': code,
        if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
        if (trackers) 'trackers': '1',
        if (discord) 'discord': '1',
      };

  /// Accepts `zangetsu://pair?…` and the configured [Environment.sitePairUrl].
  static PairLink? parse(Uri uri) {
    if (!_isPairUri(uri)) return null;
    final q = uri.queryParameters;
    return PairLink(
      code: q['code'],
      nonce: q['nonce'],
      trackers: q['trackers'] == '1',
      discord: q['discord'] == '1',
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
