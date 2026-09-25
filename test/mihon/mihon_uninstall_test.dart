import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mihon/mihon_extension_service.dart';

/// Uninstall has to remove the APK, not just the installed-box entry: the
/// native `loadInstalled` walks the mihon directory and loads every `*.apk`
/// it finds without consulting the box, so an APK left behind is re-registered
/// on the next cold start and the source reappears as if nothing happened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mihon_uninstall_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<dynamic>(MihonExtensionService.installedBoxName);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('deletes the APK and the box entry', () async {
    final apk = File('${tempDir.path}/asmhentai.apk')
      ..writeAsBytesSync([1, 2, 3]);
    await Hive.box<dynamic>(MihonExtensionService.installedBoxName)
        .put('asmhentai', apk.path);

    final failure = await MihonExtensionService.uninstall('asmhentai');

    expect(failure, isNull);
    expect(apk.existsSync(), isFalse, reason: 'APK must not survive uninstall');
    expect(
      Hive.box<dynamic>(MihonExtensionService.installedBoxName)
          .containsKey('asmhentai'),
      isFalse,
    );
  });

  test('clears the box entry even when the APK is already gone', () async {
    // The ghost state: an entry in the box with nothing on disk. There is
    // nothing left to delete, so this is a success — but the entry still has
    // to go, or the source stays registered as installed forever.
    await Hive.box<dynamic>(MihonExtensionService.installedBoxName)
        .put('asmhentai', '${tempDir.path}/does-not-exist.apk');

    final failure = await MihonExtensionService.uninstall('asmhentai');

    expect(failure, isNull);
    expect(
      Hive.box<dynamic>(MihonExtensionService.installedBoxName)
          .containsKey('asmhentai'),
      isFalse,
    );
  });

  test('reports when neither the box nor the directory has an apk', () async {
    final failure = await MihonExtensionService.uninstall(
      'never-installed',
      mihonDir: tempDir,
    );

    expect(failure, isNotNull);
  });

  test('finds the apk by convention when the box has lost the entry', () async {
    // The real failure: `mihon_installed` was empty for an extension that was
    // still installed and loading on every cold start, so uninstall deleted
    // nothing and the source came back. The APK name is derived from the pkg
    // at install time, so the directory is enough to find it.
    final apk = File('${tempDir.path}/asmhentai.apk')
      ..writeAsBytesSync([1, 2, 3]);

    final failure =
        await MihonExtensionService.uninstall('asmhentai', mihonDir: tempDir);

    expect(failure, isNull);
    expect(apk.existsSync(), isFalse, reason: 'APK must be deleted, not left');
  });
}
