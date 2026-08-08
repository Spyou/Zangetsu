import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../di/injector.dart';
import '../repository/source_repository.dart';
import '../state/active_source_cubit.dart';
import 'content_mode.dart';

/// App-wide content mode (anime | manga | novel), persisted across launches.
/// Also remembers the active source separately per mode, so flipping to Manga
/// and back never disturbs the anime source selection.
class ContentModeCubit extends Cubit<ContentMode> {
  ContentModeCubit._(this._box, this._active, super.initial);

  final Box _box;
  final ActiveSourceCubit _active;

  static Future<ContentModeCubit> create(ActiveSourceCubit active) async {
    final box = await openBoxSafely('content_mode');
    return ContentModeCubit._(box, active, _restore(box));
  }

  static ContentMode _restore(Box box) {
    final stored = box.get('mode') as String?;
    if (stored == null) return ContentMode.anime;
    try {
      return ContentMode.values.byName(stored);
    } catch (_) {
      return ContentMode.anime;
    }
  }

  /// True if [id] is a currently-loaded source. [SourceRepository] is
  /// registered in the injector *after* this cubit, so it can't be a
  /// constructor dependency — looked up lazily here instead, the same way
  /// injector.dart itself guards optional-late dependencies (see
  /// `sl.isRegistered<PlaybackPrefs>()` there). By the time a user can tap
  /// the mode switcher, SourceRepository is long since registered; if for
  /// some reason it isn't yet, we can't validate, so trust the id rather
  /// than dropping a legitimate pick.
  bool _sourceStillLoaded(String id) {
    if (!sl.isRegistered<SourceRepository>()) return true;
    return sl<SourceRepository>().loadedSources.any((s) => s.id == id);
  }

  Future<void> setMode(ContentMode m) async {
    if (m == state) return;
    // Capture the outgoing mode/source BEFORE emitting or restoring anything
    // — read after a restore, this would park the newly-restored source
    // under the OUTGOING mode's key instead of what was really active there.
    final outgoingMode = state;
    final outgoingSource = _active.state;
    emit(m); // update the UI first; persistence below is fire-and-forget.

    // Restore the incoming mode's remembered source — but only if it's still
    // loaded. A stale/uninstalled id would otherwise leave Home silently
    // empty (ActiveSourceCubit emits it unvalidated and HomeCubit swallows
    // the resulting error into an empty section list).
    final remembered = _box.get('src.${m.name}') as String?;
    if (remembered != null &&
        remembered.isNotEmpty &&
        _sourceStillLoaded(remembered)) {
      _active.setSource(remembered);
    }

    // Fire-and-forget; Hive serializes writes so ordering is preserved (same
    // rationale as ActiveSourceCubit.setSource). Each write catches its own
    // error so a failure can't surface as an unhandled zone error — the mode
    // switcher calls setMode without awaiting it — and can't block the other
    // key's write either.
    unawaited(
      _box.put('src.${outgoingMode.name}', outgoingSource).catchError(
        (e) => debugPrint('[ContentModeCubit] failed to park $outgoingSource: $e'),
      ),
    );
    unawaited(
      _box.put('mode', m.name).catchError(
        (e) => debugPrint('[ContentModeCubit] failed to persist mode ${m.name}: $e'),
      ),
    );
  }
}
