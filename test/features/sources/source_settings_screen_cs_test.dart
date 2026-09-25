import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/repository/provider_settings_repository.dart';
import 'package:watch_app/features/sources/source_settings_screen.dart';

class _StubDownloader implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) =>
      throw UnimplementedError('must not fetch for a cs: source');

  @override
  Future<void> remove(String name) async {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cs_settings_screen');
    Hive.init(dir.path);
    await ProviderRegistry.init();
    await ProviderSettingsRepository.init();
    final sl = GetIt.instance;
    final manager = ProviderManager(dio: Dio());
    sl
      ..registerSingleton<ProviderManager>(manager)
      ..registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _StubDownloader(), manager: manager),
      )
      ..registerSingleton<ProviderSettingsRepository>(
        ProviderSettingsRepository(),
      );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  testWidgets('a CloudStream source without a JS schema shows the '
      'no-settings state instead of an error', (tester) async {
    // `cs:` sources live natively, not in the JS runtime, so there is no
    // JS schema to load. The screen must not report "Could not load
    // settings" — it should fall through to the native/no-settings state.
    await tester.pumpWidget(
      const MaterialApp(
        home: SourceSettingsScreen(sourceId: 'cs:Missing', repoUrl: ''),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load settings'), findsNothing);
    expect(find.text('This source has no settings'), findsOneWidget);
  });
}
