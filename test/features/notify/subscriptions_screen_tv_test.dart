import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/notify/subscription_store.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/notify/subscriptions_screen_tv.dart';

// ── Minimal fakes ─────────────────────────────────────────────────────────────

/// Stub [SubscriptionStore]: returns a fixed list without touching Hive.
/// Only [all] is called by [SubscriptionsScreenTv.build].
class _FakeSubscriptionStore extends SubscriptionStore {
  _FakeSubscriptionStore(this._subs);

  final List<Subscription> _subs;

  @override
  List<Subscription> all() => List<Subscription>.from(_subs);

  @override
  Future<void> add(Subscription sub) async {}

  @override
  Future<void> remove(String sourceId, String url) async {}

  @override
  bool contains(String sourceId, String url) => false;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void _registerStubs(List<Subscription> subs) {
  GetIt.instance
      .registerSingleton<SubscriptionStore>(_FakeSubscriptionStore(subs));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const sub1 = Subscription(
    sourceId: 'allanime',
    url: '/aot',
    title: 'Attack on Titan',
  );
  const sub2 = Subscription(
    sourceId: 'cs:AnimePahe',
    url: '/ds',
    title: 'Demon Slayer',
  );

  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets(
    'SubscriptionsScreenTv renders subscription rows and first row has autofocus',
    (tester) async {
      _registerStubs([sub1, sub2]);

      await tester.pumpWidget(
        const MaterialApp(home: SubscriptionsScreenTv()),
      );
      await tester.pumpAndSettle();

      // Both titles are rendered.
      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Demon Slayer'), findsOneWidget);

      // At least 2 TvFocusable rows are present.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(2));

      // The very first TvFocusable (first subscription row) has autofocus=true.
      expect(focusables.first.autofocus, isTrue);
    },
  );

  testWidgets(
    'SubscriptionsScreenTv shows empty state when there are no subscriptions',
    (tester) async {
      _registerStubs([]);

      await tester.pumpWidget(
        const MaterialApp(home: SubscriptionsScreenTv()),
      );
      await tester.pumpAndSettle();

      // No rows — empty state message visible.
      expect(find.text('No notifications yet.', findRichText: true),
          findsNothing);
      // TvBackButton is always present (adds exactly one TvFocusable), even
      // when the subscription list is empty, so the empty state has no rows
      // but does have the back-navigation button.
      expect(find.byType(TvFocusable), findsOneWidget);
      // The EmptyState icon is present.
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'SubscriptionsScreenTv shows header title "Notifications"',
    (tester) async {
      _registerStubs([sub1]);

      await tester.pumpWidget(
        const MaterialApp(home: SubscriptionsScreenTv()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
    },
  );

  testWidgets(
    'SubscriptionsScreenTv only first row has autofocus=true',
    (tester) async {
      _registerStubs([sub1, sub2]);

      await tester.pumpWidget(
        const MaterialApp(home: SubscriptionsScreenTv()),
      );
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      expect(focusables, isNotEmpty);
      expect(focusables.first.autofocus, isTrue);

      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );
}
