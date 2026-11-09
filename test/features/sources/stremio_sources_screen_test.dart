import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/stremio/stremio_manager.dart';
import 'package:watch_app/features/sources/stremio_sources_screen.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

class _FakeSecrets implements StremioSecretStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}

StremioInstallation _installation({
  bool streamOnly = false,
  bool enabled = true,
  int revision = 0,
}) {
  return StremioInstallation(
    id: 'stremio_1',
    name: streamOnly ? 'Streams Only' : 'Test Addon',
    version: '1.0.0',
    manifestId: 'org.test.addon',
    types: const ['movie'],
    idPrefixes: streamOnly ? const ['tt'] : const [],
    resources: streamOnly
        ? const [StremioResourceDescriptor(name: 'stream')]
        : const [
            StremioResourceDescriptor(name: 'catalog'),
            StremioResourceDescriptor(name: 'meta'),
            StremioResourceDescriptor(name: 'stream'),
            StremioResourceDescriptor(name: 'subtitles'),
          ],
    catalogs: streamOnly
        ? const []
        : const [StremioCatalog(type: 'movie', id: 'top', name: 'Top')],
    enabled: enabled,
    revision: revision,
    createdAt: 1,
    urlDigest: 'digest',
  );
}

class _FakeManager extends StremioManager {
  _FakeManager()
    : super(
        client: StremioClient(
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
        secrets: _FakeSecrets(),
      );

  final List<StremioInstallation> _items = [];

  @override
  List<StremioInstallation> get installations =>
      List<StremioInstallation>.unmodifiable(_items);

  @override
  StremioInstallation? byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<StremioInstallation> install(String rawUrl) async {
    if (rawUrl.contains('bad')) {
      throw const StremioInstallException('Addon request failed');
    }
    if (_items.any((i) => i.name == 'Test Addon')) {
      throw const StremioInstallException('addon is already installed');
    }
    final item = _installation(streamOnly: rawUrl.contains('streams'));
    _items.add(item);
    notifyListeners();
    return item;
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    final index = _items.indexWhere((i) => i.id == id);
    _items[index] = _items[index].copyWith(
      enabled: enabled,
      revision: _items[index].revision + 1,
    );
    notifyListeners();
  }

  @override
  Future<StremioInstallation> configure(String id, String rawUrl) async {
    final index = _items.indexWhere((i) => i.id == id);
    _items[index] = _items[index].copyWith(
      revision: _items[index].revision + 1,
    );
    notifyListeners();
    return _items[index];
  }

  @override
  Future<void> setCatalogVisible(
    String id,
    String type,
    String catalogId,
    bool visible,
  ) async {
    final index = _items.indexWhere((item) => item.id == id);
    _items[index] = _items[index].copyWith(
      hiddenCatalogs: visible
          ? []
          : [
              jsonEncode([type, catalogId]),
            ],
    );
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    _items.removeWhere((i) => i.id == id);
    notifyListeners();
  }

  @override
  Future<Uri?> baseUri(String id) async => Uri.parse('https://addon.example');
}

void main() {
  late _FakeManager manager;

  setUp(() {
    manager = _FakeManager();
    sl.registerSingleton<StremioManager>(manager);
  });

  tearDown(() => sl.reset());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: StremioSourcesScreen()));
    await tester.pump();
  }

  Future<void> addUrl(WidgetTester tester, String url) async {
    await tester.tap(find.text('Add addon'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('installs, enables, configures and removes an addon', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('No addons yet. Add an addon to get started.'), findsOne);

    await addUrl(tester, 'https://addon.example/manifest.json');
    expect(find.text('Test Addon'), findsOne);
    expect(find.text('1 catalogue · streams · metadata · subtitles'), findsOne);
    final installation = manager.installations.single;

    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.byId(installation.id)!.enabled, isFalse);

    await tester.tap(find.byTooltip('Update URL'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'https://b.example');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.byId(installation.id)!.revision, 2);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.installations, isEmpty);
    expect(find.text('Test Addon'), findsNothing);
  });

  testWidgets('Home rows can be hidden without disabling the addon', (
    tester,
  ) async {
    await pump(tester);
    await addUrl(tester, 'https://addon.example');
    await tester.tap(find.text('Home rows'));
    await tester.pumpAndSettle();
    final row = find.widgetWithText(SwitchListTile, 'Top · Movies');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(
      manager.installations.single.isCatalogVisible('movie', 'top'),
      isFalse,
    );
    expect(manager.installations.single.enabled, isTrue);
  });

  testWidgets('repeat add is rejected without a second row', (tester) async {
    await pump(tester);
    await addUrl(tester, 'https://addon.example/manifest.json');
    await tester.pump(const Duration(seconds: 5));
    await addUrl(tester, 'https://addon.example/manifest.json');

    expect(manager.installations, hasLength(1));
    expect(find.text('addon is already installed'), findsOne);
    expect(find.text('Test Addon'), findsOne);
  });

  testWidgets('a failed manifest shows an error and adds nothing', (
    tester,
  ) async {
    await pump(tester);
    await addUrl(tester, 'https://bad.example/manifest.json');

    expect(manager.installations, isEmpty);
    expect(find.text('Addon request failed'), findsOne);
  });

  testWidgets('stream-only addon explains it needs a catalogue addon', (
    tester,
  ) async {
    await pump(tester);
    await addUrl(tester, 'https://addon.example/streams');

    expect(find.text('Streams Only'), findsOne);
    expect(find.textContaining('add a catalogue addon to browse'), findsOne);
  });
}
