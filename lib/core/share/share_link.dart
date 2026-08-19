import '../environment.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';

/// Encodes a [MediaItem] into a short shareable web link and decodes an incoming
/// `zangetsu://open?…` deep link back into a [MediaItem].
///
/// The shared link is an HTTPS URL to the site's `/open/` page:
///   `https://…/Zangetsu-Site/open/?s=<source>&u=<url>&t=<title>&y=<a|m>&c=<cover>`
/// Only the fields needed to re-open the title are carried — the Detail
/// re-fetches everything else — which keeps the link short. When installed, the
/// app catches it via `zangetsu://open?…`; otherwise the page offers the app.
class ShareLink {
  const ShareLink._();

  /// The short web link to share for [item].
  static String forItem(MediaItem item) {
    final cover = item.cover;
    return Uri.parse(Environment.siteOpenUrl).replace(queryParameters: {
      's': item.sourceId,
      'u': item.url,
      't': item.title,
      'y': item.type == ProviderType.movie ? 'm' : 'a',
      // Carried so an opened link has art straight away. Detail otherwise has
      // nothing to draw until the source's own detail call returns, and for a
      // source that omits the cover there it never appears at all.
      // Only the URL: covers needing a Referer are a minority and would bloat
      // every link with headers to rescue them.
      if (cover != null && cover.isNotEmpty) 'c': cover,
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
    final c = q['c'];
    return MediaItem(
      id: u, // stable key; the source addresses the title by url anyway
      title: q['t'] ?? '',
      url: u,
      type: q['y'] == 'm' ? ProviderType.movie : ProviderType.anime,
      sourceId: s,
      // Absent on links shared by older builds, which is why Detail still
      // falls back to whatever the source's detail call returns.
      cover: (c != null && c.isNotEmpty) ? c : null,
    );
  }
}
