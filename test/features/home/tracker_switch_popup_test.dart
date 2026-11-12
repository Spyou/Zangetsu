import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/features/home/tracker_switch_popup.dart';

class _FakeTracker extends ChangeNotifier implements Tracker {
  _FakeTracker(this._name, {this.viewerName, this.viewerAvatar});

  @override
  final String? viewerName;
  @override
  final String? viewerAvatar;

  final String _name;

  @override
  String get displayName => _name;

  // Only displayName is read by the popup; everything else would throw if
  // touched, which is exactly what a misuse would deserve.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _open(
  WidgetTester t, {
  Tracker? current,
  String? ownAvatarUrl,
  String? ownName,
  required List<Tracker> trackers,
  required ValueChanged<Tracker?> onPick,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTrackerSwitchPopup(
              context,
              current: current,
              ownAvatarUrl: ownAvatarUrl,
              ownName: ownName,
              trackers: trackers,
              onPick: onPick,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  group('showTrackerSwitchPopup', () {
    testWidgets('lists My List plus trackers and picks one', (t) async {
      final a = _FakeTracker('AniList');
      final b = _FakeTracker('MAL');
      var fired = false;
      Tracker? picked;
      await _open(
        t,
        trackers: [a, b],
        onPick: (tracker) {
          fired = true;
          picked = tracker;
        },
      );
      expect(find.text('Zangetsu List'), findsOneWidget);
      expect(find.text('AniList'), findsOneWidget);
      expect(find.text('MAL'), findsOneWidget);

      await t.tap(find.text('MAL'));
      await t.pumpAndSettle();
      expect(fired, isTrue);
      expect(picked, same(b));
      // Dismissed after picking.
      expect(find.text('MAL'), findsNothing);
    });

    testWidgets('My List pick reports null', (t) async {
      final a = _FakeTracker('AniList');
      var fired = false;
      Tracker? picked = a;
      await _open(
        t,
        current: a,
        trackers: [a],
        onPick: (tracker) {
          fired = true;
          picked = tracker;
        },
      );
      await t.tap(find.text('Zangetsu List'));
      await t.pumpAndSettle();
      expect(fired, isTrue);
      expect(picked, isNull);
    });

    testWidgets('shows rounded account avatars and usernames', (t) async {
      final a = _FakeTracker(
        'AniList',
        viewerName: 'anime-fan',
        viewerAvatar: 'https://example.com/al.png',
      );
      await _open(
        t,
        trackers: [a],
        ownName: 'Krishna',
        ownAvatarUrl: 'https://example.com/me.png',
        onPick: (_) {},
      );
      expect(find.text('Krishna'), findsOneWidget);
      expect(find.text('anime-fan'), findsOneWidget);
      expect(find.byType(ClipOval), findsNWidgets(2));
      expect(
        t
            .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .map((w) => w.imageUrl),
        containsAll([
          'https://example.com/me.png',
          'https://example.com/al.png',
        ]),
      );
    });

    testWidgets('long account lists scroll on a small screen', (t) async {
      t.view.physicalSize = const Size(320, 480);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final trackers = List.generate(9, (i) => _FakeTracker('Tracker $i'));
      Tracker? picked;
      await _open(t, trackers: trackers, onPick: (value) => picked = value);
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(
        find.text('Tracker 8'),
        160,
        scrollable: find.byType(Scrollable),
      );
      await t.tap(find.text('Tracker 8'));
      await t.pumpAndSettle();
      expect(picked, same(trackers.last));
    });

    testWidgets('tap-out dismisses without picking', (t) async {
      final a = _FakeTracker('AniList');
      var fired = false;
      await _open(t, trackers: [a], onPick: (_) => fired = true);
      await t.tapAt(const Offset(10, 300));
      await t.pumpAndSettle();
      expect(fired, isFalse);
      expect(find.text('AniList'), findsNothing);
    });
  });
}
