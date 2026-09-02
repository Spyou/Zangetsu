// The browser is offered per source, and a source with no site to open must
// not offer it — a screen that loads about:blank helps nobody. The URL comes
// from a different field in each ecosystem, so the lookup is worth pinning.
//
// webViewUrlFor has two return paths before it ever asks the repository:
// the Z Mode catalogue short-circuits to null, and (only when SourceRepository
// isn't in GetIt at all) a DI guard also returns null. Neither of those
// exercises SourceRepository.baseUrlFor's own empty-string-to-null
// translation, so a repository is registered here to pin that directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/repository/source_actions.dart' as source_actions;
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Minimal [SourceRepository] stub — only [baseUrlFor] is used by
/// [source_actions.webViewUrlFor], the rest just isn't called from these tests.
class _FakeSourceRepository implements SourceRepository {
  _FakeSourceRepository(this._urls);

  final Map<String, String> _urls;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  String baseUrlFor(String sourceId) => _urls[sourceId] ?? '';
}

void main() {
  tearDown(() {
    if (sl.isRegistered<SourceRepository>()) {
      sl.unregister<SourceRepository>();
    }
  });

  test('a source with no known site offers no browser', () {
    sl.registerSingleton<SourceRepository>(_FakeSourceRepository(const {}));
    expect(source_actions.webViewUrlFor('not-a-real-source'), isNull);
  });

  test('a source with a known site offers its trimmed url', () {
    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(const {'mihon:asurascans': '  https://asuracomic.net  '}),
    );
    expect(
      source_actions.webViewUrlFor('mihon:asurascans'),
      'https://asuracomic.net',
    );
  });

  test('the metadata catalogue is not a site you can log in to', () {
    // Z Mode is a catalogue, not a provider with an account. The repository
    // registered here DOES answer for 'zm', so the null can only come from the
    // Z Mode gate — drop that gate and this fails instead of quietly passing
    // on an unregistered-repository guard.
    sl.registerSingleton<SourceRepository>(
      _FakeSourceRepository(const {ZmodeIds.sourceId: 'https://zangetsu.online'}),
    );
    expect(
      source_actions.webViewUrlFor('not-zm'),
      isNull,
      reason: 'guard sanity: the fake answers for zm and nothing else',
    );
    expect(source_actions.webViewUrlFor(ZmodeIds.sourceId), isNull);
  });

  test('with no repository registered at all, offers no browser', () {
    // Only reachable in an unbootstrapped context (this test file, or a
    // screen that somehow runs before DI is set up) — the DI guard in
    // webViewUrlFor, not SourceRepository's own logic.
    expect(sl.isRegistered<SourceRepository>(), isFalse);
    expect(source_actions.webViewUrlFor('mihon:asurascans'), isNull);
  });
}
