import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/catalogue_router.dart';

/// Records which repo a call landed on. Every method not overridden throws,
/// so an unexpected forward shows up as a failure, not a silent pass.
class _Spy implements CatalogueRepository {
  _Spy(this.name);
  final String name;
  final calls = <String>[];

  @override
  noSuchMethod(Invocation i) {
    calls.add(i.memberName.toString());
    if (i.memberName == #home) return Future.value(const <HomeSection>[]);
    if (i.memberName == #search) return Future.value(const <MediaItem>[]);
    if (i.memberName == #searchStatus) {
      return Future.value((
        items: const <MediaItem>[],
        outcome: SourceOutcome.ok,
      ));
    }
    if (i.memberName == #loadedSources) {
      return const <({String id, String name})>[];
    }
    if (i.memberName == #sources) return Future.value(const <VideoSource>[]);
    if (i.memberName == #episodes) return Future.value(const <Episode>[]);
    if (i.memberName == #polledSources) {
      return Future.value((sources: const <VideoSource>[], done: true));
    }
    if (i.memberName == #detail) {
      return Future.value(MediaDetail(
        id: 'x', title: 'x', url: 'x', type: ProviderType.anime, sourceId: name));
    }
    if (i.memberName == #sourceId) return name;
    return super.noSuchMethod(i);
  }
}

void main() {
  late _Spy source, meta;
  var on = false;
  late CatalogueRouter router;

  setUp(() {
    source = _Spy('src');
    meta = _Spy('zm');
    on = false;
    router = CatalogueRouter(source: source, metadata: meta, enabled: () => on);
  });

  test('toggle off: browsing calls go to the source', () async {
    await router.home();
    await router.search('naruto');
    await router.searchStatus('naruto');
    router.loadedSources;
    expect(source.calls, contains('Symbol("home")'));
    expect(source.calls, contains('Symbol("search")'));
    expect(source.calls, contains('Symbol("searchStatus")'));
    expect(source.calls, contains('Symbol("loadedSources")'));
    expect(meta.calls, isEmpty);
  });

  test('toggle on: browsing calls go to metadata', () async {
    on = true;
    await router.home();
    await router.search('naruto');
    await router.searchStatus('naruto');
    router.loadedSources;
    expect(meta.calls, contains('Symbol("home")'));
    expect(meta.calls, contains('Symbol("search")'));
    expect(meta.calls, contains('Symbol("searchStatus")'));
    expect(meta.calls, contains('Symbol("loadedSources")'));
    expect(source.calls, isEmpty);
  });

  test(
    'detail, episodes, sources and polledSources route by url scheme, not by toggle',
    () async {
      // Toggle ON, but every url is a source url — must stay on the source.
      on = true;
      await router.detail('https://allanime.to/x');
      await router.episodes('https://allanime.to/x');
      await router.sources('https://allanime.to/x/1');
      await router.polledSources('https://allanime.to/x/1');
      expect(source.calls.length, 4);
      expect(meta.calls, isEmpty);

      // Toggle OFF, but every url is a zm:// url — must still hit metadata.
      on = false;
      await router.detail('zm://anime/mal:1');
      await router.episodes('zm://anime/mal:1');
      await router.sources('zm://anime/mal:1/ep/1');
      await router.polledSources('zm://anime/mal:1/ep/1');
      expect(meta.calls.length, 4);
    },
  );

  test('sourceId reflects the active side', () {
    expect(router.sourceId, 'src');
    on = true;
    expect(router.sourceId, 'zm');
  });
}
