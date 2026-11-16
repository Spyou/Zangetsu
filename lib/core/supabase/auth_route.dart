import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../environment.dart';

class AuthRoute {
  // Selected once during startup and shared by pairing links.
  static AuthRoute active = cloud;

  const AuthRoute({
    required this.authority,
    required this.generation,
    required this.anonKey,
  });

  final String authority;
  final int generation;
  final String anonKey;

  String get url => authority == 'vps'
      ? 'https://sb.zangetsu.online'
      : Environment.supabaseUrl;

  static const cloud = AuthRoute(
    authority: 'cloud',
    generation: 0,
    anonKey: Environment.supabaseAnonKey,
  );

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'generation': generation,
    'authority': authority,
    'anonKey': anonKey,
  };

  static AuthRoute parse(String value) {
    if (value.length > 16384) {
      throw const FormatException('Connection settings too large');
    }
    final data = jsonDecode(value);
    if (data is! Map<String, dynamic> ||
        data.keys.toSet().difference({
          'schema',
          'generation',
          'authority',
          'anonKey',
        }).isNotEmpty ||
        data['schema'] is! int ||
        data['schema'] != 1 ||
        data['generation'] is! int ||
        (data['generation'] as int) < 1 ||
        (data['generation'] as int) > 0x1fffffffffffff ||
        !['cloud', 'vps'].contains(data['authority']) ||
        data['anonKey'] is! String ||
        !_publicKey(data['anonKey'] as String)) {
      throw const FormatException('Invalid connection settings');
    }
    return AuthRoute(
      authority: data['authority'] as String,
      generation: data['generation'] as int,
      anonKey: data['anonKey'] as String,
    );
  }

  static bool _publicKey(String key) {
    if (key.length > 8192 || key.contains(RegExp(r'\s'))) return false;
    if (key.startsWith('sb_publishable_') && key.length > 20) return true;
    try {
      final parts = key.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }
}

class AuthRouteDecision {
  const AuthRouteDecision(this.route, {required this.changed});
  final AuthRoute route;
  final bool changed;
}

/// Resolves once per launch. A migrated device never falls back to Cloud.
class AuthRouteResolver {
  AuthRouteResolver({
    required this.preferences,
    required this.client,
    this.timeout = const Duration(milliseconds: 1200),
  });

  static const cacheKey = 'auth_route_v1';
  static final manifestUrl = Uri.parse(
    '${Environment.vpsSyncUrl}/auth-routing/v1.json',
  );
  final SharedPreferences preferences;
  final http.Client client;
  final Duration timeout;

  Future<AuthRouteDecision> resolve() async {
    AuthRoute? cached;
    final raw = preferences.getString(cacheKey);
    if (raw != null) {
      try {
        cached = AuthRoute.parse(raw);
      } on FormatException {
        /* Recover from the trusted manifest below. */
      }
    }
    AuthRoute? remote;
    try {
      remote = await _fetch().timeout(timeout);
    } catch (_) {
      /* Keep the last validated authority during outages. */
    }
    if (cached == null && raw != null && remote?.authority != 'vps') {
      throw const FormatException(
        'Connection settings unavailable. Connect to the internet and retry.',
      );
    }
    final previous = cached ?? AuthRoute.cloud;
    if (remote == null ||
        remote.generation <= previous.generation ||
        (previous.authority == 'vps' && remote.authority != 'vps')) {
      return AuthRouteDecision(previous, changed: false);
    }
    // Persist the URL/key pair together before using it, so a restart cannot split them.
    if (!await preferences.setString(cacheKey, jsonEncode(remote.toJson()))) {
      throw StateError('Could not save connection settings');
    }
    return AuthRouteDecision(
      remote,
      changed: previous.authority != remote.authority,
    );
  }

  Future<AuthRoute?> _fetch() async {
    final response = await client.send(
      http.Request('GET', manifestUrl)..followRedirects = false,
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 16384) {
        throw const FormatException('Connection settings too large');
      }
      bytes.addAll(chunk);
    }
    return AuthRoute.parse(utf8.decode(bytes));
  }
}
