import 'tmdb.dart';

/// The big services, in the order most people would expect to see them.
///
/// TMDB's own `display_priority` is per-region and mixes the majors in with
/// long-tail catalogues — in India it puts FilmBox+, Cultpix and DOCSVILLE
/// ahead of Crunchyroll — so the rail, which only shows the first handful,
/// would bury the ones people actually have. These ids are pinned to the
/// front in this order; everything else keeps TMDB's order behind them.
///
/// Every id below was read from the live API across IN/US/GB, not guessed.
/// Amazon and Apple appear twice on purpose: TMDB uses a different id for the
/// same service in different regions.
const List<int> kPopularProviderIds = [
  8, // Netflix
  9, // Amazon Prime Video (US, GB)
  119, // Amazon Prime Video (IN)
  337, // Disney Plus
  350, // Apple TV
  283, // Crunchyroll
  1899, // HBO Max
  15, // Hulu
  531, // Paramount Plus
  386, // Peacock Premium
  2336, // JioHotstar
  232, // Zee5
];

/// Rent-and-buy stores and profile variants. Not services you subscribe to,
/// and [2] in particular ships almost the same icon as Apple TV (350), so the
/// rail showed what looked like Apple twice.
const Set<int> _notASubscription = {
  2, // Apple TV Store — rent/buy
  3, // Google Play Movies — rent/buy
  10, // Amazon Video — rent/buy
  68, // Microsoft Store — rent/buy
  192, // YouTube — free/rent, not a subscription catalogue
  175, // Netflix Kids — a profile, not a service
  2285, // JustWatch TV — the comparison site's own channel
};

/// Whether this entry is a streaming service someone can subscribe to.
///
/// TMDB's list is mostly resellers: of 92 entries in India, 38 are
/// `<name> Amazon Channel`, `<name> Apple TV channel`, a rent/buy store, or
/// an ad-supported duplicate of a service already in the list. In the US it is
/// 163 of 333. They clutter the rail and, worse, duplicate the brands next to
/// them with near-identical logos.
///
/// A service sold ONLY as an Amazon channel drops out with them. That is the
/// accepted cost: the alternative is a rail where Apple appears twice.
bool isSubscribableService(int id, String name) {
  if (_notASubscription.contains(id)) return false;
  final n = name.toLowerCase().trim();
  return !n.endsWith('channel') &&
      !n.endsWith('store') &&
      !n.endsWith('kids') &&
      !n.contains('with ads');
}

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
