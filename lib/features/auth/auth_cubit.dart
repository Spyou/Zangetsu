import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException, UserAttributes;

import '../../core/appwrite/appwrite_service.dart';
import '../../core/supabase/auth_user.dart';
import '../../core/supabase/supabase_service.dart';
import 'migration_bridge.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Auth view-state. [user] is the app-owned [AuthUser] when authenticated;
/// [avatarUrl] is derived from the `avatar_path` stored in the profile row.
class AuthState extends Equatable {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.avatarUrl,
    this.busy = false,
    this.error,
  });

  final AuthStatus status;
  final AuthUser? user;
  final String? avatarUrl;
  final bool busy; // an auth action (login/signup/upload) is in flight
  final String? error;

  bool get isLoggedIn => status == AuthStatus.authenticated && user != null;
  String get displayName => user?.name.isNotEmpty == true ? user!.name : (user?.email ?? '');

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? Function()? user,
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
  List<Object?> get props => [status, user?.id, user?.name, user?.email, avatarUrl, busy, error];
}

/// Owns Supabase email/password auth + the profile (name + avatar), plus the
/// invisible migration from the legacy Appwrite account. Other features react
/// to [isLoggedIn] via BlocBuilder/BlocListener.
class AuthCubit extends Cubit<AuthState> {
  AuthCubit(this._sb, this._aw, this._bridge) : super(const AuthState());

  final SupabaseService _sb;
  final AppwriteService _aw;
  final MigrationBridge _bridge;

  /// Hive box that caches the signed-in user (opened in [initDependencies]).
  static const String cacheBoxName = 'auth_cache';
  static const String _userKey = 'user';

  Box? get _cache =>
      Hive.isBoxOpen(cacheBoxName) ? Hive.box(cacheBoxName) : null;

  /// The last-known user from the local cache, or null. Never throws.
  AuthUser? _readCachedUser() {
    try {
      final raw = _cache?.get(_userKey);
      if (raw is String && raw.isNotEmpty) {
        return AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {/* malformed cache → treat as none */}
    return null;
  }

  void _writeCachedUser(AuthUser u) {
    try {
      _cache?.put(_userKey, jsonEncode(u.toJson()));
    } catch (_) {/* best-effort */}
  }

  void _clearCachedUser() {
    try {
      _cache?.delete(_userKey);
    } catch (_) {}
  }

  String? _avatarFromUser(AuthUser u) {
    final path = u.avatarPath;
    return (path != null && path.isNotEmpty) ? _sb.avatarUrl(path) : null;
  }

  /// Load the `profiles` row for [uid], or null if missing/offline.
  Future<Map<String, dynamic>?> _loadProfile(String uid) async {
    try {
      return await _sb.client.from('profiles').select().eq('id', uid).maybeSingle();
    } catch (_) {
      return null;
    }
  }

  /// Restore a persisted session on boot. Silent — no busy/error UI.
  ///
  /// Optimistic: if a cached user exists we emit it IMMEDIATELY (so the
  /// logged-in UI shows on boot with no network wait — no "Sign in" flash) and
  /// validate against Supabase in the background. Only when there is no cache
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

  /// Confirm the session with Supabase and refresh the cached user. If there
  /// is no Supabase session, try the invisible Case-2 migration (a still
  /// signed-in Appwrite user) before giving up. Any failure with a cached
  /// session keeps it — a network blip shouldn't bounce the user to "Sign in".
  Future<void> _validate({required bool hadCache}) async {
    try {
      final current = _sb.client.auth.currentSession;
      final authUser = current?.user ?? _sb.client.auth.currentUser;
      if (authUser != null) {
        final profile = await _loadProfile(authUser.id);
        final u = AuthUser.fromSupabase(authUser, profile);
        _writeCachedUser(u);
        emit(state.copyWith(
          status: AuthStatus.authenticated,
          user: () => u,
          avatarUrl: () => _avatarFromUser(u),
        ));
        return;
      }

      // No Supabase session — check for a still-signed-in Appwrite user
      // (Case 2: invisible migration for an existing session).
      final jwt = await _aw.mintJwt();
      if (jwt != null) {
        final migrated = await _bridge.trySessionMigration(jwt);
        if (migrated) {
          final u2 = _sb.client.auth.currentUser;
          if (u2 != null) {
            final profile = await _loadProfile(u2.id);
            final u = AuthUser.fromSupabase(u2, profile);
            _writeCachedUser(u);
            emit(state.copyWith(
              status: AuthStatus.authenticated,
              user: () => u,
              avatarUrl: () => _avatarFromUser(u),
            ));
            return;
          }
        }
      }

      _clearCachedUser();
      emit(state.copyWith(status: AuthStatus.unauthenticated, user: () => null));
    } catch (_) {
      if (!hadCache) {
        emit(state.copyWith(status: AuthStatus.unauthenticated, user: () => null));
      }
    }
  }

  Future<bool> login(String email, String password) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      await _sb.client.auth.signInWithPassword(email: email, password: password);
      return await _emitFromCurrentUser();
    } on AuthException catch (_) {
      return _loginViaMigration(email, password);
    } catch (_) {
      return _loginViaMigration(email, password);
    }
  }

  /// Legacy Appwrite account not yet migrated: heal it (Case 1) then sign in.
  Future<bool> _loginViaMigration(String email, String password) async {
    try {
      final migrated = await _bridge.tryPasswordMigration(email, password);
      if (migrated) return _emitFromCurrentUser();
      emit(state.copyWith(busy: false, error: () => 'Invalid email or password'));
      return false;
    } catch (_) {
      emit(state.copyWith(busy: false, error: () => 'Authentication failed'));
      return false;
    }
  }

  /// A Supabase session was established outside the normal login flow — e.g. the
  /// TV signed itself in via device pairing (`verifyOtp`). Adopt it and emit
  /// authenticated, exactly like a password login would.
  Future<bool> adoptCurrentSession() => _emitFromCurrentUser();

  Future<bool> _emitFromCurrentUser() async {
    final authUser = _sb.client.auth.currentUser;
    if (authUser == null) {
      emit(state.copyWith(busy: false, error: () => 'Authentication failed'));
      return false;
    }
    final profile = await _loadProfile(authUser.id);
    final u = AuthUser.fromSupabase(authUser, profile);
    _writeCachedUser(u);
    emit(state.copyWith(
      status: AuthStatus.authenticated,
      user: () => u,
      avatarUrl: () => _avatarFromUser(u),
      busy: false,
    ));
    return true;
  }

  Future<bool> signUp(String name, String email, String password) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      await _sb.client.auth.signUp(email: email, password: password, data: {'name': name});
      final authUser = _sb.client.auth.currentUser;
      if (authUser == null) {
        emit(state.copyWith(busy: false, error: () => 'Sign up failed'));
        return false;
      }
      await _sb.client.from('profiles').upsert({'id': authUser.id, 'display_name': name});
      final u = AuthUser.fromSupabase(authUser, {'display_name': name});
      _writeCachedUser(u);
      emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
        busy: false,
      ));
      return true;
    } on AuthException catch (e) {
      emit(state.copyWith(busy: false, error: () => e.message));
      return false;
    } catch (_) {
      emit(state.copyWith(busy: false, error: () => 'Something went wrong'));
      return false;
    }
  }

  /// Send a password-recovery email via Supabase. Does NOT touch auth state —
  /// it works while signed out. Returns null on success, or an error message.
  Future<String?> sendRecovery(String email) async {
    try {
      await _sb.client.auth.resetPasswordForEmail(email);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not send the reset email';
    }
  }

  Future<void> logout() async {
    try {
      await _sb.client.auth.signOut();
    } catch (_) {/* ignore — clear locally regardless */}
    _clearCachedUser();
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  Future<bool> updateName(String name) async {
    try {
      final uid = _sb.currentUserId();
      if (uid == null) return false;
      await _sb.client.from('profiles').upsert({'id': uid, 'display_name': name});
      await _sb.client.auth.updateUser(UserAttributes(data: {'name': name}));
      final current = state.user;
      if (current == null) return false;
      final u = AuthUser(id: current.id, name: name, email: current.email, avatarPath: current.avatarPath);
      _writeCachedUser(u);
      emit(state.copyWith(user: () => u));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Upload a new profile picture from [path], store its object path in the
  /// profile row.
  Future<bool> updateAvatar(String path) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      final uid = _sb.currentUserId();
      if (uid == null) {
        emit(state.copyWith(busy: false, error: () => "Couldn't update photo"));
        return false;
      }
      // Remember the current avatar so we can delete it once the new one is
      // safely uploaded — otherwise every change orphans a file in the bucket
      // forever, which is what actually fills the storage quota.
      final oldPath = state.user?.avatarPath;
      final ext = path.contains('.') ? path.split('.').last : 'jpg';
      // ponytail: timestamp+hashCode is unique enough for one account's
      // avatar folder; a real uuid dep would be overkill for this.
      final name = '${DateTime.now().microsecondsSinceEpoch}${path.hashCode}';
      final objectPath = '$uid/$name.$ext';
      await _sb.client.storage.from('avatars').upload(objectPath, File(path));
      await _sb.client.from('profiles').upsert({'id': uid, 'avatar_path': objectPath});

      final current = state.user;
      final u = current == null
          ? null
          : AuthUser(id: current.id, name: current.name, email: current.email, avatarPath: objectPath);
      if (u != null) _writeCachedUser(u);
      emit(state.copyWith(
        user: () => u,
        avatarUrl: () => _sb.avatarUrl(objectPath),
        busy: false,
      ));
      // Best-effort cleanup of the previous picture (never blocks success).
      if (oldPath != null && oldPath.isNotEmpty && oldPath != objectPath) {
        try {
          await _sb.client.storage.from('avatars').remove([oldPath]);
        } catch (_) {/* already gone / offline — harmless */}
      }
      return true;
    } catch (_) {
      emit(state.copyWith(busy: false, error: () => "Couldn't update photo"));
      return false;
    }
  }
}
