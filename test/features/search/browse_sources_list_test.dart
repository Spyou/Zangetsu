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

  testWidgets('says so when nothing is installed', (t) async {
    await sl.reset();
    await registerPickerDeps();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseSourcesList(onBrowse: (_, _) {})),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('HiAnime'), findsNothing);
  });
}
