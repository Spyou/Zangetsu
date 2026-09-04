import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/features/search/browse_sources_list.dart';

import '../../support/picker_deps.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_list');
    Hive.init(dir.path);
    await registerPickerDeps(
      aniyomi: [aniSource(id: 1, name: 'HiAnime')],
    );
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('lists installed sources and reports the one tapped', (t) async {
    String? tappedId;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (id, _) => tappedId = id),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);

    await t.tap(find.textContaining('HiAnime'));
    await t.pumpAndSettle();
    expect(tappedId, 'ani:1');
  });

  // This list is the Sources TAB, so the shell's floating dock is drawn over
  // it and its height reaches the list as a bottom inset. A ListView with an
  // explicit padding opts out of absorbing that, so the padding has to add it
  // back — otherwise the last source sits under the dock with no way to
  // scroll it clear.
  testWidgets('the list clears the dock inset', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(bottom: 104)),
            child: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final list = t.widget<ListView>(find.byType(ListView).first);
    expect(
      (list.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(104.0),
      reason: 'the last source must scroll clear of the dock',
    );
  });

  testWidgets('says so when nothing is installed', (t) async {
    await sl.reset();
    await registerPickerDeps();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsNothing);
    expect(find.text('No sources installed'), findsOneWidget);
  });

  testWidgets('query narrows the rows by source name', (t) async {
    await sl.reset();
    await registerPickerDeps(
      aniyomi: [
        aniSource(id: 1, name: 'HiAnime'),
        aniSource(id: 2, name: 'AllAnime'),
      ],
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'hi')),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsOneWidget);
    expect(find.textContaining('AllAnime'), findsNothing);
  });

  testWidgets('a query nothing matches shows the no-matches state, not '
      'the nothing-installed one', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrowseSourcesList(onBrowse: (_, _) {}, query: 'zzz-nope'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsNothing);
    expect(find.text('No matches found'), findsOneWidget);
    expect(find.text('No sources installed'), findsNothing);
  });

}
