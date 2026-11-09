/// Whether a source url is a torrent (magnet link or .torrent file) rather
/// than a directly-playable http(s) url.
bool isTorrentUrl(String url) {
  final u = url.trim().toLowerCase();
  return u.startsWith('magnet:') || u.endsWith('.torrent');
}

/// 40-char hex or 32-char base32 BitTorrent info hash.
bool isValidTorrentHash(String hash) =>
    RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hash) ||
    RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(hash);

bool _isTrackerUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return false;
  return const {'http', 'https', 'udp', 'ws', 'wss'}.contains(uri.scheme);
}

/// Builds the exact magnet a Stremio torrent link describes. [fileIndex] is
/// forwarded as the conventional `so` parameter and preserved even when zero.
/// Returns null for a malformed hash.
String? buildTorrentMagnet({
  required String infoHash,
  List<String> trackers = const [],
  int? fileIndex,
}) {
  if (!isValidTorrentHash(infoHash)) return null;
  if (fileIndex != null && fileIndex < 0) return null;
  final parts = <String>[
    'xt=urn:btih:${infoHash.toLowerCase()}',
    for (final tracker in trackers)
      if (_isTrackerUrl(tracker)) 'tr=${Uri.encodeQueryComponent(tracker)}',
    if (fileIndex != null) 'so=$fileIndex',
  ];
  return 'magnet:?${parts.join('&')}';
}
