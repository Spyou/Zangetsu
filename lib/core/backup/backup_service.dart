import 'package:flutter/foundation.dart';

import '../stremio/stremio_backup.dart';

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
  BackupService(
    this._sources,
    this._library,
    this._settings, {
    DateTime Function()? now,
    Future<void> Function()? authorize,
    StremioBackup Function()? stremio,
  }) : _now = now ?? DateTime.now,
       _authorize = authorize,
       _stremio = stremio;
  final StremioBackup Function()? _stremio;
  final SourcesBackup _sources;
  final LibraryBackup _library;
  final SettingsBackup _settings;
  final DateTime Function() _now;
  final Future<void> Function()? _authorize;
  bool _authorized = false;

  Future<void> authorize() async {
    _authorized = false;
    await _authorize?.call();
    _authorized = true;
  }

  Map<String, dynamic> build(Set<BackupBundle> bundles) {
    if (_authorize != null && !_authorized) {
      throw StateError(
        'Profile authorization is required before exporting a backup',
      );
    }
    _authorized = false;
    final out = <BackupBundle, Map<String, dynamic>>{};
    if (bundles.contains(BackupBundle.sources)) {
      out[BackupBundle.sources] = _sources.build();
    }
    if (bundles.contains(BackupBundle.library)) {
      out[BackupBundle.library] = _library.build();
    }
    if (bundles.contains(BackupBundle.settings)) {
      out[BackupBundle.settings] = _settings.build();
    }
    return wrapPayload(out, createdAtIso: _now().toUtc().toIso8601String());
  }

  Future<Map<String, dynamic>> buildProtected(
    Set<BackupBundle> bundles, {
    String? password,
    bool forFile = false,
  }) async {
    final payload = build(bundles);
    if (bundles.contains(BackupBundle.sources) && _stremio != null) {
      final envelope = await _stremio().encode(
        password: password,
        forFile: forFile,
      );
      (payload['bundles']['sources'] as Map)['stremio'] = envelope;
    }
    return payload;
  }

  Future<RestoreReport> restore(
    Map<String, dynamic> payload,
    Set<BackupBundle> bundles, {
    String? password,
  }) async {
    await authorize();
    _authorized = false;
    final data = unwrapPayload(
      payload,
    ); // throws BackupFormatException on bad app/version
    Map<String, dynamic>? addonConfiguration;
    Future<void> Function(Map<String, dynamic>)? restoreAddons;
    final envelope = data[BackupBundle.sources]?['stremio'];
    if (bundles.contains(BackupBundle.sources) && envelope != null) {
      if (_stremio == null || envelope is! Map) {
        throw const BackupFormatException(
          'This build cannot restore the addon backup.',
        );
      }
      restoreAddons = _stremio().guardedRestore();
      addonConfiguration = await _stremio().decode(
        Map<String, dynamic>.from(envelope),
        password: password,
      );
      await _stremio().validate(addonConfiguration);
    }
    final failures = <String>[];
    final restored = <BackupBundle>{};
    for (final b in bundles) {
      final d = data[b];
      if (d == null) continue;
      switch (b) {
        case BackupBundle.sources:
          failures.addAll(await _sources.merge(d));
          if (addonConfiguration != null) {
            try {
              await restoreAddons!(addonConfiguration);
            } catch (_) {
              failures.add(
                'Stremio addons could not be restored. Current addons were kept.',
              );
            }
          }
          restored.add(b);
        case BackupBundle.library:
          await _library.merge(d);
          restored.add(b);
        case BackupBundle.settings:
          await _settings.merge(d);
          restored.add(b);
      }
    }
    // A restore rewrites sources, library and settings at once. Unlogged, the
    // result looks like the app spontaneously changing state — which is how it
    // read in a shared log until the bundles were named here.
    debugPrint(
      '[backup] restore · ${restored.map((b) => b.name).join(", ")} '
      '· ${failures.length} failed',
    );
    return RestoreReport(restored: restored, failures: failures);
  }
}
