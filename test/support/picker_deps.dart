// The Z Mode source picker is the app's shared tabbed picker
// (`SourceSwitcher.showPicker`), so any widget test that OPENS it needs the
// singletons that picker reads: the provider registry, the ecosystem managers,
// and the content mode that decides which tabs are shown.
//
// Rows come from those registries — NOT from whatever fake SourceRepository a
// test registered — so a test that wants a row in the sheet has to register a
// real provider here. [registerPickerDeps] takes the Aniyomi sources to expose
// for exactly that reason.
//
// Hive must already be initialised by the caller.
import 'package:dio/dio.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/mihon/mihon_manager.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

ActiveSourceCubit? _activeSource;
ContentModeCubit? _modeCubit;

/// Builds an Aniyomi source row for the picker. [id] must match the numeric
/// half of the `ani:<id>` source id the test asserts on.
AniyomiProvider aniSource({required int id, required String name, String lang = 'en'}) =>
    AniyomiProvider(
      info: AniyomiSourceInfo(
        id: id,
        name: name,
        lang: lang,
        baseUrl: 'https://example.test',
        pkg: 'test.pkg',
        nsfw: false,
      ),
    );

/// Builds a Mihon (manga) source row. [id] must match the numeric half of the
/// `mihon:<id>` source id the test asserts on.
MihonProvider mihonSource({required int id, required String name, String lang = 'en'}) =>
    MihonProvider(
      info: MihonSourceInfo(
        id: id,
        name: name,
        lang: lang,
        baseUrl: 'https://example.test',
        pkg: 'test.pkg',
        nsfw: false,
      ),
    );

/// Registers everything `SourceSwitcher.showPicker` needs. Call after
/// `Hive.init`, and pair with [disposePickerDeps] before `sl.reset()`.
Future<void> registerPickerDeps({
  List<AniyomiProvider> aniyomi = const [],
  List<MihonProvider> mihon = const [],
  ContentMode? mode,
}) async {
  await ProviderRegistry.init();
  await ProviderReposRegistry.init();
  await PlaybackPrefs.init();
  await CloudStreamManager.init();

  sl.registerSingleton<ProviderRegistry>(
    ProviderRegistry(
      downloader: _FakeFetcher(),
      manager: _FakeManager(),
      repos: ProviderReposRegistry(dio: Dio()),
    ),
  );
  sl.registerSingleton<ProviderReposRegistry>(ProviderReposRegistry(dio: Dio()));
  sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  sl.registerSingleton<CloudStreamManager>(CloudStreamManager());

  final aniManager = AniyomiManager();
  if (aniyomi.isNotEmpty) aniManager.registerAll(aniyomi);
  sl.registerSingleton<AniyomiManager>(aniManager);
  if (mihon.isNotEmpty) {
    final mihonManager = MihonManager()..registerAll(mihon);
    sl.registerSingleton<MihonManager>(mihonManager);
  }
  sl.registerSingleton<AppMode>(const AppMode(isTv: false));

  // Seed the mode BEFORE the cubit reads it. Calling setMode afterwards would
  // work too, but its persistence is fire-and-forget and the pending write
  // leaks a timer past the end of a pump-driven test.
  if (mode != null) {
    final modeBox = await openBoxSafely('content_mode');
    await modeBox.put('mode', mode.name);
  }
  _activeSource = ActiveSourceCubit();
  _modeCubit = await ContentModeCubit.create(_activeSource!);
  sl.registerSingleton<ActiveSourceCubit>(_activeSource!);
  sl.registerSingleton<ContentModeCubit>(_modeCubit!);
}

Future<void> disposePickerDeps() async {
  await _modeCubit?.close();
  await _activeSource?.close();
  _modeCubit = null;
  _activeSource = null;
}
