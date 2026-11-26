import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/profile_shell_scope.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/profile_launch_gate.dart';

/// Start-up prompts (update dialog, community / announcement sheets) versus
/// the launch profile picker. Both shells now hold Home's prompts while
/// [ProfileShellScope.shouldDeferTabs] is true; the picker must also close
/// itself, not whatever route ends up on top of it.
void main() {
  late Directory directory;
  late ViewerProfileStore profiles;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gate_prompts');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    profiles = ViewerProfileStore();
    await profiles.loadForUser();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<ViewerProfileStore>(profiles);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('no start-up prompt opens while the picker is up', (
    tester,
  ) async {
    await tester.runAsync(() => profiles.create('Second'));
    final pickerUpWhenShown = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileLaunchGate(
          child: _PromptProbe(
            waitForTabs: true,
            onShow: () => pickerUpWhenShown.add(
              find.text("Who's watching?").evaluate().isNotEmpty,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Update prompt'), findsNothing);
    expect(pickerUpWhenShown, isEmpty);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(find.text("Who's watching?"), findsNothing);
    expect(find.text('Update prompt'), findsOneWidget);
    expect(pickerUpWhenShown, [false]);
  });

  testWidgets(
    'closing the picker removes the picker, not a prompt pushed on top',
    (tester) async {
      await tester.runAsync(() => profiles.create('Second'));
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileLaunchGate(
            // Fires as soon as content is released, which happens during the
            // avatar animation while the picker is still the route below.
            child: _PromptProbe(waitForTabs: false, onShow: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Update prompt'), findsNothing);

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();

      expect(find.text("Who's watching?"), findsNothing);
      expect(find.text('Update prompt'), findsOneWidget);
      // The prompt is the top route and closes normally afterwards.
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Update prompt'), findsNothing);
      expect(find.text('Main screen'), findsOneWidget);
    },
  );
}

/// Stands in for Home: opens one prompt on the root navigator the first time
/// it is allowed to, like `_maybeStartLaunchChecks`.
class _PromptProbe extends StatefulWidget {
  const _PromptProbe({required this.waitForTabs, required this.onShow});

  /// True: wait for [ProfileShellScope.shouldDeferTabs] (what both shells
  /// pass as deferHomeStartupPrompts). False: only wait for content.
  final bool waitForTabs;
  final VoidCallback onShow;

  @override
  State<_PromptProbe> createState() => _PromptProbeState();
}

class _PromptProbeState extends State<_PromptProbe> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final deferContent = ProfileShellScope.shouldDeferContent(context);
    final hold = widget.waitForTabs
        ? ProfileShellScope.shouldDeferTabs(context) || deferContent
        : deferContent;
    if (!hold && !_shown) {
      _shown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onShow();
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            content: const Text('Update prompt'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Later'),
              ),
            ],
          ),
        );
      });
    }
    return deferContent ? const SizedBox.expand() : const Text('Main screen');
  }
}
