typedef InvokeFn = Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> body);
typedef SignInPasswordFn = Future<bool> Function(String email, String password);
typedef VerifyOtpFn = Future<bool> Function(String email, String token);

/// Client half of the invisible account migration. Pure of Supabase types so
/// it is unit-testable; the injector wires the real invoke/sign-in closures.
class MigrationBridge {
  MigrationBridge({required this.invoke, required this.signInPassword, required this.verifyOtp});
  final InvokeFn invoke;
  final SignInPasswordFn signInPassword;
  final VerifyOtpFn verifyOtp;

  /// Case 1 / heal: verify+migrate against Appwrite, then sign in with the same password.
  Future<bool> tryPasswordMigration(String email, String password) async {
    final res = await invoke('migrate-account', {'email': email, 'password': password});
    if (res['ok'] != true) return false;
    return signInPassword(email, password);
  }

  /// Case 2: already-signed-in Appwrite user; migrate via JWT, then consume the one-time token.
  Future<bool> trySessionMigration(String? appwriteJwt) async {
    if (appwriteJwt == null || appwriteJwt.isEmpty) return false;
    final res = await invoke('migrate-account', {'appwriteJwt': appwriteJwt});
    if (res['ok'] != true) return false;
    final session = res['session'];
    if (session is! Map) return false;
    return verifyOtp('${session['email']}', '${session['token']}');
  }
}
