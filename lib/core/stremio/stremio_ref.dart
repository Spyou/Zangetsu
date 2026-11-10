import 'package:equatable/equatable.dart';

const String stremioSourceId = 'stremio';
const int _refVersion = 1;

/// A Stremio title reference that can live in a URL, My List row or history
/// entry. It carries no credentials: the configured addon URL stays in secure
/// storage.
class StremioRef extends Equatable {
  const StremioRef({
    required this.installationId,
    required this.type,
    required this.itemId,
    this.videoId,
  });

  final String installationId;
  final String type;
  final String itemId;
  final String? videoId;

  /// The id sent to the addon's stream endpoint: the selected video when one
  /// is chosen, otherwise the metadata id.
  String get requestId => videoId ?? itemId;

  StremioRef withVideo(String? video) => StremioRef(
    installationId: installationId,
    type: type,
    itemId: itemId,
    videoId: video,
  );

  String encode() {
    final query = {
      'v': '$_refVersion',
      'i': installationId,
      't': type,
      'm': itemId,
      if (videoId != null && videoId!.isNotEmpty) 'e': videoId!,
    };
    return 'stremio://ref?${Uri(queryParameters: query).query}';
  }

  static StremioRef parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'stremio' || uri.host != 'ref') {
      throw const FormatException('not a Stremio reference');
    }
    final params = uri.queryParameters;
    if (params['v'] != '$_refVersion') {
      throw const FormatException('unsupported Stremio reference version');
    }
    final installationId = params['i'];
    final type = params['t'];
    final itemId = params['m'];
    if (installationId == null ||
        installationId.isEmpty ||
        type == null ||
        type.isEmpty ||
        itemId == null ||
        itemId.isEmpty) {
      throw const FormatException('incomplete Stremio reference');
    }
    final video = params['e'];
    return StremioRef(
      installationId: installationId,
      type: type,
      itemId: itemId,
      videoId: (video == null || video.isEmpty) ? null : video,
    );
  }

  static bool isRef(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'stremio' && uri.host == 'ref';
  }

  @override
  List<Object?> get props => [installationId, type, itemId, videoId];
}

/// An id family the addon protocol can carry across addons (`tt123`, `tmdb:1`,
/// `kitsu:2`, `mal:3`). Everything else is addon-local.
bool isVerifiedStremioId(String id) =>
    RegExp(r'^tt\d+$').hasMatch(id) ||
    RegExp(r'^(tmdb|kitsu|mal):\d+$').hasMatch(id);

/// Saved identity: type + verified id so the same title from two addons is one
/// list row, while a movie and a series can never collide.
String stremioMediaId({
  required String type,
  required String itemId,
  required String installationId,
}) {
  final base = isVerifiedStremioId(itemId) ? itemId : '$installationId:$itemId';
  return '$type:$base';
}

/// Saved episode identity. Verified titles merge across addons; custom ids stay
/// scoped to their installation.
String stremioEpisodeId({
  required String itemId,
  required String videoId,
  required String installationId,
}) {
  return isVerifiedStremioId(itemId) ? videoId : '$installationId:$videoId';
}

bool isStremioMovieType(String type) {
  final lower = type.toLowerCase();
  return lower.startsWith('movie') || lower.startsWith('film');
}
