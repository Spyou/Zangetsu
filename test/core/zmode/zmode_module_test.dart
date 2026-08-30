import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_module.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';

class _Repo implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  List<({String id, String name})> get loadedSources => const [
    (id: 'allanime', name: 'AllAnime'),
    (id: 'mihon:1', name: 'MangaDex'),
    (id: 'lnr:2', name: 'NovelUpdates'),
    (id: 'cs:3', name: 'A CS source'),
  ];
}

void main() {
  final repo = _Repo();

  test('candidates are filtered by source-id prefix', () {
    expect(candidatesForKind(repo, ZKind.manga).map((s) => s.id), ['mihon:1']);
    expect(candidatesForKind(repo, ZKind.novel).map((s) => s.id), ['lnr:2']);
    expect(candidatesForKind(repo, ZKind.anime).map((s) => s.id),
        ['allanime', 'cs:3']);
    expect(candidatesForKind(repo, ZKind.movie).map((s) => s.id),
        ['allanime', 'cs:3']);
  });

  test('browse kind splits Movie/TV out of the anime content mode', () {
    expect(browseKindFor(ContentMode.anime, StreamKind.anime), ZKind.anime);
    expect(browseKindFor(ContentMode.anime, StreamKind.movie), ZKind.movie);
    expect(browseKindFor(ContentMode.manga, StreamKind.movie), ZKind.manga);
    expect(browseKindFor(ContentMode.novel, StreamKind.anime), ZKind.novel);
  });
}
