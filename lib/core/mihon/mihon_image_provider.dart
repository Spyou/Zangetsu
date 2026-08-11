// Native-backed image provider for Mihon (manga) source covers and pages.
//
// The manga twin of [AniyomiImage] (`lib/core/aniyomi/aniyomi_image_provider.dart`)
// — deliberately duplicated, not shared, so the frozen Aniyomi path never has to
// change for a manga change.
//
// Manga cover/page images frequently sit behind Cloudflare on a separate image
// host (e.g. `static.comix.to`). Flutter's `cached_network_image` can't pass CF
// because it has no access to the `cf_clearance` cookie. This provider fetches
// image bytes through the SOURCE'S OWN OkHttpClient (which carries the CF session
// cookie the browse path uses) via the `zangetsu/mihon` channel's `getImage`
// call, then decodes the bytes in Flutter.
//
// Keyed by `(sourceId, url)` so Flutter's ImageCache deduplicates identical
// requests. Constructed only where the `x-mihon-src` marker is present in a
// cover's headers — non-Mihon paths are untouched.
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

const MethodChannel _kMihonChannel = MethodChannel('zangetsu/mihon');

/// [ImageProvider] that fetches image bytes via the native Mihon OkHttpClient.
///
/// Keyed by [sourceId] (the numeric Mihon source id) and [url] (the cover/page
/// image URL). Flutter's image cache deduplicates on the pair.
class MihonImage extends ImageProvider<MihonImage> {
  const MihonImage(this.sourceId, this.url);

  /// The numeric Mihon source id as registered in `MihonSourceManager`.
  final int sourceId;

  /// Absolute URL of the cover / page image.
  final String url;

  @override
  Future<MihonImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MihonImage>(this);

  @override
  ImageStreamCompleter loadImage(MihonImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadAsync(key, decode));
  }

  Future<ImageInfo> _loadAsync(
    MihonImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List? bytes = await _kMihonChannel.invokeMethod<Uint8List>(
      'getImage',
      {'sourceId': key.sourceId, 'url': key.url},
    );
    if (bytes == null || bytes.isEmpty) {
      throw Exception(
        'MihonImage: native getImage returned empty bytes for ${key.url}',
      );
    }
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.Codec codec = await decode(buffer);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is MihonImage && sourceId == other.sourceId && url == other.url;

  @override
  int get hashCode => Object.hash(sourceId, url);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'MihonImage')}(sourceId: $sourceId, url: $url)';
}

/// Returns the right [ImageProvider] for a Mihon source cover: a native,
/// CF-aware [MihonImage] when [headers] carries the `x-mihon-src` marker,
/// otherwise the normal [CachedNetworkImageProvider].
ImageProvider mihonCoverProvider(String url, Map<String, String>? headers) {
  final marker = headers?['x-mihon-src'];
  if (marker != null) {
    final id = int.tryParse(marker);
    if (id != null) return MihonImage(id, url);
  }
  return CachedNetworkImageProvider(url, headers: headers);
}
