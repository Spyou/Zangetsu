// Task E2: My List's two EmptyStates ("Nothing here in this filter" and
// "Titles you add appear here") are watch-centric wording baked in
// regardless of content mode. Pulled the message choice out into two pure
// functions so the anime-unchanged guarantee and the reading wording are
// each a one-line assertion, no widget pump required. Widget-level
// regression coverage (actually rendered, mode-filtered) lives in
// reading_home_test.dart's MyListScreen group.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/home/my_list_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

AppLocalizations get _l10n =>
    lookupAppLocalizations(const Locale('en'));

void main() {
  group('myListFilteredEmptyMessage', () {
    test('anime mode — unchanged from today', () {
      expect(
        myListFilteredEmptyMessage(_l10n, ContentMode.anime),
        'Nothing here in this filter',
      );
    });

    test('manga mode names the content type', () {
      expect(
        myListFilteredEmptyMessage(_l10n, ContentMode.manga),
        'No manga here in this filter',
      );
    });

    test('novel mode names the content type', () {
      expect(
        myListFilteredEmptyMessage(_l10n, ContentMode.novel),
        'No novels here in this filter',
      );
    });
  });

  group('myListEmptyMessage', () {
    test('anime mode — unchanged from today', () {
      expect(
        myListEmptyMessage(_l10n, ContentMode.anime),
        'Titles you add appear here',
      );
    });

    test('manga mode', () {
      expect(
        myListEmptyMessage(_l10n, ContentMode.manga),
        'Manga you add appear here',
      );
    });

    test('novel mode', () {
      expect(
        myListEmptyMessage(_l10n, ContentMode.novel),
        'Novels you add appear here',
      );
    });
  });
}
