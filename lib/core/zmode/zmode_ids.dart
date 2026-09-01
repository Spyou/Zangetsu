/// What a metadata title is, which decides both the catalogue that serves it
/// (AniList vs TMDB) and which sources may play it.
enum ZKind { anime, movie, tv, manga, novel }

/// The identity of a metadata title, independent of any source.
/// [id] is `mal:<n>` or `al:<n>` for AniList titles, `tmdb:<n>` for TMDB.
class ZCanonical {
  const ZCanonical(this.kind, this.id);
  final ZKind kind;
  final String id;

  /// Storage key for the match store.
  String get key => '${kind.name}:$id';

  @override
  bool operator ==(Object o) =>
      o is ZCanonical && o.kind == kind && o.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
  @override
  String toString() => key;
}

/// Metadata titles carry `zm://` urls so the router can tell them from source
/// urls without a lookup: `zm://<kind>/<id>` and `zm://<kind>/<id>/ep/<n>`.
class ZmodeIds {
  const ZmodeIds._();

  /// The pseudo source id every metadata [MediaItem] carries.
  static const String sourceId = 'zm';
  static const String _scheme = 'zm://';

  static bool isZ(String url) => url.startsWith(_scheme);

  static String showUrl(ZCanonical c) => '$_scheme${c.kind.name}/${c.id}';

  static String episodeUrl(ZCanonical c, int n) => '${showUrl(c)}/ep/$n';

  static ZCanonical? parseShow(String url) {
    if (!isZ(url)) return null;
    final parts = url.substring(_scheme.length).split('/');
    if (parts.length < 2) return null;
    final kind = ZKind.values.where((k) => k.name == parts[0]).firstOrNull;
    if (kind == null || parts[1].isEmpty) return null;
    return ZCanonical(kind, parts[1]);
  }

  static ({ZCanonical show, int episode})? parseEpisode(String url) {
    final show = parseShow(url);
    if (show == null) return null;
    final parts = url.substring(_scheme.length).split('/');
    if (parts.length != 4 || parts[2] != 'ep') return null;
    final n = int.tryParse(parts[3]);
    if (n == null) return null;
    return (show: show, episode: n);
  }
}
