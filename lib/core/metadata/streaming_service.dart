import 'tmdb.dart';

/// One streaming service as TMDB knows it in a given country.
///
/// The logo is TMDB's own `logo_path`, served from its image CDN exactly like
/// a poster. Nothing brand-owned is ever shipped in this repo.
class StreamingService {
  const StreamingService({
    required this.id,
    required this.name,
    required this.logoPath,
    required this.priority,
  });

  /// TMDB `provider_id` — the value `with_watch_providers` takes.
  final int id;
  final String name;
  final String? logoPath;

  /// TMDB `display_priority`: lower sorts first, and it is region-specific, so
  /// the order already reflects what matters in that country.
  final int priority;

  /// Logos are small and often wide; `original` is the only size TMDB
  /// guarantees for every provider.
  String? get logoUrl =>
      logoPath == null ? null : '${Tmdb.img}/original$logoPath';

  /// Null when the row cannot identify a service. A row with no id is unusable
  /// (nothing to query) and a row with no name has nothing to label a home row
  /// with — both are dropped rather than rendered blank.
  static StreamingService? fromJson(Map<String, dynamic> m) {
    final id = m['provider_id'];
    final name = m['provider_name'];
    if (id is! int || name is! String || name.isEmpty) return null;
    final logo = m['logo_path'];
    final p = m['display_priority'];
    return StreamingService(
      id: id,
      name: name,
      logoPath: logo is String && logo.isNotEmpty ? logo : null,
      priority: p is int ? p : 9999,
    );
  }
}

/// A service the user pinned as a Home row.
///
/// The NAME is stored alongside the id on purpose: `TmdbCatalogue.rowTitles()`
/// is synchronous (the Home-rows editor calls it during build) and the name
/// only exists in a fetched list. Storing it keeps the editor working offline
/// and before the provider list has loaded.
class StreamingPin {
  const StreamingPin({required this.id, required this.name});

  final int id;
  final String name;

  /// `'<id>|<name>'`. `|` never appears in a TMDB provider name, and the id is
  /// numeric, so the split is unambiguous.
  String toEntry() => '$id|$name';

  static StreamingPin? fromEntry(String entry) {
    final i = entry.indexOf('|');
    if (i <= 0 || i == entry.length - 1) return null;
    final id = int.tryParse(entry.substring(0, i));
    if (id == null) return null;
    return StreamingPin(id: id, name: entry.substring(i + 1));
  }
}
