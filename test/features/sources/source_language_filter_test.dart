// The manga/anime catalogs gained a per-language filter (🌐 Languages). This
// proves the Mihon repo section honours the enabled set — hiding sources whose
// language is off, always showing multi-language ('all') ones, and re-filtering
// live when the set changes. The Aniyomi section shares the exact same wiring.
//
// Uses an in-memory fake MangaLangPrefs registered in GetIt so no Hive box is
// needed; the section reads `sl<MangaLangPrefs>()` and rebuilds off its
// ChangeNotifier.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/prefs/source_lang_prefs.dart';
import 'package:watch_app/features/sources/mihon_repo_tab.dart';

class _FakeMangaLangPrefs extends MangaLangPrefs {
  _FakeMangaLangPrefs(this._langs);
  Set<String>? _langs;
  @override
  Set<String>? get enabled => _langs;
  @override
  Future<void> setEnabled(Set<String> langs) async {
    _langs = langs;
    notifyListeners();
  }
}

AniyomiRepoEntry _entry(String name, String lang) => AniyomiRepoEntry(
      name: name,
      pkg: 'com.fake.${name.toLowerCase()}',
      apk: '$name-v1.apk',
      lang: lang,
      version: '1.0',
      code: 1,
      nsfw: false,
      sources: const [],
      repoBaseUrl: 'https://repo.example.com',
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  final sl = GetIt.instance;

  Future<void> pumpTab(WidgetTester tester, List<AniyomiRepoEntry> entries) async {
    await tester.pumpWidget(_wrap(
      MihonRepoTab(
        repoUrls: const ['https://repo.example.com'],
        onRemoveRepo: (_) {},
        fetchIndexFn: (_) async => entries,
        installedPkgsFn: (_) => false,
      ),
    ));
    await tester.pump(); // initState → fetch starts
    await tester.pump(); // fetch resolves
    await tester.pump(const Duration(milliseconds: 300)); // AnimatedSize settles
  }

  tearDown(() async => sl.reset());

  testWidgets('hides sources of a disabled language, keeps multi-language ones',
      (tester) async {
    sl.registerSingleton<MangaLangPrefs>(_FakeMangaLangPrefs({'en'}));

    await pumpTab(tester, [
      _entry('Alpha', 'en'), // enabled → shown
      _entry('Beta', 'es'), // disabled → hidden
      _entry('Gamma', 'all'), // multi-language → always shown
      _entry('Delta', 'pt-BR'), // region variant of a disabled base → hidden
    ]);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Delta'), findsNothing);
  });

  testWidgets('re-filters live when the enabled set changes', (tester) async {
    sl.registerSingleton<MangaLangPrefs>(_FakeMangaLangPrefs({'en'}));

    await pumpTab(tester, [_entry('Alpha', 'en'), _entry('Beta', 'es')]);
    expect(find.text('Beta'), findsNothing);

    // Enable Spanish through the same notifier the picker would use.
    await sl<MangaLangPrefs>().setEnabled({'en', 'es'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('with no prefs registered the filter is off (every entry shows)',
      (tester) async {
    // No MangaLangPrefs registered — mirrors the existing repo-tab tests, which
    // must keep asserting on the full list.
    await pumpTab(tester, [_entry('Alpha', 'en'), _entry('Beta', 'es')]);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });
}
