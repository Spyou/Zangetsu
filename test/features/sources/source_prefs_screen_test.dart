// The app now draws an extension's own settings instead of launching the
// extension's native screen. What matters here is that a row only moves once
// the SOURCE has accepted the change: a source can refuse (its change listener
// returns false), and a switch showing a state the source never took is worse
// than no switch at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/source_pref.dart';
import 'package:watch_app/features/sources/source_prefs_screen.dart';

void main() {
  final writes = <(String, Object?)>[];
  late bool accept;
  var nativeOpened = 0;

  Future<bool> write(String key, Object? value) async {
    writes.add((key, value));
    return accept;
  }

  setUp(() {
    writes.clear();
    accept = true;
    nativeOpened = 0;
  });

  Widget harness(List<SourcePref> prefs, {bool leftovers = false}) => MaterialApp(
    home: SourcePrefsScreen(
      title: 'AnimeWorld',
      prefs: prefs,
      write: write,
      onOpenNative: leftovers
          ? () async {
              nativeOpened++;
            }
          : null,
    ),
  );

  const toggle = SourcePref(
    key: 'pref_dub',
    type: SourcePrefType.switchToggle,
    title: 'Prefer dubbed',
    summary: 'Pick the dub when there is one',
    value: false,
  );
  const lang = SourcePref(
    key: 'lang',
    type: SourcePrefType.list,
    title: 'Language',
    value: 'en',
    entries: ['English', 'Español'],
    values: ['en', 'es'],
  );
  const domain = SourcePref(
    key: 'domain',
    type: SourcePrefType.text,
    title: 'Domain',
    value: 'https://a.test',
  );

  testWidgets('draws each kind with its current value', (t) async {
    await t.pumpWidget(harness([toggle, lang, domain]));
    await t.pumpAndSettle();

    expect(find.text('AnimeWorld'), findsOneWidget);
    expect(find.text('Prefer dubbed'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    // The label, not the stored value.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('https://a.test'), findsOneWidget);
  });

  testWidgets('flipping a switch writes that key and value', (t) async {
    await t.pumpWidget(harness([toggle]));
    await t.pumpAndSettle();

    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();

    expect(writes, [('pref_dub', true)]);
  });

  testWidgets('a source that refuses leaves the row where it was', (t) async {
    accept = false;
    await t.pumpWidget(harness([toggle]));
    await t.pumpAndSettle();

    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();

    expect(writes, [('pref_dub', true)]); // it was attempted
    final s = t.widget<Switch>(find.byType(Switch));
    expect(s.value, isFalse); // …and not shown as taken
    // The refusal shows a toast, which holds a timer past the test body.
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('picking from a list writes the stored value, not the label',
      (t) async {
    await t.pumpWidget(harness([lang]));
    await t.pumpAndSettle();

    await t.tap(find.text('Language'));
    await t.pumpAndSettle();
    await t.tap(find.text('Español'));
    await t.pumpAndSettle();

    expect(writes, [('lang', 'es')]);
    // The row now shows the new label.
    expect(find.text('Español'), findsOneWidget);
  });

  testWidgets('a kind we cannot draw is not drawn, but is still reachable',
      (t) async {
    // Half a page is fine as long as the rest has a door. Drawing nothing for
    // an odd setting AND offering no way to it is what would hide it.
    const odd = SourcePref(
      key: 'seek',
      type: SourcePrefType.unknown,
      title: 'Some slider',
    );
    await t.pumpWidget(harness([toggle, odd], leftovers: true));
    await t.pumpAndSettle();

    expect(find.text('Prefer dubbed'), findsOneWidget);
    expect(find.text('Some slider'), findsNothing);
    // Not merely invisible: it must not take a slot either. SettingsCard draws
    // a divider between children, so a blank row left in the list shows up as
    // a stray line under the only real one.
    expect(find.byType(Divider), findsNothing);

    await t.tap(find.text('Other settings').last);
    await t.pumpAndSettle();

    expect(nativeOpened, 1);
  });

  testWidgets('a page with nothing left over offers no extra row', (t) async {
    await t.pumpWidget(harness([toggle]));
    await t.pumpAndSettle();
    expect(find.text('Other settings'), findsNothing);
  });

  testWidgets('a multi-select writes the whole set once, on save', (t) async {
    // Not per tap: each write fires the source's change listener, and a source
    // that rebuilds something on change would do it once per box.
    const servers = SourcePref(
      key: 'servers',
      type: SourcePrefType.multi,
      title: 'Servers',
      value: <String>['a'],
      entries: ['A', 'B'],
      values: ['a', 'b'],
    );
    await t.pumpWidget(harness([servers]));
    await t.pumpAndSettle();

    await t.tap(find.text('Servers'));
    await t.pumpAndSettle();
    await t.tap(find.text('B'));
    await t.pumpAndSettle();
    expect(writes, isEmpty); // nothing yet

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(writes.length, 1);
    expect(writes.single.$1, 'servers');
    expect((writes.single.$2! as List).toSet(), {'a', 'b'});
  });
}
