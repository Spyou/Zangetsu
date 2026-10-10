import 'package:hive/hive.dart';

import '../app_config.dart';

class ProfilePickerArtwork {
  ProfilePickerArtwork({
    required Box box,
    required Future<Object?> Function() fetchManifest,
  }) : _box = box,
       _fetchManifest = fetchManifest;

  static const lastUrlKey = 'profile_picker_artwork_last_url';
  static const _maxImages = 3;
  static final _fileName = RegExp(
    r'^[a-zA-Z0-9_-]{1,64}\.(?:webp|png|jpe?g)$',
    caseSensitive: false,
  );

  final Box _box;
  final Future<Object?> Function() _fetchManifest;
  List<String>? _manifestImages;
  int _nextIndex = 0;

  String? get cachedUrl {
    final raw = _box.get(lastUrlKey);
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != Uri.parse(kProfilePickerArtworkManifestUrl).host ||
        uri.query.isNotEmpty ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'profile-picker' ||
        !_fileName.hasMatch(uri.pathSegments.last)) {
      return null;
    }
    return uri.toString();
  }

  bool get canRotate => (_manifestImages?.length ?? 0) > 1;

  Future<String?> next() async {
    final images = _manifestImages ??= _images(await _readManifest());
    if (images.isEmpty) return cachedUrl;

    final next = images[_nextIndex];
    if (_nextIndex == 0) await _box.put(lastUrlKey, next);
    _nextIndex = (_nextIndex + 1) % images.length;
    return next;
  }

  Future<Object?> _readManifest() async {
    try {
      return await _fetchManifest();
    } catch (_) {
      return null;
    }
  }

  static List<String> _images(Object? manifest) {
    if (manifest is! Map || manifest['images'] is! List) return const [];

    final base = Uri.parse(kProfilePickerArtworkManifestUrl);
    final images = <String>[];
    for (final item in manifest['images'] as List) {
      if (item is! String || !_fileName.hasMatch(item)) continue;
      images.add(base.resolve(item).toString());
      if (images.length == _maxImages) break;
    }
    return images;
  }
}
