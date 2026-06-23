/// TMDB API config. One embedded v3 key, used by every user — TMDB rate-limits
/// per-IP, not per-key, so a single key scales cleanly across all installs (the
/// same pattern CloudStream/Dantotsu use). Powers movie/TV search autocomplete,
/// trailers, and cast/relations. Replaces the old keyless proxy, which died.
///
/// The key is attached to every request to [host] by a Dio interceptor wired in
/// initDependencies — individual TMDB calls don't need to pass `api_key`.
class Tmdb {
  Tmdb._();

  static const String host = 'api.themoviedb.org';
  static const String base = 'https://$host/3';
  static const String apiKey = 'fab792d6c5936a7332045ca4565c7353';

  /// TMDB image CDN (no key needed).
  static const String img = 'https://image.tmdb.org/t/p';
}
