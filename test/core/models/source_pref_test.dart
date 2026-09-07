// An Aniyomi/Mihon source declares its settings the Android way, and the native
// bridge hands that over as plain maps. This is the parse of those maps.
//
// The rule that matters: anything we cannot draw faithfully must come back as
// `unknown`, because one unknown sends the WHOLE page to the extension's own
// screen. Guessing instead would silently drop a setting the user needs, and
// leave it unreachable.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/source_pref.dart';

void main() {
  test('a switch carries its bool', () {
    final p = SourcePref.fromMap({
      'key': 'pref_dub',
      'type': 'switch',
      'title': 'Prefer dubbed',
      'summary': 'Pick the dub when there is one',
      'value': true,
    });
    expect(p.type, SourcePrefType.switchToggle);
    expect(p.asBool, isTrue);
    expect(p.title, 'Prefer dubbed');
    expect(p.summary, 'Pick the dub when there is one');
  });

  test('a checkbox stays a checkbox, not a switch', () {
    // The source asked for a checkbox; drawing a switch would be a different
    // control from the one it declared.
    final p = SourcePref.fromMap({
      'key': 'k',
      'type': 'checkbox',
      'title': 'T',
      'value': false,
    });
    expect(p.type, SourcePrefType.checkbox);
    expect(p.asBool, isFalse);
  });

  test('a list keeps its labels and its stored value apart', () {
    // Sources store a value ('en') but must show a label ('English').
    final p = SourcePref.fromMap({
      'key': 'lang',
      'type': 'list',
      'title': 'Language',
      'value': 'en',
      'entries': ['English', 'Español'],
      'values': ['en', 'es'],
    });
    expect(p.type, SourcePrefType.list);
    expect(p.asText, 'en');
    expect(p.selectedEntry, 'English');
  });

  test('a list whose stored value is not in the list shows no label', () {
    final p = SourcePref.fromMap({
      'key': 'lang',
      'type': 'list',
      'title': 'Language',
      'value': 'zz',
      'entries': ['English'],
      'values': ['en'],
    });
    expect(p.selectedEntry, '');
  });

  test('a multi-select carries a list of values', () {
    final p = SourcePref.fromMap({
      'key': 'servers',
      'type': 'multi',
      'title': 'Servers',
      'value': ['a', 'b'],
      'entries': ['A', 'B', 'C'],
      'values': ['a', 'b', 'c'],
    });
    expect(p.type, SourcePrefType.multi);
    expect(p.asList, ['a', 'b']);
  });

  test('a text pref carries its string', () {
    final p = SourcePref.fromMap({
      'key': 'domain',
      'type': 'text',
      'title': 'Domain',
      'value': 'https://example.test',
    });
    expect(p.type, SourcePrefType.text);
    expect(p.asText, 'https://example.test');
  });

  group('what must come back unknown', () {
    test('a kind we do not draw', () {
      final p = SourcePref.fromMap({
        'key': 'k',
        'type': 'seekbar',
        'title': 'T',
      });
      expect(p.type, SourcePrefType.unknown);
    });

    test('a pref with no key, however well we could draw it', () {
      // Nothing to write back to, so it is as good as undrawable.
      final p = SourcePref.fromMap({
        'type': 'switch',
        'title': 'T',
        'value': true,
      });
      expect(p.type, SourcePrefType.unknown);
    });

    test('junk instead of a map entry', () {
      final p = SourcePref.fromMap({'key': 1, 'type': 2});
      expect(p.type, SourcePrefType.unknown);
    });
  });

  group('what the page can do with an odd setting', () {
    const ok = SourcePref(
      key: 'a',
      type: SourcePrefType.switchToggle,
      title: 'A',
      value: true,
    );
    const odd = SourcePref(key: 'b', type: SourcePrefType.unknown, title: 'B');

    test('a page we fully understand is ours, with nothing left over', () {
      expect(SourcePref.canDrawAny([ok, ok]), isTrue);
      expect(SourcePref.hasUndrawable([ok, ok]), isFalse);
    });

    test('a mixed page is still ours, and says so', () {
      // The rows we know render here; the odd one is reached through the row
      // hasUndrawable turns on. Dropping it silently would leave a setting
      // invisible AND unreachable.
      expect(SourcePref.canDrawAny([ok, odd]), isTrue);
      expect(SourcePref.hasUndrawable([ok, odd]), isTrue);
    });

    test('a page with nothing drawable goes to the native screen', () {
      expect(SourcePref.canDrawAny([odd]), isFalse);
    });

    test('a failed read goes there too', () {
      expect(SourcePref.canDrawAny(null), isFalse);
    });

    test('an empty page falls back rather than showing nothing', () {
      // hasSourceSettings said yes, so an empty list means we misread it.
      expect(SourcePref.canDrawAny(const []), isFalse);
    });
  });

  group('listFrom', () {
    test('parses a channel reply', () {
      final list = SourcePref.listFrom([
        {'key': 'a', 'type': 'switch', 'title': 'A', 'value': true},
        {'key': 'b', 'type': 'text', 'title': 'B', 'value': 'x'},
      ]);
      expect(list.length, 2);
      expect(list.first.type, SourcePrefType.switchToggle);
    });

    test('a null or wrong-shaped reply is empty, never a throw', () {
      expect(SourcePref.listFrom(null), isEmpty);
      expect(SourcePref.listFrom('nonsense'), isEmpty);
    });

    test('skips non-map entries instead of failing the whole page', () {
      expect(SourcePref.listFrom([
        'junk',
        {'key': 'a', 'type': 'switch', 'title': 'A', 'value': false},
      ]).length, 1);
    });
  });
}
