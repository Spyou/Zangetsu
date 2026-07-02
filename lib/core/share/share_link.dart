import 'dart:convert';

import '../environment.dart';
import '../models/media_item.dart';

/// Encodes a [MediaItem] into a shareable web link and decodes an incoming
/// `zangetsu://open?…` deep link back into a [MediaItem].
///
/// The shared link is an HTTPS URL to the site's `/open/` page:
///   `https://…/Zangetsu-Site/open/?d=<base64(item json)>&t=<title>`
/// That page opens the app (via `zangetsu://open?d=…&t=…`) when installed, or
/// offers the download otherwise. The app parses the `zangetsu://open` link
/// here and opens the title's Detail on its source.
class ShareLink {
  const ShareLink._();

  /// The web link to share for [item]. `t` (plain title) is only for the
  /// site's human-readable copy; `d` carries the full item for the app.
  static String forItem(MediaItem item) {
    // Drop coverHeaders — the Detail re-fetches the cover with proper headers,
    // and they can be large, keeping the link short.
    final json = Map<String, dynamic>.from(item.toJson())..remove('coverHeaders');
    final d = base64Url.encode(utf8.encode(jsonEncode(json)));
    return Uri.parse(Environment.siteOpenUrl)
        .replace(queryParameters: {'d': d, 't': item.title})
        .toString();
  }

  /// Human-facing share text: the title + the link.
  static String shareText(MediaItem item) =>
      '${item.title}\n\nWatch on Zangetsu:\n${forItem(item)}';

  /// Parse a `zangetsu://open?d=…` deep link into a [MediaItem], or null when
  /// [uri] is not an open-link or the payload is malformed.
  static MediaItem? parse(Uri uri) {
    if (uri.scheme != Environment.openLinkScheme ||
        uri.host != Environment.openLinkHost) {
      return null;
    }
    final d = uri.queryParameters['d'];
    if (d == null || d.isEmpty) return null;
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(d))))
          as Map<String, dynamic>;
      return MediaItem.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
