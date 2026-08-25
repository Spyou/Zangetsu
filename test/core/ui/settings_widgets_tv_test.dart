import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/tv/tv_list_focusable.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';

void main() {
  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets('SettingsCard uses Clip.none on TV so focus chrome is not cropped',
      (tester) async {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.settings,
                title: 'Row',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(SettingsCard),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.clipBehavior, Clip.none);
    expect(find.byType(TvListFocusable), findsOneWidget);
  });

  testWidgets('SettingsTile stays InkWell on phone (no TvListFocusable)',
      (tester) async {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.settings,
                title: 'Row',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TvListFocusable), findsNothing);
    expect(find.byType(InkWell), findsWidgets);

    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(SettingsCard),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.clipBehavior, Clip.antiAlias);
  });
}
