import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/sources/aniyomi_sources_screen.dart';
import 'package:watch_app/features/sources/cloudstream_sources_screen.dart';
import 'package:watch_app/features/sources/lnreader_sources_screen.dart';
import 'package:watch_app/features/sources/manage_source_route.dart';
import 'package:watch_app/features/sources/mihon_sources_screen.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

/// The health screen offers "uninstall" by sending the user to the screen that
/// owns the source. Sending them to the WRONG one is the failure that matters:
/// they arrive somewhere the source isn't listed and conclude the app is
/// broken. These pin each prefix to its screen.
void main() {
  group('each id family goes to its own screen', () {
    test('cs: → CloudStream', () {
      expect(manageSourceScreenFor('cs:foo'), isA<CloudStreamSourcesScreen>());
    });

    test('ani: → Aniyomi', () {
      expect(manageSourceScreenFor('ani:12'), isA<AniyomiSourcesScreen>());
    });

    test('mihon: → Mihon', () {
      expect(manageSourceScreenFor('mihon:12'), isA<MihonSourcesScreen>());
    });

    test('lnr: → LNReader', () {
      expect(manageSourceScreenFor('lnr:x'), isA<LnReaderSourcesScreen>());
    });

    test('an unprefixed id is a JS provider → Zangetsu', () {
      // JS provider ids carry no prefix, so this is the fallback. If a new
      // ecosystem ever ships an unprefixed id it would land here wrongly —
      // which is exactly why the prefixes above are pinned.
      expect(manageSourceScreenFor('hianime'), isA<ZangetsuSourcesScreen>());
    });
  });

  group('what cannot be managed', () {
    test('Z-Mode has nothing installed behind it', () {
      // A meta-source that resolves across the others. Offering "uninstall"
      // would promise something no screen can do.
      expect(canManageSource('zm'), isFalse);
    });

    test('an empty id is refused rather than routed', () {
      expect(canManageSource(''), isFalse);
    });

    test('everything real is manageable', () {
      for (final id in ['cs:a', 'ani:1', 'mihon:1', 'lnr:a', 'hianime']) {
        expect(canManageSource(id), isTrue, reason: id);
      }
    });
  });

  test('a mihon id is not mistaken for a plain one', () {
    // 'mihon:' must be checked before the unprefixed fallback, or every Mihon
    // source would route to the Zangetsu screen.
    expect(
      manageSourceScreenFor('mihon:9'),
      isNot(isA<ZangetsuSourcesScreen>()),
    );
  });
}
