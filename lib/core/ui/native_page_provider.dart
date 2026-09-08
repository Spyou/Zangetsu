import 'package:flutter/painting.dart';

import '../aniyomi/aniyomi_image_provider.dart';
import '../mihon/mihon_image_provider.dart';

/// The native image path for a CHAPTER PAGE, or null when the page is an
/// ordinary one that Flutter should fetch itself.
///
/// The cover twin of this is [nativeCoverProvider], and the markers are the
/// same (`x-mihon-src` / `x-ani-src`). Pages are separate because they take the
/// opposite default: a cover is small and always worth the native round trip,
/// while a chapter can be hundreds of pages, so pages stay on Flutter's own
/// disk cache unless the source actually needs otherwise.
///
/// It needs otherwise when the extension REWRITES the image bytes — several
/// sources serve their pages deliberately scrambled and unscramble them in an
/// interceptor on their own OkHttp client. Fetching the url from Dart never
/// runs that interceptor, so the reader drew the scrambled bytes and the page
/// came out looking torn into squares. The bridge marks exactly those pages
/// (see `rewritesImageBytes` in MihonBridge.kt); everything else is untouched
/// and keeps the cached path.
///
/// Returns null for an unmarked page, so the caller keeps its existing
/// behaviour rather than this having to know about it.
ImageProvider? nativePageProvider(String url, Map<String, String>? headers) {
  final ani = headers?['x-ani-src'];
  if (ani != null) {
    final id = int.tryParse(ani);
    if (id != null) return AniyomiImage(id, url);
  }
  final mihon = headers?['x-mihon-src'];
  if (mihon != null) {
    final id = int.tryParse(mihon);
    if (id != null) return MihonImage(id, url);
  }
  return null;
}
