import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';

/// The startup session check cannot tell "your session expired" from "there was
/// no network for a second", so a blink offline raises the Reconnect banner —
/// and it used to stay until the next launch, because restore() only runs at
/// startup. These cover the re-test, and the guards that keep it from becoming
/// a request on every resume.

class _Sb implements SupabaseService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Aw implements AppwriteService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Bridge implements MigrationBridge {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// AuthCubit with the one network call stubbed — everything under test here is
/// the guarding around it, not Supabase.
class _Cubit extends AuthCubit {
  _Cubit() : super(_Sb(), _Aw(), _Bridge());

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

void main() {
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
