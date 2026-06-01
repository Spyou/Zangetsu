import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/playback/my_list.dart';

/// Cubit that owns the current "My List" contents.
///
/// The state is `List<MediaItem>` initialised from [MyListStore.all].
/// Call [reload] after any toggle to re-read the Hive box and push a fresh
/// snapshot to all listeners.
class MyListCubit extends Cubit<List<MediaItem>> {
  MyListCubit(this._store) : super(_store.all());

  final MyListStore _store;

  /// Re-read the Hive box and emit the updated list.
  void reload() => emit(_store.all());
}
