// The per-source filter icon (search_screen.dart's control row +
// section headers) must show for both `ani:` (Aniyomi) and `mihon:` (Mihon)
// sources, routed to the right sheet, and stay hidden for anything else
// (`cs:`, unprefixed Zangetsu ids). sourceFilterEcosystemOf is pulled out as
// its own top-level function (same pattern as searchFilterSections /
// searchTypeAudioGroupsVisible) so the routing decision is testable without
// pumping the sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/home/search_screen.dart';

void main() {
  group('sourceFilterEcosystemOf', () {
    test('ani: sources route to Aniyomi', () {
      expect(sourceFilterEcosystemOf('ani:1'), SourceFilterEcosystem.aniyomi);
    });

    test('mihon: sources route to Mihon', () {
      expect(sourceFilterEcosystemOf('mihon:1'), SourceFilterEcosystem.mihon);
    });

    test('cs: sources have no per-source filter sheet', () {
      expect(sourceFilterEcosystemOf('cs:1'), isNull);
    });

    test('unprefixed (Zangetsu) sources have no per-source filter sheet', () {
      expect(sourceFilterEcosystemOf('some-js-source'), isNull);
    });
  });
}
