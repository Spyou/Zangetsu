/// Shared AniList GraphQL transport details.
///
/// AniList 403s the app-wide Dio User-Agent (`WATCH_APP`) and anonymous calls
/// that lack browser-like Origin/Referer — while [GraphiQL] still works in a
/// browser. Every client hitting `graphql.anilist.co` must send these headers.
///
/// [GraphiQL]: https://anilist.co/graphiql
class AniListGraphql {
  AniListGraphql._();

  static const String host = 'graphql.anilist.co';
  static const String endpoint = 'https://$host';

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Request headers for POST bodies `{query, variables}`.
  static const Map<String, String> headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': userAgent,
    'Origin': 'https://anilist.co',
    'Referer': 'https://anilist.co/',
  };
}
