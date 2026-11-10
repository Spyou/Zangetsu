/// Whether a source url is a torrent (magnet link or .torrent file) rather
/// than a directly-playable http(s) url.
bool isTorrentUrl(String url) {
  final u = url.trim().toLowerCase();
  return u.startsWith('magnet:') || u.endsWith('.torrent');
}
