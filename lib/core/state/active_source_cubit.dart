import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// Holds the id of the currently-active content source (e.g. 'allanime',
/// 'netmirror_pv') and **persists** it so the user's pick survives restarts.
///
/// The chosen id is written to a tiny Hive box on every change and read back at
/// construction. If the saved id is no longer valid (the provider was disabled
/// or uninstalled), it falls back to [fallback] so the app never boots pointing
/// at a source that isn't loaded.
class ActiveSourceCubit extends Cubit<String> {
  ActiveSourceCubit({
    Box? box,
    String fallback = 'allanime',
    Set<String>? valid,
  })  : _box = box,
        super(_restore(box, fallback, valid));

  static const String boxName = 'app_prefs';
  static const String _key = 'active_source';

  final Box? _box;

  /// Opens the prefs box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  static String _restore(Box? box, String fallback, Set<String>? valid) {
    final saved = box?.get(_key) as String?;
    if (saved != null &&
        saved.isNotEmpty &&
        (valid == null || valid.contains(saved))) {
      return saved;
    }
    return fallback;
  }

  void setSource(String id) {
    if (id == state) return;
    emit(id);
    // Fire-and-forget; Hive serializes writes so ordering is preserved.
    _box?.put(_key, id);
  }

  /// Re-applies the persisted pick when it becomes valid *after* boot.
  ///
  /// Aniyomi sources load asynchronously, so a saved `ani:` source isn't in the
  /// valid set when [_restore] runs at construction — we fall back to a JS source
  /// then. Once the extensions register, the boot step calls this so the user's
  /// actual pick is honored instead of the fallback. Returns true if it changed.
  bool reapplySaved(bool Function(String id) isNowValid) {
    final saved = _box?.get(_key) as String?;
    if (saved == null || saved.isEmpty || saved == state) return false;
    if (!isNowValid(saved)) return false;
    emit(saved);
    return true;
  }
}
