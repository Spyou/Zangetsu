import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
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
    if (i.memberName == #sources) return Future.value(const <VideoSource>[]);
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

  test('toggle off: home and search go to the source', () async {
    await router.home();
    await router.search('naruto');
    expect(source.calls, contains('Symbol("home")'));
    expect(source.calls, contains('Symbol("search")'));
    expect(meta.calls, isEmpty);
  });

  test('toggle on: home and search go to metadata', () async {
    on = true;
    await router.home();
    await router.search('naruto');
    expect(meta.calls, contains('Symbol("home")'));
    expect(meta.calls, contains('Symbol("search")'));
    expect(source.calls, isEmpty);
  });

  test('detail and sources route by url scheme, not by toggle', () async {
    on = true;
    await router.detail('https://allanime.to/x');
    await router.sources('https://allanime.to/x/1');
    expect(source.calls.length, 2);
    expect(meta.calls, isEmpty);

    on = false;
    await router.detail('zm://anime/mal:1');
    await router.sources('zm://anime/mal:1/ep/1');
    expect(meta.calls.length, 2);
  });

  test('sourceId reflects the active side', () {
    expect(router.sourceId, 'src');
    on = true;
    expect(router.sourceId, 'zm');
  });
}
