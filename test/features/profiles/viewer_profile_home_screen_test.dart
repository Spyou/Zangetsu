import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/viewer_profile_home_screen.dart';

void main() {
  late Directory directory;
  late _TestViewerProfileStore profiles;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_home');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    profiles = _TestViewerProfileStore();
    await profiles.loadForUser();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<ViewerProfileStore>(profiles);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('shows the active profile and actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ViewerProfileHomeScreen()));

    expect(find.text('Active profile'), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Switch profile'), findsOneWidget);
    expect(find.text('Manage profiles'), findsOneWidget);
    expect(find.byTooltip('Edit profile'), findsOneWidget);
    expect(find.byTooltip('App settings'), findsOneWidget);
  });

  testWidgets('selecting a profile changes the active viewer', (tester) async {
    final guest = await tester.runAsync(() => profiles.create('Guest'));
    await tester.pumpWidget(const MaterialApp(home: ViewerProfileHomeScreen()));
    await tester.tap(find.byKey(ValueKey('profile-home-choice-${guest!.id}')));
    await tester.pump();

    expect(profiles.activeProfile.name, 'Guest');
    expect(find.text('Guest'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('edit action opens the full-page editor', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ViewerProfileHomeScreen()));
    await tester.tap(find.byTooltip('Edit profile'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(profiles.activeProfile.name, 'Home');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Manage profiles opens the existing profile manager', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ViewerProfileHomeScreen()));
    await tester.tap(find.text('Manage profiles'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Choose who is watching. Each profile keeps its own list and progress.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _TestViewerProfileStore extends ViewerProfileStore {
  @override
  Future<void> switchTo(String profileId) async {
    active.value = profiles.firstWhere((profile) => profile.id == profileId);
    revision.value++;
  }
}
