import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/features/search/browse_sources_screen.dart';
import 'package:watch_app/features/search/browse_sources_screen_tv.dart';

class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  Map<String, String> typeMapOf() => const {};
}

class _FakePlaybackPrefs extends PlaybackPrefs {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get nsfwSources => false;

  @override
  bool get showNsfwAniyomi => false;
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<CloudStreamProvider> get enabled => const [];
}

class _FakeAniyomiManager implements AniyomiManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<BaseProvider> get all => const [];
}

void main() {
  setUp(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    if (sl.isRegistered<ProviderRegistry>()) sl.unregister<ProviderRegistry>();
    if (sl.isRegistered<PlaybackPrefs>()) sl.unregister<PlaybackPrefs>();
    if (sl.isRegistered<CloudStreamManager>()) {
      sl.unregister<CloudStreamManager>();
    }
    if (sl.isRegistered<AniyomiManager>()) sl.unregister<AniyomiManager>();

    sl.registerSingleton<AppMode>(AppMode(isTv: true));
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<PlaybackPrefs>(_FakePlaybackPrefs());
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<AniyomiManager>(_FakeAniyomiManager());
  });

  tearDown(() {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    if (sl.isRegistered<ProviderRegistry>()) sl.unregister<ProviderRegistry>();
    if (sl.isRegistered<PlaybackPrefs>()) sl.unregister<PlaybackPrefs>();
    if (sl.isRegistered<CloudStreamManager>()) {
      sl.unregister<CloudStreamManager>();
    }
    if (sl.isRegistered<AniyomiManager>()) sl.unregister<AniyomiManager>();
  });

  testWidgets('BrowseSourcesScreen routes to BrowseSourcesScreenTv on TV', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: BrowseSourcesScreen()),
    );
    await tester.pump();

    expect(find.byType(BrowseSourcesScreenTv), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-sources-tab-0')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
