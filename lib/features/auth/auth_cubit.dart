import 'dart:async';
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/appwrite/appwrite_service.dart';
import '../../core/environment.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Auth view-state. [user] is the Appwrite account when authenticated;
/// [avatarUrl] is derived from the `avatarId` stored in account prefs.
class AuthState extends Equatable {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.avatarUrl,
    this.busy = false,
    this.error,
  });

  final AuthStatus status;
  final models.User? user;
  final String? avatarUrl;
  final bool busy; // an auth action (login/signup/upload) is in flight
  final String? error;

  bool get isLoggedIn => status == AuthStatus.authenticated && user != null;
  String get displayName => user?.name.isNotEmpty == true ? user!.name : (user?.email ?? '');

  AuthState copyWith({
    AuthStatus? status,
    models.User? Function()? user,
    String? Function()? avatarUrl,
    bool? busy,
    String? Function()? error,
  }) => AuthState(
    status: status ?? this.status,
    user: user != null ? user() : this.user,
    avatarUrl: avatarUrl != null ? avatarUrl() : this.avatarUrl,
    busy: busy ?? this.busy,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [status, user?.$id, user?.name, user?.email, avatarUrl, busy, error];
}

/// Owns Appwrite email/password auth + the profile (name + avatar). Other
/// features react to [isLoggedIn] via BlocBuilder/BlocListener.
class AuthCubit extends Cubit<AuthState> {
  AuthCubit(this._aw) : super(const AuthState());

  final AppwriteService _aw;

  /// Hive box that caches the signed-in user (opened in [initDependencies]).
  static const String cacheBoxName = 'auth_cache';
  static const String _userKey = 'user';

  Box? get _cache =>
      Hive.isBoxOpen(cacheBoxName) ? Hive.box(cacheBoxName) : null;

  /// The last-known user from the local cache, or null. Never throws.
  models.User? _readCachedUser() {
    try {
      final raw = _cache?.get(_userKey);
      if (raw is String && raw.isNotEmpty) {
        return models.User.fromMap(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {/* malformed cache → treat as none */}
    return null;
  }

  void _writeCachedUser(models.User u) {
    try {
      _cache?.put(_userKey, jsonEncode(u.toMap()));
    } catch (_) {/* best-effort */}
  }

  void _clearCachedUser() {
    try {
      _cache?.delete(_userKey);
    } catch (_) {}
  }

  String? _avatarFromUser(models.User u) {
    final id = u.prefs.data['avatarId'];
    return (id is String && id.isNotEmpty) ? _aw.avatarUrl(id) : null;
  }

  /// Restore a persisted session on boot. Silent — no busy/error UI.
  ///
  /// Optimistic: if a cached user exists we emit it IMMEDIATELY (so the
  /// logged-in UI shows on boot with no network wait — no "Sign in" flash) and
  /// validate against Appwrite in the background. Only when there is no cache
  /// (first run / signed out) do we await the network check.
  Future<void> restore() async {
    final cached = _readCachedUser();
    if (cached != null) {
      emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: () => cached,
        avatarUrl: () => _avatarFromUser(cached),
      ));
      unawaited(_validate(hadCache: true)); // refresh, don't block boot
      return;
    }
    await _validate(hadCache: false);
  }

  /// Confirm the session with Appwrite and refresh the cached user. A 401 means
  /// the session is genuinely gone → sign out + clear cache. Any other failure
  /// (offline/timeout/server) keeps a cached session so a network blip doesn't
  /// bounce the user to "Sign in".
  Future<void> _validate({required bool hadCache}) async {
    try {
      final u = await _aw.account.get();
      _writeCachedUser(u);
      emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
      ));
    } on AppwriteException catch (e) {
      if (e.code == 401) {
        _clearCachedUser();
        emit(state.copyWith(
            status: AuthStatus.unauthenticated, user: () => null));
      } else if (!hadCache) {
        emit(state.copyWith(
            status: AuthStatus.unauthenticated, user: () => null));
      }
    } catch (_) {
      if (!hadCache) {
        emit(state.copyWith(
            status: AuthStatus.unauthenticated, user: () => null));
      }
    }
  }

  Future<bool> login(String email, String password) =>
      _run(() async {
        await _aw.account.createEmailPasswordSession(email: email, password: password);
        return _aw.account.get();
      });

  Future<bool> signUp(String name, String email, String password) =>
      _run(() async {
        await _aw.account.create(
          userId: ID.unique(),
          email: email,
          password: password,
          name: name,
        );
        await _aw.account.createEmailPasswordSession(email: email, password: password);
        return _aw.account.get();
      });

  /// Send a password-recovery email. Appwrite mails a link to
  /// [Environment.passwordResetUrl] with `?userId=…&secret=…` appended, where
  /// the user sets a new password (the hosted reset page calls
  /// `account.updateRecovery`). Does NOT touch auth state — it works while
  /// signed out. Returns null on success, or an error message to show.
  Future<String?> sendRecovery(String email) async {
    try {
      await _aw.account.createRecovery(
        email: email,
        url: Environment.passwordResetUrl,
      );
      return null;
    } on AppwriteException catch (e) {
      return e.message ?? 'Could not send the reset email';
    } catch (_) {
      return 'Could not send the reset email';
    }
  }

  /// Shared login/signup runner: sets busy, runs [action] to a fresh User,
  /// emits authenticated on success. Returns true on success.
  Future<bool> _run(Future<models.User> Function() action) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      final u = await action();
      _writeCachedUser(u);
      emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
        busy: false,
      ));
      return true;
    } on AppwriteException catch (e) {
      emit(state.copyWith(busy: false, error: () => e.message ?? 'Authentication failed'));
      return false;
    } catch (e) {
      emit(state.copyWith(busy: false, error: () => 'Something went wrong'));
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await _aw.account.deleteSession(sessionId: 'current');
    } catch (_) {/* ignore — clear locally regardless */}
    _clearCachedUser();
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  Future<bool> updateName(String name) async {
    try {
      final u = await _aw.account.updateName(name: name);
      _writeCachedUser(u);
      emit(state.copyWith(user: () => u));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Upload a new profile picture from [path], store its file id in prefs.
  Future<bool> updateAvatar(String path) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      // Remember the current avatar so we can delete it once the new one is
      // safely uploaded — otherwise every change orphans a file in the bucket
      // forever, which is what actually fills the storage quota.
      final oldAvatarId = state.user?.prefs.data['avatarId'] as String?;
      final file = await _aw.storage.createFile(
        bucketId: 'avatars',
        fileId: ID.unique(),
        file: InputFile.fromPath(path: path),
      );
      final prefs = Map<String, dynamic>.from(state.user?.prefs.data ?? {});
      prefs['avatarId'] = file.$id;
      await _aw.account.updatePrefs(prefs: prefs);
      final u = await _aw.account.get();
      _writeCachedUser(u);
      emit(state.copyWith(
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
        busy: false,
      ));
      // Best-effort cleanup of the previous picture (never blocks success).
      if (oldAvatarId != null &&
          oldAvatarId.isNotEmpty &&
          oldAvatarId != file.$id) {
        try {
          await _aw.storage
              .deleteFile(bucketId: 'avatars', fileId: oldAvatarId);
        } catch (_) {/* already gone / offline — harmless */}
      }
      return true;
    } catch (_) {
      emit(state.copyWith(busy: false, error: () => "Couldn't update photo"));
      return false;
    }
  }
}
