import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/tv/tv_text_field.dart';
import 'package:watch_app/core/tv/tv_alert_dialog.dart';
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
  String id = 'stremio_1',
  bool streamOnly = false,
  bool enabled = true,
  int revision = 0,
}) {
  return StremioInstallation(
    id: id,
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
  final moves = <(String, int)>[];
  Completer<void>? moveGate;

  @override
  Future<void> move(String id, int delta) async {
    moves.add((id, delta));
    await moveGate?.future;
    final index = _items.indexWhere((item) => item.id == id);
    final item = _items.removeAt(index);
    _items.insert(index + delta, item);
    notifyListeners();
  }

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

  Future<void> pumpTv(WidgetTester tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester);
    await tester.pumpAndSettle();
  }

  Future<FocusNode> focusControl(WidgetTester tester, Finder control) async {
    await tester.ensureVisible(control);
    await tester.pumpAndSettle();
    final focus = tester.widget<Focus>(
      find.descendant(of: control, matching: find.byType(Focus)).first,
    );
    final node = Focus.of(tester.element(find.byWidget(focus.child).first));
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    return node;
  }

  testWidgets('TV URL entry does not trap remote navigation in the keyboard', (
    tester,
  ) async {
    await pumpTv(tester);
    expect(find.byType(TvTextField), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    final originalFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(originalFocus)));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(originalFocus));
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'TV remote reorders the focused addon and keeps its action focused',
    (tester) async {
      manager._items.addAll([
        _installation(id: 'first'),
        _installation(id: 'second'),
        _installation(id: 'third'),
      ]);
      await pumpTv(tester);
      manager.moveGate = Completer<void>();
      final down = find.descendant(
        of: find.byKey(const ValueKey('tv-stremio-addon:first')),
        matching: find.byTooltip('Move down'),
      );
      final focus = await focusControl(tester, down);
      final theme = IconButtonTheme.of(tester.element(down));
      expect(
        theme.style!.backgroundColor!.resolve({WidgetState.focused}),
        Colors.white,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(of: down, matching: find.byType(IconButton)).first,
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(manager.moves, [('first', 1)]);
      manager.moveGate!.complete();
      await tester.pumpAndSettle();
      expect(manager.moves, [('first', 1)]);
      expect(manager.installations.map((item) => item.id), [
        'second',
        'first',
        'third',
      ]);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      final up = find.descendant(
        of: find.byKey(const ValueKey('tv-stremio-addon:first')),
        matching: find.byTooltip('Move up'),
      );
      final upFocus = await focusControl(tester, up);
      manager.moveGate = Completer<void>();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      manager.moveGate!.complete();
      await tester.pumpAndSettle();
      expect(manager.moves, [('first', 1), ('first', -1)]);
      expect(manager.installations.first.id, 'first');
      expect(upFocus.hasFocus, isFalse);
      Key? focusedCard;
      FocusManager.instance.primaryFocus!.context!.visitAncestorElements((
        element,
      ) {
        if (element.widget is Card) {
          focusedCard = element.widget.key;
          return false;
        }
        return true;
      });
      expect(focusedCard, const ValueKey('tv-stremio-addon:first'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV filter tabs respond to remote arrows and Select', (
    tester,
  ) async {
    manager._items.add(_installation(streamOnly: true));
    await pumpTv(tester);
    await focusControl(tester, find.widgetWithText(ChoiceChip, 'All'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final tab = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Catalogues'),
    );
    expect(tab.selected, isTrue);
    expect(
      (tab.side as WidgetStateBorderSide).resolve({WidgetState.focused}),
      const BorderSide(color: Colors.white, width: 2),
    );
    expect(find.text('Streams Only'), findsNothing);
    expect(manager.installations, hasLength(1));
  });

  testWidgets(
    'TV install returns focus to URL navigation without opening the keyboard',
    (tester) async {
      await pumpTv(tester);
      final input = tester.widget<TvTextField>(find.byType(TvTextField));
      input.controller!.text = 'https://addon.example/manifest.json';
      await tester.pumpAndSettle();
      await focusControl(
        tester,
        find.widgetWithText(FilledButton, 'Install Addon'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(manager.installations, hasLength(1));
      expect(input.controller!.text, isEmpty);
      expect(FocusManager.instance.primaryFocus, same(input.focusNode));
      expect(tester.testTextInput.isVisible, isFalse);
    },
  );

  testWidgets(
    'TV remote toggles addons and Home rows without touching other settings',
    (tester) async {
      manager._items.add(_installation());
      await pumpTv(tester);
      await focusControl(tester, find.byType(Switch));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(manager.installations.single.enabled, isFalse);
      await focusControl(tester, find.byType(ExpansionTile));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await focusControl(tester, find.byType(SwitchListTile));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        manager.installations.single.isCatalogVisible('movie', 'top'),
        isFalse,
      );
      expect(manager.installations.single.enabled, isFalse);
    },
  );

  testWidgets(
    'TV update dialog uses remote-friendly URL entry and saves normally',
    (tester) async {
      manager._items.add(_installation());
      await pumpTv(tester);
      await focusControl(tester, find.byTooltip('Update URL'));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(TvAlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TvAlertDialog),
          matching: find.byType(TvTextField),
        ),
        findsOneWidget,
      );
      final field = tester.widget<TvTextField>(
        find.descendant(
          of: find.byType(TvAlertDialog),
          matching: find.byType(TvTextField),
        ),
      );
      field.controller!.text = 'https://updated.example/manifest.json';
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(manager.installations.single.revision, 1);
      expect(find.byType(TvAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV remove dialog starts on Cancel and supports remote confirmation',
    (tester) async {
      manager._items.add(_installation());
      await pumpTv(tester);
      await focusControl(tester, find.byTooltip('Remove'));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(TvAlertDialog), findsOneWidget);
      expect(manager.installations, hasLength(1));
      expect(FocusManager.instance.primaryFocus!.debugLabel, 'tv-alert-Cancel');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(manager.installations, isEmpty);
    },
  );

  Future<void> addUrl(WidgetTester tester, String url) async {
    await tester.ensureVisible(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), url);
    await tester.pump();
    await tester.ensureVisible(find.text('Install Addon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install Addon'));
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('shows overview and disables install for an empty URL', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Stremio Addons'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Installed Addons'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Install Addon'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Install Addon'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('rounded text-only tabs preserve addon filtering', (
    tester,
  ) async {
    manager._items.add(_installation(streamOnly: true));
    await pump(tester);
    final allTab = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'All'),
    );
    expect(allTab.showCheckmark, isFalse);
    expect(allTab.shape, isA<StadiumBorder>());
    expect(allTab.selected, isTrue);

    final catalogues = find.widgetWithText(ChoiceChip, 'Catalogues');
    await tester.ensureVisible(catalogues);
    await tester.pumpAndSettle();
    await tester.tap(catalogues);
    await tester.pumpAndSettle();
    expect(find.text('Streams Only'), findsNothing);
    expect(tester.widget<ChoiceChip>(catalogues).selected, isTrue);
    expect(manager.installations, hasLength(1));

    final streams = find.widgetWithText(ChoiceChip, 'Streams');
    await tester.ensureVisible(streams);
    await tester.pumpAndSettle();
    await tester.tap(streams);
    await tester.pumpAndSettle();
    expect(find.text('Streams Only'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(streams).selected, isTrue);
  });

  testWidgets('cards and actions fit a narrow phone with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    manager._items.add(_installation());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const StremioSourcesScreen(),
      ),
    );
    await tester.ensureVisible(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Version 1.0.0'), findsOneWidget);
    await tester.tap(find.byTooltip('Update URL'));
    await tester.pumpAndSettle();
    expect(find.text('Update Test Addon'), findsOneWidget);
  });

  testWidgets('installs, enables, configures and removes an addon', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('No addons yet. Add an addon to get started.'), findsOne);

    await addUrl(tester, 'https://addon.example/manifest.json');
    expect(find.text('Test Addon'), findsOne);
    expect(find.text('1 catalogue · streams · metadata · subtitles'), findsOne);
    final installation = manager.installations.single;

    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.byId(installation.id)!.enabled, isFalse);

    await tester.ensureVisible(find.byTooltip('Update URL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Update URL'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'https://b.example');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.byId(installation.id)!.revision, 2);

    await tester.ensureVisible(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(find.text('Home rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home rows'));
    await tester.pumpAndSettle();
    final row = find.widgetWithText(SwitchListTile, 'Top · Movies');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
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
