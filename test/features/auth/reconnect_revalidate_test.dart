import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/features/auth/reconnect.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';

/// The startup session check cannot tell "your session expired" from "there was
/// no network for a second", so a blink offline raises the Reconnect banner —
/// and it used to stay until the next launch, because restore() only runs at
/// startup. These cover the re-test, and the guards that keep it from becoming
/// a request on every resume.

class _Sb implements SupabaseService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// AuthCubit with the one network call stubbed — everything under test here is
/// the guarding around it, not Supabase.
class _Cubit extends AuthCubit {
  _Cubit() : super(_Sb());

  int calls = 0;
  bool succeed = true;
  Future<void>? gate;

  @override
  Future<bool> ensureFreshSession() async {
    calls++;
    if (gate != null) await gate;
    if (succeed) emit(state.copyWith(needsReconnect: false));
    return succeed;
  }

  void flagIt() => emit(state.copyWith(needsReconnect: true));
}

class _SignedInCubit extends _Cubit {
  _SignedInCubit() {
    emit(
      const AuthState(
        status: AuthStatus.authenticated,
        user: AuthUser(
          id: 'test',
          name: 'Viewer',
          email: 'viewer@example.test',
        ),
      ),
    );
  }

  int logouts = 0;

  @override
  bool get hasLiveSession => true;

  @override
  Future<void> logout() async => logouts++;
}

class _HistoryWithFailedUpload implements WatchHistory {
  @override
  List<HistoryEntry> all() => [
    HistoryEntry(
      sourceId: 'test',
      showId: 'show',
      showTitle: 'Test show',
      showUrl: '',
      category: 'anime',
      episodeId: 'episode',
      episodeNumber: 1,
      episodeUrl: '',
      position: Duration.zero,
      duration: Duration.zero,
      updatedAt: 1,
    ),
  ];

  @override
  Future<({int pushed, int failed})> pushAllLocalToCloud() async =>
      (pushed: 0, failed: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyList implements MyListStore {
  @override
  List<MediaItem> all() => const [];

  @override
  Future<({int pushed, int failed})> pushAllLocalToCloud() async =>
      (pushed: 0, failed: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('partial sync reports failure and blocks logout', (tester) async {
    final auth = _SignedInCubit();
    final sl = GetIt.instance
      ..registerSingleton<AuthCubit>(auth)
      ..registerSingleton<WatchHistory>(_HistoryWithFailedUpload())
      ..registerSingleton<MyListStore>(_EmptyList());
    addTearDown(sl.reset);
    addTearDown(auth.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => syncLibraryNow(context),
                  child: const Text('Sync'),
                ),
                TextButton(
                  onPressed: () => safeLogout(context),
                  child: const Text('Log out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(
      find.text('Library sync incomplete. Please try again.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(auth.logouts, 0);
    expect(
      find.text('Library backup incomplete. Please try again.'),
      findsOneWidget,
    );
  });

  test('does nothing at all when the banner is not showing', () async {
    final c = _Cubit();
    await c.revalidateIfFlagged();
    await c.revalidateIfFlagged(force: true);
    expect(c.calls, 0, reason: 'a healthy session must cost no requests');
  });

  test('re-tests and clears the banner when back online', () async {
    final c = _Cubit()..flagIt();
    expect(c.state.needsReconnect, isTrue);

    await c.revalidateIfFlagged();

    expect(c.calls, 1);
    expect(c.state.needsReconnect, isFalse, reason: 'no restart needed');
  });

  test('still offline: it does not retry on its own', () async {
    final c = _Cubit()
      ..succeed = false
      ..flagIt();

    await c.revalidateIfFlagged();
    await c.revalidateIfFlagged(); // a second resume, moments later

    expect(c.calls, 1, reason: 'the cool-off caps a dead token to one try');
    expect(c.state.needsReconnect, isTrue, reason: 'banner stays, correctly');
  });

  test('pull-to-refresh skips the cool-off — the user asked', () async {
    final c = _Cubit()
      ..succeed = false
      ..flagIt();

    await c.revalidateIfFlagged(); // resume
    c.succeed = true; // network came back
    await c.revalidateIfFlagged(force: true); // user pulls to refresh

    expect(c.calls, 2);
    expect(c.state.needsReconnect, isFalse);
  });

  test('two triggers at once make one request, not two', () async {
    final c = _Cubit()..flagIt();
    final open = Completer<void>();
    c.gate = open.future;

    final a = c.revalidateIfFlagged(force: true);
    final b = c.revalidateIfFlagged(force: true); // arrives mid-flight
    open.complete();
    await a;
    await b;

    expect(c.calls, 1);
  });
}
