import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../metadata/title_logo_service.dart';
import '../models/media_item.dart';

/// Warms only adjacent slides, using the same image providers as the banner.
class BannerImagePreloader {
  BannerImagePreloader({
    Future<void> Function(ImageProvider, BuildContext)? loadImage,
  }) : _loadImage = loadImage ?? _precache;

  final Future<void> Function(ImageProvider, BuildContext) _loadImage;
  List<MediaItem> _items = const [];
  int? _index;
  MediaQueryData? _media;
  int _generation = 0;
  bool _disposed = false;

  static Future<void> _precache(ImageProvider image, BuildContext context) =>
      precacheImage(image, context, onError: (_, _) {});

  void warm(
    BuildContext context,
    List<MediaItem> items,
    int index, {
    required ImageProvider? Function(MediaItem) artwork,
  }) {
    if (_disposed || items.length < 2) return;
    final realIndex = index % items.length;
    final media = MediaQuery.maybeOf(context);
    if (_index == realIndex &&
        listEquals(items, _items) &&
        _media?.size == media?.size &&
        _media?.devicePixelRatio == media?.devicePixelRatio) {
      return;
    }
    _items = List.of(items);
    _index = realIndex;
    _media = media;
    final generation = ++_generation;
    final neighbours = {
      (realIndex + 1) % items.length,
      (realIndex - 1) % items.length,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final i in neighbours) {
        if (!context.mounted || !_current(generation)) return;
        unawaited(_warmItem(context, items[i], artwork, generation));
      }
    });
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _warmItem(
    BuildContext context,
    MediaItem item,
    ImageProvider? Function(MediaItem) artwork,
    int generation,
  ) async {
    try {
      final image = artwork(item);
      if (image != null) await _loadImage(image, context);
    } catch (_) {
      // A failed warm must not prevent normal image loading later.
    }
    if (!context.mounted ||
        !_current(generation) ||
        !sl.isRegistered<TitleLogoService>()) {
      return;
    }
    try {
      final logo = await sl<TitleLogoService>().logoFor(item);
      if (!context.mounted ||
          !_current(generation) ||
          logo == null ||
          logo.isEmpty) {
        return;
      }
      await _loadImage(CachedNetworkImageProvider(logo), context);
    } catch (_) {
      // Text titles remain available when a logo cannot be warmed.
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
  }
}
