import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/features/shell/root_shell.dart';

void main() {
  test('phone Profile tab uses the Settings destination', () {
    final pages = buildShellPages(null);

    expect(pages, hasLength(4));
    expect(pages[3], isA<SettingsScreen>());
    expect(pages.last, isA<SettingsScreen>());
  });
}
