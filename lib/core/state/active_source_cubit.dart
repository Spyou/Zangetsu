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
}
