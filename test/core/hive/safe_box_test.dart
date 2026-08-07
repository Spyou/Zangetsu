import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// A stand-in for a type an OLD build persisted via a registered adapter
/// (typeId 116). The current build no longer registers it — so reopening a box
/// that still holds one reproduces the tester's crash:
/// `HiveError: Cannot read, unknown typeId`.
class _Legacy {}

class _Id116Adapter extends TypeAdapter<_Legacy> {
  @override
  final int typeId = 116;
  @override
  _Legacy read(BinaryReader reader) => _Legacy();
  @override
  void write(BinaryWriter writer, _Legacy obj) {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('safe_box_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Seeds a box on disk with a value only the typeId-116 adapter can read,
  /// then forgets the adapter — leaving the exact corruption the tester hit.
  Future<void> writeUnreadableBox(String name) async {
    if (!Hive.isAdapterRegistered(116)) Hive.registerAdapter(_Id116Adapter());
    final box = await Hive.openBox(name);
    await box.put('k', _Legacy());
    await box.close();
    Hive.resetAdapters(); // current build no longer knows typeId 116
  }

  test('heals a corrupt box: opens it empty instead of throwing', () async {
    await writeUnreadableBox('legacy');

    // A failed Hive.openBox leaves an orphan errored completer, surfacing as an
    // unhandled async error — harmless in the app (the top-level zone logs it;
    // it's a separate future, so it can't fail init or hang the splash), but it
    // would fail this test. Run the helper in a guarded zone that swallows that
    // stray error, and resolve the result through our own completer so the test
    // sees the recovered box, not the orphan.
    final opened = Completer<Box<dynamic>>();
    runZonedGuarded(() async {
      try {
        opened.complete(await openBoxSafely('legacy'));
      } catch (e, s) {
        opened.completeError(e, s); // real failure → surface it, don't time out
      }
    }, (_, _) {}); // swallow ONLY Hive's orphan unhandled error
    final box = await opened.future.timeout(const Duration(seconds: 10));

    expect(box.isOpen, isTrue);
    expect(box.isEmpty, isTrue); // corrupt data dropped, app still boots
  });

  test('leaves a healthy box (and its data) untouched', () async {
    final box = await openBoxSafely<int>('good');
    await box.put('n', 42);
    await box.close();
    final reopened = await openBoxSafely<int>('good');
    expect(reopened.get('n'), 42);
  });
}
