import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/backup/backup_cloud.dart';
import '../../core/backup/backup_file.dart';
import '../../core/backup/backup_payload.dart';
import '../../core/backup/backup_service.dart';
import '../../core/di/injector.dart';
import '../../core/supabase/supabase_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../../l10n/l10n.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final Set<BackupBundle> _selected = {...BackupBundle.values};
  bool _busy = false;

  BackupService get _service => sl<BackupService>();
  BackupCloud _cloud() => BackupCloud(sl<SupabaseService>());

  bool get _isTv => sl<AppMode>().isTv;

  Future<void> _backupToCloud() async {
    if (!requireLogin(context, action: context.l10n.signInToBackUpToCloud)) return;
    final uid = context.read<AuthCubit>().state.user?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      await _cloud().upload(uid, _service.build(_selected));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.backedUpToCloud)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.cloudBackupFailed)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToFile() async {
    setState(() => _busy = true);
    try {
      // On TV also keep an app-private copy so restore-from-file can list it
      // without a document picker (see [_restoreFromFile]).
      final path = await BackupFile()
          .export(_service.build(_selected), keepLocalCopy: _isTv);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(path == null
              ? context.l10n.couldnTSaveTheBackupFileStoragePermissionMayBeNeeded
              : context.l10n.savedToDownloadsZangetsu),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromCloud() async {
    if (!requireLogin(context, action: context.l10n.signInToRestoreFromCloud)) return;
    final uid = context.read<AuthCubit>().state.user?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      final p = await _cloud().download(uid);
      if (!mounted) return;
      if (p == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.noCloudBackupFound)),
        );
        return;
      }
      final report = await _service.restore(p, _selected);
      if (!mounted) return;
      _showResult(report);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromFile() async {
    // On TV, prefer the SAF document picker too — Android TV's DocumentsUI is
    // D-pad-navigable, so a backup transferred from another device (e.g. the
    // phone app) can be browsed to and restored. Fall back to scanning the
    // app-readable backup files on boxes that genuinely lack a picker.
    Map<String, dynamic>? p;
    try {
      p = await BackupFile().import();
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.thatFileIsnTAValidBackup)),
      );
      if (!_isTv) return;
      p = null; // on TV, fall back to the app-readable local picker below
    } catch (_) {
      p = null;
    }
    if (_isTv) p ??= await _pickLocalBackupTv();
    if (p == null) return;
    setState(() => _busy = true);
    try {
      final report = await _service.restore(p, _selected);
      if (!mounted) return;
      _showResult(report);
    } on BackupFormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.restoreFailed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// TV restore: enumerate app-readable backup files and show a D-pad list.
  /// Returns the parsed backup, or null if none exist / the user backs out.
  Future<Map<String, dynamic>?> _pickLocalBackupTv() async {
    final backup = BackupFile();
    final files = await backup.listLocalBackups();
    if (!mounted) return null;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noBackupFilesOnDevice)),
      );
      return null;
    }
    final chosen = await showDialog<File>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.pickABackup, style: AppText.headline),
        children: [
          for (var i = 0; i < files.length; i++)
            TvListFocusable(
              autofocus: i == 0,
              onTap: () => Navigator.pop(ctx, files[i]),
              semanticLabel: _backupLabel(files[i]),
              // Row focus is an accent wash over the dark surface, not a white
              // pill — keep the text and icon light or they disappear into it.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        color: AppColors.textSecondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _backupLabel(files[i]),
                        style: AppText.body
                            .copyWith(color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return null;
    try {
      return await backup.readBackup(chosen);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldnTReadThatBackupFile)),
        );
      }
      return null;
    }
  }

  /// Friendly label for a backup file, parsed from its
  /// `zangetsu-backup-YYYYMMDD-HHMM.json` name (falls back to the raw name).
  String _backupLabel(File f) {
    final name = f.uri.pathSegments.last;
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})').firstMatch(name);
    if (m == null) return name;
    return '${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}';
  }

  void _showResult(RestoreReport r) {
    final names = r.restored.map((b) => switch (b) {
          BackupBundle.sources => context.l10n.sourcesAndRepos,
          BackupBundle.library => context.l10n.libraryBundle,
          BackupBundle.settings => context.l10n.appSettingsBundle,
        }).join(', ');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.restoreComplete, style: AppText.headline),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.restoredColon(names), style: AppText.body),
            if (r.hasFailures) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.couldnTReinstall(r.failures.join('\n')),
                style: AppText.body,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              context.l10n.reopenZangetsuToSeeRestoredLibrarySources,
              style: AppText.caption,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.ok),
          ),
        ],
      ),
    );
  }

  Widget _bundleRow(BackupBundle bundle, String label, String subtitle) {
    final selected = _selected.contains(bundle);
    void toggle() => setState(() {
          if (_selected.contains(bundle)) {
            _selected.remove(bundle);
          } else {
            _selected.add(bundle);
          }
        });
    // On TV, SettingsTile is already D-pad focusable (white pill). Phones keep
    // the Material CheckboxListTile.
    if (_isTv) {
      return SettingsTile(
        icon: selected
            ? Icons.check_box_rounded
            : Icons.check_box_outline_blank_rounded,
        title: label,
        subtitle: subtitle,
        onTap: _busy ? null : toggle,
      );
    }
    // Transparent Material so the tile's ink/splash paints above the
    // SettingsCard's DecoratedBox background (Flutter asserts otherwise — the
    // card colour would hide the splash).
    return Material(
      type: MaterialType.transparency,
      child: CheckboxListTile(
        value: selected,
        onChanged: _busy ? null : (v) => toggle(),
        title: Text(
          label,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
        ),
        subtitle: Text(subtitle, style: AppText.caption),
        activeColor: AppColors.accent,
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }

  String _fmtDt(DateTime dt) {
    final l = dt.toLocal();
    final mo = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    final h = l.hour.toString().padLeft(2, '0');
    final mi = l.minute.toString().padLeft(2, '0');
    return '${l.year}-$mo-$d $h:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthCubit>().state.user?.id;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.backupAndRestore),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  'Save your sources, list and settings — to a file on your '
                  'device or to your Zangetsu account. Restoring only adds '
                  'things back; it never deletes what you already have.',
                  style: AppText.caption,
                ),
              ),
              SettingsSectionLabel(context.l10n.includeInTheBackup),
              SettingsCard(
                children: [
                  _bundleRow(BackupBundle.sources, context.l10n.sourcesAndRepos,
                      context.l10n.installedSourcesAndRepoLinks),
                  _bundleRow(BackupBundle.library, context.l10n.libraryBundle,
                      context.l10n.myListAndContinueWatching),
                  _bundleRow(BackupBundle.settings, context.l10n.appSettingsBundle,
                      context.l10n.playerSubtitlesQualityPreferences),
                ],
              ),
              const SettingsSectionLabel('Create a backup'),
              SettingsCard(
                children: [
                  SettingsTile(
                    autofocus: true,
                    icon: Icons.save_alt_outlined,
                    title: context.l10n.saveToAFile,
                    subtitle: context.l10n.saveABackupFileToYourDownloadsFolder,
                    onTap: _busy ? null : _saveToFile,
                  ),
                  SettingsTile(
                    icon: Icons.cloud_upload_outlined,
                    title: context.l10n.backUpToCloud,
                    subtitle: context.l10n.saveACopyToYourAccountNeedsSignIn,
                    onTap: _busy ? null : _backupToCloud,
                  ),
                ],
              ),
              const SettingsSectionLabel('Restore a backup'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.folder_open_outlined,
                    title: context.l10n.restoreFromAFile,
                    subtitle: context.l10n.pickABackupFileYouSavedEarlier,
                    onTap: _busy ? null : _restoreFromFile,
                  ),
                  SettingsTile(
                    icon: Icons.cloud_download_outlined,
                    title: context.l10n.restoreFromCloud,
                    subtitle: context.l10n.bringBackYourLatestCloudBackup,
                    onTap: _busy ? null : _restoreFromCloud,
                  ),
                ],
              ),
              if (uid != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: FutureBuilder<DateTime?>(
                    future: _cloud().lastBackupAt(uid),
                    builder: (_, snap) {
                      final dt = snap.data;
                      final label = dt == null ? context.l10n.never : _fmtDt(dt);
                      return Text(
                        'Last cloud backup: $label',
                        style: AppText.caption,
                      );
                    },
                  ),
                ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
