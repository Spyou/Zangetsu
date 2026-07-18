import 'package:appwrite/appwrite.dart';

import '../environment.dart';

/// Retained for ONE release: mints a short-lived Appwrite JWT so the
/// migrate-account edge function can verify an already-signed-in user
/// (Case 2). Removed once account migration dries up.
class AppwriteService {
  AppwriteService() {
    final client = Client()
        .setEndpoint(Environment.appwritePublicEndpoint)
        .setProject(Environment.appwriteProjectId);
    _account = Account(client);
  }
  late final Account _account;

  /// Null when there is no restorable Appwrite session.
  Future<String?> mintJwt() async {
    try {
      final jwt = await _account.createJWT();
      return jwt.jwt;
    } catch (_) {
      return null;
    }
  }
}
