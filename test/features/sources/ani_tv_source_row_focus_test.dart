// On TV the settings gear sat INSIDE the row's own focusable. Directional
// D-pad traversal picks its next target by geometry, and a widget nested
// inside the current one is never "to the right of" it — so the remote could
// reach the row and never the gear, and source settings were unreachable on TV
// entirely. The two have to be siblings.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/tv/tv_list_focusable.dart';
import 'package:watch_app/features/sources/aniyomi_sources_screen.dart';

AniyomiProvider _prov() => AniyomiProvider(
  info: const AniyomiSourceInfo(
    id: 1,
    name: 'Anikoto',
    lang: 'en',
    baseUrl: '',
    pkg: 'p.anikoto',
    nsfw: false,
    version: '1.0',
    versionCode: 1,
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
    home: BlocProvider(
      create: (_) => ActiveSourceCubit(),
      child: Scaffold(body: child),
    ),
  );

  testWidgets('the gear is its own focusable, not nested in the row',
      (t) async {
    await t.pumpWidget(host(
      debugAniTvSourceRow(source: _prov(), activeId: 'ani:1'),
    ));
    await t.pump();

    final focusables = find.byType(TvListFocusable);
    expect(focusables, findsNWidgets(2)); // the row, and the gear

    // The one that matters: neither contains the other. A gear inside the row
    // is a gear the D-pad cannot land on.
    final gear = find.ancestor(
      of: find.byIcon(Icons.tune_rounded),
      matching: find.byType(TvListFocusable),
    );
    expect(gear, findsOneWidget);
    expect(
      find.descendant(of: gear, matching: find.text('Anikoto')),
      findsNothing,
    );
    final row = find.ancestor(
      of: find.text('Anikoto'),
      matching: find.byType(TvListFocusable),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.tune_rounded)),
      findsNothing,
    );
  });

  testWidgets('a source with no settings shows only the row', (t) async {
    await t.pumpWidget(host(
      debugAniTvSourceRow(source: _prov(), activeId: 'ani:1', hasSettings: false),
    ));
    await t.pump();

    expect(find.byType(TvListFocusable), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
  });
}
