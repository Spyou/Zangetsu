import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Opens a Hive box, self-healing if the on-disk file is unreadable.
///
/// A corrupt box file (an interrupted write, flaky storage) makes
/// [Hive.openBox] throw — e.g. `HiveError: unknown typeId`. Because every store
/// opens its box during startup, one bad file would otherwise hang the splash
/// forever: the whole `initDependencies` chain dies on the unhandled error and
/// the app never finishes booting. Rather than brick the app, delete the
/// unreadable file and reopen it empty.
///
/// Every box we open holds non-critical or cloud-recoverable data (resume/read
/// positions, history, prefs, caches), so dropping a corrupt one is strictly
/// better than never launching. If the *reopen* also fails (e.g. the disk is
/// full) there's nothing we can do — that rethrows.
Future<Box<E>> openBoxSafely<E>(String name) async {
  try {
    return await Hive.openBox<E>(name);
  } catch (e) {
    debugPrint('[Hive] box "$name" is corrupt ($e) — recreating it empty.');
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (deleteError) {
      // deleteBoxFromDisk removes the data (.hive) file first, then the .lock —
      // and its exists()/delete() on the .lock is a TOCTOU race: the lock can be
      // released in the gap, throwing PathNotFoundException even though the data
      // file is already gone. Don't let that abort recovery; the reopen below is
      // what actually matters.
      debugPrint(
        '[Hive] cleanup of "$name" hit $deleteError — reopening anyway.',
      );
    }
    return await Hive.openBox<E>(name);
  }
}
