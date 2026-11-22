import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:watch_app/core/mangayomi/mangayomi_provider.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

class _FakeManager extends MangayomiManager {
  _FakeManager(this.worker)
    : super(MangayomiExtensionService(Directory.systemTemp));

  final _FakeWorker worker;

  @override
  Future<T> run<T>(
    String sourceId,
    Future<T> Function(MangayomiRuntimeWorker worker) operation,
  ) => operation(worker);
}

class _FakeWorker extends MangayomiRuntimeWorker {
  _FakeWorker({required this.latest, this.popular, this.latestFailure})
    : super(MSource(), '', MangayomiCodeLanguage.javascript);

  final MPages latest;
  final MPages? popular;
  final Object? latestFailure;

  @override
  Future<MPages> getPopular(int page) async {
    final result = popular;
    if (result == null) throw StateError('unavailable');
    return result;
  }

  @override
  Future<MPages> getLatestUpdates(int page) async {
    if (latestFailure case final failure?) throw failure;
    return latest;
  }
}

MangayomiProvider _provider(_FakeWorker worker) {
  final source = MangayomiSource(
    repository: Uri.parse('https://repo.example.com/index.json'),
    key: 'mg:repo:0:0:1',
    id: 1,
    name: 'Manga source',
    baseUrl: Uri.parse('https://manga.example.com'),
    codeUrl: Uri.parse('https://repo.example.com/source.js'),
    version: '1',
    contentType: MangayomiContentType.manga,
    codeLanguage: MangayomiCodeLanguage.javascript,
    language: 'en',
  );
  return MangayomiProvider(
    manager: _FakeManager(worker),
    installed: InstalledMangayomiSource(source, File('unused.js')),
  );
}

void main() {
  test(
    'Manga Home falls back to latest updates if popular is unavailable',
    () async {
      final worker = _FakeWorker(
        latest: MPages(
          list: [MManga(name: 'Latest manga', link: '/latest')],
        ),
      );
      final provider = _provider(worker);

      final sections = await provider.getHome();

      expect(sections, hasLength(1));
      expect(sections!.single.title, 'Latest');
      expect(sections.single.items.single.title, 'Latest manga');
      expect(sections.single.more?.kind, 'mg_latest');
      provider.manager.dispose();
    },
  );

  test('Mangayomi Home includes both Popular and Latest rows', () async {
    final provider = _provider(
      _FakeWorker(
        popular: MPages(
          list: [MManga(name: 'Popular manga', link: '/popular')],
        ),
        latest: MPages(
          list: [MManga(name: 'Latest manga', link: '/latest')],
        ),
      ),
    );

    final sections = await provider.getHome();

    expect(sections, hasLength(2));
    expect(sections!.map((section) => section.title), ['Popular', 'Latest']);
    expect(sections[0].items.single.title, 'Popular manga');
    expect(sections[1].items.single.title, 'Latest manga');
    expect(sections[0].more?.kind, 'mg_popular');
    expect(sections[1].more?.kind, 'mg_latest');
    provider.manager.dispose();
  });

  test('Popular remains visible when latest updates fail', () async {
    final provider = _provider(
      _FakeWorker(
        popular: MPages(
          list: [MManga(name: 'Popular manga', link: '/popular')],
        ),
        latest: MPages(list: const []),
        latestFailure: StateError('latest unavailable'),
      ),
    );

    final sections = await provider.getHome();

    expect(sections, hasLength(1));
    expect(sections!.single.title, 'Popular');
    provider.manager.dispose();
  });
}
