import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/i18n/source_languages.dart';

/// The installed list is a MANAGEMENT list — it is where you uninstall, open
/// settings and sign in. So it filters by language like everywhere else, but
/// never to the point of hiding an extension you'd then be unable to remove.

typedef Src = ({String pkg, String lang});

List<Src> filter(List<Src> items, Set<String> enabled) =>
    visibleInstalledSources(
      items,
      enabled,
      pkgOf: (s) => s.pkg,
      langOf: (s) => s.lang,
    );

void main() {
  test('a multi-language extension is narrowed to the enabled languages', () {
    // MangaDex is one package yielding one source per language. Choosing
    // English should not leave 61 rows on screen.
    final out = filter(const [
      (pkg: 'mangadex', lang: 'en'),
      (pkg: 'mangadex', lang: 'es'),
      (pkg: 'mangadex', lang: 'ja'),
    ], {'en'});

    expect(out, [const (pkg: 'mangadex', lang: 'en')]);
  });

  test('an extension with NO enabled language keeps all its rows', () {
    // The guard that matters: filtering it out of sight would leave the user
    // unable to uninstall it.
    final out = filter(const [
      (pkg: 'spanish-only', lang: 'es'),
      (pkg: 'spanish-only', lang: 'ca'),
    ], {'en'});

    expect(out.length, 2, reason: 'must stay reachable to uninstall');
  });

  test("'all' and unknown codes are never hidden", () {
    // sourceLangVisible lets these through because there is no toggle for
    // them — hiding one would be a source you cannot get back.
    final out = filter(const [
      (pkg: 'a', lang: 'all'),
      (pkg: 'b', lang: ''),
      (pkg: 'c', lang: 'xyz'),
    ], {'en'});

    expect(out.length, 3);
  });

  test('one extension being filtered does not rescue another', () {
    // The fallback is per-extension. A package that HAS an English source
    // must not also drag in its other languages.
    final out = filter(const [
      (pkg: 'mixed', lang: 'en'),
      (pkg: 'mixed', lang: 'de'),
      (pkg: 'german-only', lang: 'de'),
    ], {'en'});

    expect(out, contains(const (pkg: 'mixed', lang: 'en')));
    expect(out, isNot(contains(const (pkg: 'mixed', lang: 'de'))));
    expect(out, contains(const (pkg: 'german-only', lang: 'de')));
  });

  test('an empty enabled set still keeps every extension reachable', () {
    final out = filter(const [
      (pkg: 'a', lang: 'en'),
      (pkg: 'b', lang: 'ja'),
    ], {});

    expect(out.length, 2);
  });

  test('a language outside the built-in map is still filtered', () {
    // The reported bug. MangaDot ships mo/gn/gl/tl; none are in
    // kSourceLanguages, so the "unknown language" escape hatch showed all of
    // them however you'd set the filter. 41 codes in the real catalogue are
    // in that position, so the map was never going to be the answer — the
    // filterable set has to come from what you actually have.
    final out = filter(const [
      (pkg: 'mangadot', lang: 'en'),
      (pkg: 'mangadot', lang: 'mo'),
      (pkg: 'mangadot', lang: 'gn'),
      (pkg: 'mangadot', lang: 'tl'),
    ], {'en'});

    expect(out, [const (pkg: 'mangadot', lang: 'en')]);
  });

  test('an unknown code can be switched ON as well as off', () {
    // The other half: filtering it is only fair because the picker offers it.
    final out = filter(const [
      (pkg: 'mangadot', lang: 'en'),
      (pkg: 'mangadot', lang: 'tl'),
    ], {'en', 'tl'});

    expect(out.length, 2);
  });

  test('presentLangCodes reports what the picker must offer', () {
    expect(
      presentLangCodes(
        const [
          (pkg: 'a', lang: 'en'),
          (pkg: 'a', lang: 'pt-BR'),
          (pkg: 'b', lang: 'tl'),
          (pkg: 'c', lang: 'all'),
          (pkg: 'd', lang: ''),
        ],
        (s) => s.lang,
      ),
      // 'all' and blank are not languages you can switch off.
      {'en', 'pt', 'tl'},
    );
  });
}
