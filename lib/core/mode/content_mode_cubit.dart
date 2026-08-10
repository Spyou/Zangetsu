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

  /// Which mode a source id belongs to, by id prefix — no manager lookup, so
  /// it's cheap and can't throw when the registry isn't up yet: `lnr:` = novel,
  /// `mihon:` = manga, everything else (JS / CloudStream / Aniyomi) = anime.
  /// Matches the prefix rules in [sourceTypeOf].
  static bool _sourceInMode(String id, ContentMode m) => switch (m) {
    ContentMode.novel => id.startsWith('lnr:'),
    ContentMode.manga => id.startsWith('mihon:'),
    ContentMode.anime => !id.startsWith('lnr:') && !id.startsWith('mihon:'),
  };

  /// No valid remembered source for [m] — don't leave a source from another
  /// mode active (the "enter Novel and the header still shows an anime source"
  /// bug). Keep the current pick if it already fits [m], otherwise land on the
  /// first loaded source of the mode. Guarded on SourceRepository like
  /// [_sourceStillLoaded]: if it isn't ready we can't enumerate, so leave the
  /// source alone.
  void _fallBackToModeSource(ContentMode m) {
    if (!sl.isRegistered<SourceRepository>()) return;
    if (_sourceInMode(_active.state, m)) return; // already fits — keep it
    for (final s in sl<SourceRepository>().loadedSources) {
      if (_sourceInMode(s.id, m)) {
        _active.setSource(s.id);
        return;
      }
    }
  }

  /// Boot safety net: make the restored mode's active source belong to that
  /// mode. Called once after SourceRepository is registered so a novel-mode
  /// launch that restored an anime source self-corrects. No-op for anime and
  /// for any already-correct pick.
  void ensureSourceForMode() => _fallBackToModeSource(state);

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
    } else {
      // No valid remembered source for this mode — don't strand a reading mode
      // on the anime source that was active; land on a source of this mode.
      _fallBackToModeSource(m);
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
