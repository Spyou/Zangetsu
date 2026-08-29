import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';

import '../aniyomi/aniyomi_image_provider.dart';
import '../cache/app_image_cache.dart';
import '../mihon/mihon_image_provider.dart';

/// Central cover-image provider dispatcher for the shared card/hero widgets.
///
/// Routes Cloudflare-walled **Aniyomi** (`x-ani-src`) and **Mihon**
/// (`x-mihon-src`) covers through their native, `cf_clearance`-carrying image
/// path ([AniyomiImage] / [MihonImage]); every other source falls back to the
/// normal [CachedNetworkImageProvider]. The markers are internal header keys and
/// are never sent over the network.
ImageProvider nativeCoverProvider(String url, Map<String, String>? headers) {
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
  return AppImageCache.imageProvider(url, headers: headers);
}
