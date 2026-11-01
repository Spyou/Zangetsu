import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/sources/source_health_screen.dart';

class _Repository implements SourceRepository {
  @override
  List<({String id, String name})> get loadedSources => [
    for (var i = 0; i < 30; i++) (id: 'source-$i', name: 'Source $i'),
  ];

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async => (items: <MediaItem>[], outcome: SourceOutcome.empty);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchPrefs implements SearchSourcePrefs {
  @override
  bool isIncluded(String id) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    sl.registerSingleton<SourceRepository>(_Repository());
    sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
    sl.registerSingleton<SearchSourcePrefs>(_SearchPrefs());
  });

  tearDown(() => sl.reset());

  testWidgets('TV remote scrolls through results without action buttons', (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    await tester.pumpWidget(const MaterialApp(home: SourceHealthScreen()));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    for (var i = 0; i < 29; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(scroll.position.pixels, greaterThan(0));
    expect(find.text('Source 29').hitTestable(), findsOneWidget);
    for (var i = 0; i < 29; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(find.text('Source 0').hitTestable(), findsOneWidget);
  });

  testWidgets('phone keeps touch scrolling without TV row focus', (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(const MaterialApp(home: SourceHealthScreen()));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.text('Source 0'),
        matching: find.byType(TvFocusable),
      ),
      findsNothing,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.pixels, greaterThan(0));
  });
}
