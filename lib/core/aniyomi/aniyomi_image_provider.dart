/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Native-backed image provider for Aniyomi source thumbnails.
//
// Aniyomi thumbnails often sit behind Cloudflare (e.g. `i.animepahe.pw`).
// Flutter's `cached_network_image` cannot pass CF because it has no access to
// the `cf_clearance` cookie. This provider fetches image bytes through the
// SOURCE'S OWN OkHttpClient (which already carries the CF session used for
// browsing/playback) via the `zangetsu/aniyomi` method channel's `getImage`
// call, then decodes the bytes in Flutter.
//
// The provider is keyed by `(sourceId, url)` so Flutter's ImageCache
// deduplicates identical requests. It is only ever constructed from the
// x-ani-src guard in poster_card / detail_screen — non-Aniyomi paths are
// untouched.
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

const MethodChannel _kAniChannel = MethodChannel('zangetsu/aniyomi');

/// [ImageProvider] that fetches image bytes via the native Aniyomi OkHttpClient.
///
/// Keyed by [sourceId] (the numeric Aniyomi source id) and [url] (the cover
/// image URL). Flutter's image cache deduplicates on the pair.
class AniyomiImage extends ImageProvider<AniyomiImage> {
  const AniyomiImage(this.sourceId, this.url);

  /// The numeric Aniyomi source id as registered in [AniyomiSourceManager].
  final int sourceId;

  /// Absolute URL of the thumbnail / cover image.
  final String url;

  // ── ImageProvider ────────────────────────────────────────────────────────────

  @override
  Future<AniyomiImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AniyomiImage>(this);

  /// Flutter 3.7+ modern decode path: [ImageDecoderCallback] receives an
  /// [ui.ImmutableBuffer] built from the raw bytes returned by the native side.
  @override
  ImageStreamCompleter loadImage(AniyomiImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadAsync(key, decode));
  }

  Future<ImageInfo> _loadAsync(
    AniyomiImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List? bytes = await _kAniChannel.invokeMethod<Uint8List>(
      'getImage',
      {'sourceId': key.sourceId, 'url': key.url},
    );
    if (bytes == null || bytes.isEmpty) {
      throw Exception(
        'AniyomiImage: native getImage returned empty bytes for ${key.url}',
      );
    }
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.Codec codec = await decode(buffer);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  // ── equality / hash ──────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is AniyomiImage &&
      sourceId == other.sourceId &&
      url == other.url;

  @override
  int get hashCode => Object.hash(sourceId, url);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AniyomiImage')}(sourceId: $sourceId, url: $url)';
}

/// Returns the right [ImageProvider] for a source cover: a native, CF-aware
/// [AniyomiImage] when [headers] carries the `x-ani-src` marker (a Cloudflare-
/// walled Aniyomi thumbnail), otherwise the normal [CachedNetworkImageProvider].
///
/// Use this at provider-form call sites (hero palette / decoration images) so
/// they get the CF-aware loader for Aniyomi covers without changing behaviour
/// for every other source.
ImageProvider aniyomiCoverProvider(String url, Map<String, String>? headers) {
  final marker = headers?['x-ani-src'];
  if (marker != null) {
    final id = int.tryParse(marker);
    if (id != null) return AniyomiImage(id, url);
  }
  return CachedNetworkImageProvider(url, headers: headers);
}
