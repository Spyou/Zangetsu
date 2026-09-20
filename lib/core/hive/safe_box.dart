import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/apple_tv.dart';

/// Directory Hive keeps its box files in.
///
/// [openBoxSafely] needs it to move an unreadable file aside, and Hive's own
/// `homePath` isn't on the public interface. [initHiveForApp] records it here;
/// tests that call `Hive.init` directly set it themselves.
@visibleForTesting
String? hiveBoxDir;

/// Box names whose file couldn't be read this launch and were reopened empty.
///
/// A store that syncs to the cloud should check this after opening: an emptied
/// box needs a forced re-pull, because whatever throttles that pull lives in a
/// *different* box that survived.
final Set<String> quarantinedBoxes = <String>{};

/// Initializes Hive in a directory this platform can actually write.
///
/// [Hive.initFlutter] stores boxes under Documents. On a physical Apple TV,
/// Documents exists but rejects writes (errno 1) — the first [openBoxSafely]
/// during boot then crashes. tvOS only permits writes to Library/Caches (and
/// tmp); see path_provider_tvos PathProviderPlugin.
Future<void> initHiveForApp() async {
  if (isAppleTv) {
    final cache = await getApplicationCacheDirectory();
    hiveBoxDir = '${cache.path}/hive';
    Hive.init(hiveBoxDir!);
    return;
  }
  await Hive.initFlutter();
  // Same directory initFlutter just used; the plugin call is cached.
  hiveBoxDir = (await getApplicationDocumentsDirectory()).path;
}

/// Opens a Hive box, self-healing if the on-disk file is unreadable.
///
/// A corrupt box file (an interrupted write, flaky storage) makes
/// [Hive.openBox] throw — e.g. `HiveError: unknown typeId`. Because every store
/// opens its box during startup, one bad file would otherwise hang the splash
/// forever: the whole `initDependencies` chain dies on the unhandled error and
/// the app never finishes booting. Rather than brick the app, move the
/// unreadable file aside and reopen it empty.
///
/// **It is moved, never deleted.** This used to delete it, on the assumption —
/// written into this comment — that every box held "non-critical or
/// cloud-recoverable" data. That stopped being true once `my_list` and
/// `list_status` moved in, and real devices were logged silently losing a
/// user's library, history, resume positions and downloads. The bytes now
/// survive as `<name>.hive.corrupt` beside the box, so a later build (or a
/// support request) can still salvage them. The reopen behaviour, and the
/// splash-hang protection that motivated it, are unchanged.
///
/// If the *reopen* also fails (e.g. the disk is full) there's nothing we can
/// do — that rethrows.
Future<Box<E>> openBoxSafely<E>(String name) async {
  try {
    return await Hive.openBox<E>(name);
  } catch (e) {
    debugPrint('[Hive] box "$name" is unreadable ($e) — quarantining it.');
    await _quarantine(name);
    quarantinedBoxes.add(name);
    return await Hive.openBox<E>(name);
  }
}

/// Renames the unreadable file to `<name>.hive.corrupt`, falling back to the
/// old delete if it can't be moved — booting still matters more than the bytes.
Future<void> _quarantine(String name) async {
  final dir = hiveBoxDir;
  if (dir != null) {
    // Hive lowercases the box name for the filename. `.hivec` needs no
    // handling: findHiveFileAndCleanUp has already deleted it (or renamed it
    // into `.hive`) by the time an open can fail.
    final file = File('$dir/${name.toLowerCase()}.hive');
    try {
      if (file.existsSync()) {
        final kept = '${file.path}.corrupt';
        // One kept copy per box, so repeated failures can't fill the disk.
        final previous = File(kept);
        if (previous.existsSync()) previous.deleteSync();
        await file.rename(kept);
        debugPrint('[Hive] kept the unreadable "$name" at $kept');
        return;
      }
    } catch (e) {
      debugPrint('[Hive] could not move "$name" aside ($e) — deleting it.');
    }
  }
  try {
    await Hive.deleteBoxFromDisk(name);
  } catch (deleteError) {
    // deleteBoxFromDisk removes the data (.hive) file first, then the .lock —
    // and its exists()/delete() on the .lock is a TOCTOU race: the lock can be
    // released in the gap, throwing PathNotFoundException even though the data
    // file is already gone. Don't let that abort recovery; the reopen above is
    // what actually matters.
    debugPrint(
      '[Hive] cleanup of "$name" hit $deleteError — reopening anyway.',
    );
  }
}
