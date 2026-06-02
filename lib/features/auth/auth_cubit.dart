import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/appwrite/appwrite_service.dart';

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

  String? _avatarFromUser(models.User u) {
    final id = u.prefs.data['avatarId'];
    return (id is String && id.isNotEmpty) ? _aw.avatarUrl(id) : null;
  }

  /// Restore a persisted session on boot. Silent — no busy/error UI.
  Future<void> restore() async {
    try {
      final u = await _aw.account.get();
      emit(state.copyWith(
        status: AuthStatus.authenticated,
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
      ));
    } catch (_) {
      emit(state.copyWith(status: AuthStatus.unauthenticated, user: () => null));
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

  /// Shared login/signup runner: sets busy, runs [action] to a fresh User,
  /// emits authenticated on success. Returns true on success.
  Future<bool> _run(Future<models.User> Function() action) async {
    emit(state.copyWith(busy: true, error: () => null));
    try {
      final u = await action();
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
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  Future<bool> updateName(String name) async {
    try {
      final u = await _aw.account.updateName(name: name);
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
      final file = await _aw.storage.createFile(
        bucketId: 'avatars',
        fileId: ID.unique(),
        file: InputFile.fromPath(path: path),
      );
      final prefs = Map<String, dynamic>.from(state.user?.prefs.data ?? {});
      prefs['avatarId'] = file.$id;
      await _aw.account.updatePrefs(prefs: prefs);
      final u = await _aw.account.get();
      emit(state.copyWith(
        user: () => u,
        avatarUrl: () => _avatarFromUser(u),
        busy: false,
      ));
      return true;
    } catch (_) {
      emit(state.copyWith(busy: false, error: () => "Couldn't update photo"));
      return false;
    }
  }
}
