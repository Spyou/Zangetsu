import '../environment.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';

/// Encodes a [MediaItem] into a short shareable web link and decodes an incoming
/// `zangetsu://open?…` deep link back into a [MediaItem].
///
/// The shared link is an HTTPS URL to the site's `/open/` page:
///   `https://…/Zangetsu-Site/open/?s=<source>&u=<url>&t=<title>&y=<a|m>`
/// Only the fields needed to re-open the title are carried — the Detail
/// re-fetches everything else — which keeps the link short. When installed, the
/// app catches it via `zangetsu://open?…`; otherwise the page offers the app.
class ShareLink {
  const ShareLink._();

  /// The short web link to share for [item].
  static String forItem(MediaItem item) {
    return Uri.parse(Environment.siteOpenUrl).replace(queryParameters: {
      's': item.sourceId,
      'u': item.url,
      't': item.title,
      'y': item.type == ProviderType.movie ? 'm' : 'a',
    }).toString();
  }

  /// Human-facing share text: the title + the link.
  static String shareText(MediaItem item) =>
      '${item.title}\n\nWatch on Zangetsu:\n${forItem(item)}';

  /// Parse a `zangetsu://open?s=…&u=…` deep link into a [MediaItem], or null
  /// when [uri] is not an open-link or is missing the source/url.
  static MediaItem? parse(Uri uri) {
    if (uri.scheme != Environment.openLinkScheme ||
        uri.host != Environment.openLinkHost) {
      return null;
    }
    final q = uri.queryParameters;
    final s = q['s'], u = q['u'];
    if (s == null || s.isEmpty || u == null || u.isEmpty) return null;
    return MediaItem(
      id: u, // stable key; the source addresses the title by url anyway
      title: q['t'] ?? '',
      url: u,
      type: q['y'] == 'm' ? ProviderType.movie : ProviderType.anime,
      sourceId: s,
    );
  }
}
