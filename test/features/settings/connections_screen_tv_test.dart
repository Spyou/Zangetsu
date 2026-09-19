import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/settings/connections_screen_tv.dart';

// Configurable fake trackers — mirrors the pattern in
// test/features/shell/root_shell_tv_test.dart, minus the Hive/network guts.
class _FakeAniListService extends ChangeNotifier implements AniListService {
  _FakeAniListService({this.connected = false, this.name});
  final bool connected;
  final String? name;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => connected;

  @override
  String get displayName => 'AniList';

  @override
  String? get viewerName => name;

  @override
  String? get viewerAvatar => null;

  @override
  Future<void> disconnect() async {}
}

class _FakeMalService extends ChangeNotifier implements MalService {
  _FakeMalService({this.connected = false, this.name});
  final bool connected;
  final String? name;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => connected;

  @override
  String get displayName => 'MyAnimeList';

  @override
  String? get viewerName => name;

  @override
  String? get viewerAvatar => null;

  @override
  Future<void> disconnect() async {}
}

class _FakeSimklService extends ChangeNotifier implements SimklService {
  _FakeSimklService({this.connected = false, this.name});
  final bool connected;
  final String? name;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => connected;

  @override
  String get displayName => 'Simkl';

  @override
  String? get viewerName => name;

  @override
  String? get viewerAvatar => null;

  @override
  Future<void> disconnect() async {}
}

class _FakeMangaBakaService extends ChangeNotifier
    implements MangaBakaService {
  _FakeMangaBakaService({this.connected = false, this.name});
  final bool connected;
  final String? name;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => connected;

  @override
  String get displayName => 'MangaBaka';

  @override
  String? get viewerName => name;

  @override
  String? get viewerAvatar => null;

  @override
  Future<void> disconnect() async {}
}

void _register(
  GetIt sl, {
  bool aniConnected = false,
  String? aniName,
  bool malConnected = false,
  String? malName,
  bool simklConnected = false,
  String? simklName,
  bool mbConnected = false,
  String? mbName,
}) {
  sl.registerSingleton<AniListService>(
      _FakeAniListService(connected: aniConnected, name: aniName));
  sl.registerSingleton<MalService>(
      _FakeMalService(connected: malConnected, name: malName));
  sl.registerSingleton<SimklService>(
      _FakeSimklService(connected: simklConnected, name: simklName));
  sl.registerSingleton<MangaBakaService>(
      _FakeMangaBakaService(connected: mbConnected, name: mbName));
}

void main() {
  final sl = GetIt.instance;
  tearDown(sl.reset);

  testWidgets('lists every tracker with a Connect action when signed out',
      (tester) async {
    _register(sl, aniConnected: false, malConnected: false, simklConnected: false);
    await tester.pumpWidget(const MaterialApp(home: ConnectionsScreenTv()));
    await tester.pumpAndSettle();
    expect(find.text('AniList'), findsOneWidget);
    expect(find.text('MyAnimeList'), findsOneWidget);
    expect(find.text('Simkl'), findsOneWidget);
    expect(find.text('MangaBaka'), findsOneWidget);
    expect(find.text('Connect'), findsNWidgets(4));
  });

  testWidgets('shows Connected + viewer name and a Disconnect action',
      (tester) async {
    _register(sl,
        aniConnected: true, aniName: 'krishna',
        malConnected: false, simklConnected: false);
    await tester.pumpWidget(const MaterialApp(home: ConnectionsScreenTv()));
    await tester.pumpAndSettle();
    expect(find.textContaining('krishna'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });
}
