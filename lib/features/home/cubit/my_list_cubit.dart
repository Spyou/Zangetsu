import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/watch_status.dart';
import '../../../core/playback/list_status_store.dart';
import '../../../core/playback/my_list.dart';

/// One My List row: the title plus its library status (null = saved without a
/// status, e.g. a legacy bookmark).
class MyListEntry {
  const MyListEntry(this.item, this.status);
  final MediaItem item;
  final WatchStatus? status;
}

/// Owns My List — the user's OWN saved titles ([MyListStore]), each annotated
/// with its [WatchStatus] from [ListStatusStore]. This is the app's personal
/// list; AniList's own lists are NOT merged in. Re-emits when either source
/// changes.
class MyListCubit extends Cubit<List<MyListEntry>> {
  MyListCubit(this._store, this._status) : super(const []) {
    _store.revision.addListener(reload);
    _status.revision.addListener(reload);
    reload();
  }

  final MyListStore _store;
  final ListStatusStore _status;

  void reload() {
    if (isClosed) return;
    emit([for (final m in _store.all()) MyListEntry(m, _status.statusOf(m))]);
  }

  @override
  Future<void> close() {
    _store.revision.removeListener(reload);
    _status.revision.removeListener(reload);
    return super.close();
  }
}
