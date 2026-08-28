import 'debrid_prefs.dart';
import 'debrid_provider.dart';
import 'debrid_result.dart';
import 'debrid_token_store.dart';
import 'real_debrid_client.dart';
import 'torbox_client.dart';

/// Facade: read prefs + tokens, call the active client, return an HTTP URL.
class DebridResolver {
  DebridResolver({
    required this.prefs,
    Future<String?> Function(DebridService)? readToken,
    DebridClient? realDebrid,
    DebridClient? torbox,
    this.preferTimeout = const Duration(seconds: 40),
    this.alwaysTimeout = const Duration(seconds: 120),
  })  : _readToken = readToken ?? DebridTokenStore.read,
        _clients = {
          DebridService.realDebrid: realDebrid ?? RealDebridClient(),
          DebridService.torbox: torbox ?? TorBoxClient(),
        };

  final DebridPrefs prefs;
  final Future<String?> Function(DebridService) _readToken;
  final Map<DebridService, DebridClient> _clients;
  final Duration preferTimeout;
  final Duration alwaysTimeout;

  DebridClient clientFor(DebridService s) => _clients[s]!;

  Future<bool> validate(DebridService s, String token) =>
      _clients[s]!.validateToken(token);

  /// Which service would actually be used right now (stored pick if it still
  /// has a token, otherwise the first connected).
  Future<DebridService?> activeConnectedService() async {
    final stored = prefs.activeService;
    if (stored != null) {
      final t = await _readToken(stored);
      if (t != null && t.trim().isNotEmpty) return stored;
    }
    for (final s in DebridService.values) {
      final t = await _readToken(s);
      if (t != null && t.trim().isNotEmpty) return s;
    }
    return null;
  }

  /// Off / missing token in Prefer → [DebridSkipped]. Always without a token
  /// → [DebridFailed] auth. Otherwise calls the active client.
  Future<DebridAttempt> resolve(
    String uri, {
    void Function(String phase)? onPhase,
  }) async {
    final mode = prefs.mode;
    if (mode == DebridMode.off) return const DebridSkipped();

    final service = await activeConnectedService();
    if (service == null) {
      if (mode == DebridMode.always) {
        return const DebridFailed(
          DebridException(
            DebridFailure.auth,
            'Connect Real-Debrid or TorBox in Settings › Debrid first.',
          ),
        );
      }
      return const DebridSkipped();
    }

    final token = (await _readToken(service))?.trim();
    if (token == null || token.isEmpty) {
      if (mode == DebridMode.always) {
        return DebridFailed(
          DebridException(
            DebridFailure.auth,
            'Connect ${service.displayName} in Settings › Debrid first.',
            serviceName: service.displayName,
          ),
        );
      }
      return const DebridSkipped();
    }

    final timeout =
        mode == DebridMode.always ? alwaysTimeout : preferTimeout;
    try {
      final resolved = await _clients[service]!.resolve(
        uri,
        token: token,
        timeout: timeout,
        requireCached: mode == DebridMode.prefer,
        onPhase: onPhase,
      );
      if (resolved.url.isEmpty) {
        return DebridFailed(
          DebridException(
            DebridFailure.error,
            '${service.displayName} returned an empty URL.',
            serviceName: service.displayName,
          ),
        );
      }
      return DebridOk(resolved);
    } on DebridException catch (e) {
      return DebridFailed(e);
    } catch (e) {
      return DebridFailed(
        DebridException(
          DebridFailure.error,
          '${service.displayName} failed: $e',
          serviceName: service.displayName,
        ),
      );
    }
  }
}
