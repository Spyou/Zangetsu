import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/aniyomi/aniyomi_update.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/features/sources/sources_screen.dart';

AniyomiProvider _prov() => AniyomiProvider(
      info: const AniyomiSourceInfo(
        id: 1, name: 'HiAnime', lang: 'en', baseUrl: '',
        pkg: 'p.hianime', nsfw: false, version: '1.4.20', versionCode: 20,
      ),
    );

AniyomiUpdate _upd() => AniyomiUpdate(
      pkg: 'p.hianime', name: 'HiAnime', installedCode: 20, availableCode: 21,
      availableVersion: '1.4.21',
      entry: AniyomiRepoEntry(
        name: 'HiAnime', pkg: 'p.hianime', apk: 'x.apk', lang: 'en',
        version: '1.4.21', code: 21, nsfw: false, sources: const [],
        repoBaseUrl: 'https://r/x',
      ),
    );

void main() {
  Widget host(Widget child) => MaterialApp(
        home: BlocProvider(
          create: (_) => ActiveSourceCubit(),
          child: Scaffold(body: child),
        ),
      );

  testWidgets('no Update button when there is no update', (t) async {
    await t.pumpWidget(host(debugAniSourceRow(
      source: _prov(), activeId: 'ani:1',
      updateLookupFn: (_) => null,
    )));
    expect(find.textContaining('Update'), findsNothing);
  });

  testWidgets('shows Update button and applies on tap', (t) async {
    var applied = false;
    await t.pumpWidget(host(debugAniSourceRow(
      source: _prov(), activeId: 'ani:1',
      updateLookupFn: (pkg) => pkg == 'p.hianime' ? _upd() : null,
      applyUpdateFn: (u) async => applied = true,
    )));
    expect(find.text('Update → v1.4.21'), findsOneWidget);
    await t.tap(find.text('Update → v1.4.21'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(applied, isTrue);
  });
}
