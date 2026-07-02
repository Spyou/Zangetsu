import 'backup_payload.dart';
import 'sources_backup.dart';
import 'library_backup.dart';
import 'settings_backup.dart';

class RestoreReport {
  const RestoreReport({required this.restored, required this.failures});
  final Set<BackupBundle> restored;
  final List<String> failures;
  bool get hasFailures => failures.isNotEmpty;
}

class BackupService {
  BackupService(this._sources, this._library, this._settings, {DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final SourcesBackup _sources;
  final LibraryBackup _library;
  final SettingsBackup _settings;
  final DateTime Function() _now;

  Map<String, dynamic> build(Set<BackupBundle> bundles) {
    final out = <BackupBundle, Map<String, dynamic>>{};
    if (bundles.contains(BackupBundle.sources))  out[BackupBundle.sources]  = _sources.build();
    if (bundles.contains(BackupBundle.library))  out[BackupBundle.library]  = _library.build();
    if (bundles.contains(BackupBundle.settings)) out[BackupBundle.settings] = _settings.build();
    return wrapPayload(out, createdAtIso: _now().toUtc().toIso8601String());
  }

  Future<RestoreReport> restore(Map<String, dynamic> payload, Set<BackupBundle> bundles) async {
    final data = unwrapPayload(payload); // throws BackupFormatException on bad app/version
    final failures = <String>[];
    final restored = <BackupBundle>{};
    for (final b in bundles) {
      final d = data[b];
      if (d == null) continue;
      switch (b) {
        case BackupBundle.sources:  failures.addAll(await _sources.merge(d)); restored.add(b);
        case BackupBundle.library:  await _library.merge(d); restored.add(b);
        case BackupBundle.settings: await _settings.merge(d); restored.add(b);
      }
    }
    return RestoreReport(restored: restored, failures: failures);
  }
}
