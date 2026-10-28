import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/backup_payload.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/settings_backup.dart';
import 'package:watch_app/core/backup/sources_backup.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

class FakeSourcesBackup implements SourcesBackup {
  bool mergeCalled = false;

  @override
  Map<String, dynamic> build() => {'fake': 'sources'};

  @override
  Future<List<String>> merge(Map<String, dynamic> data) async {
    mergeCalled = true;
    return ['boom'];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeLibraryBackup implements LibraryBackup {
  bool mergeCalled = false;

  @override
  Map<String, dynamic> build() => {'fake': 'library'};

  @override
  Future<void> merge(Map<String, dynamic> data) async {
    mergeCalled = true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeSettingsBackup implements SettingsBackup {
  bool mergeCalled = false;

  @override
  Map<String, dynamic> build() => {'fake': 'settings'};

  @override
  Future<void> merge(Map<String, dynamic> data) async {
    mergeCalled = true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  test('protected backup export requires authorization for each operation', () async {
    var allowed = false;
    final protected = BackupService(FakeSourcesBackup(), FakeLibraryBackup(), FakeSettingsBackup(),
      authorize: () async { if (!allowed) throw StateError('Profile locked'); });
    expect(() => protected.build({BackupBundle.library}), throwsStateError);
    await expectLater(protected.authorize(), throwsStateError);
    allowed = true;
    await protected.authorize();
    expect(protected.build({BackupBundle.library})['app'], 'zangetsu');
    expect(() => protected.build({BackupBundle.library}), throwsStateError);
  });

  test('locked backup restore does not merge any records', () async {
    final library = FakeLibraryBackup();
    final protected = BackupService(FakeSourcesBackup(), library, FakeSettingsBackup(),
      authorize: () async { throw StateError('Profile locked'); });
    final payload = BackupService(FakeSourcesBackup(), library, FakeSettingsBackup())
      .build({BackupBundle.library});
    await expectLater(protected.restore(payload, {BackupBundle.library}), throwsStateError);
    expect(library.mergeCalled, isFalse);
  });

  late FakeSourcesBackup fakeSources;
  late FakeLibraryBackup fakeLibrary;
  late FakeSettingsBackup fakeSettings;
  late BackupService service;

  setUp(() {
    fakeSources = FakeSourcesBackup();
    fakeLibrary = FakeLibraryBackup();
    fakeSettings = FakeSettingsBackup();
    service = BackupService(
      fakeSources,
      fakeLibrary,
      fakeSettings,
      now: () => DateTime.utc(2026, 7, 2),
    );
  });

  // 1. build with only settings bundle
  test('build(settings) returns zangetsu payload with only settings bundle', () {
    final result = service.build({BackupBundle.settings});

    expect(result['app'], 'zangetsu');
    expect(result['createdAt'], '2026-07-02T00:00:00.000Z');

    final bundles = result['bundles'] as Map;
    expect(bundles.containsKey('settings'), isTrue);
    expect(bundles.containsKey('sources'), isFalse);
    expect(bundles.containsKey('library'), isFalse);
  });

  // 2. restore merges both codecs and returns correct RestoreReport
  test('restore merges sources and settings codecs and returns correct RestoreReport', () async {
    final payload = service.build({BackupBundle.settings, BackupBundle.sources});
    final report = await service.restore(payload, {BackupBundle.settings, BackupBundle.sources});

    expect(fakeSources.mergeCalled, isTrue);
    expect(fakeSettings.mergeCalled, isTrue);
    expect(report.failures, ['boom']);
    expect(report.restored, containsAll([BackupBundle.settings, BackupBundle.sources]));
  });

  // 3. restore throws BackupFormatException for wrong app field
  test('restore throws BackupFormatException when app field does not match', () async {
    await expectLater(
      service.restore(
        {'app': 'other', 'version': 1, 'bundles': {}},
        {BackupBundle.settings},
      ),
      throwsA(isA<BackupFormatException>()),
    );
  });
}
