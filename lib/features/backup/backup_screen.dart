import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/appwrite/appwrite_service.dart';
import '../../core/backup/backup_cloud.dart';
import '../../core/backup/backup_file.dart';
import '../../core/backup/backup_payload.dart';
import '../../core/backup/backup_service.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final Set<BackupBundle> _selected = {...BackupBundle.values};
  bool _busy = false;

  BackupService get _service => sl<BackupService>();
  BackupCloud _cloud() => BackupCloud(sl<AppwriteService>());

  bool get _isTv => sl<AppMode>().isTv;

  /// On TV, make [child] D-pad focusable (OK runs [onTap]); on phone, return it
  /// unchanged so the phone render/behaviour is byte-identical.
  Widget _tvWrap({
    required Widget child,
    required VoidCallback? onTap,
    bool autofocus = false,
  }) {
    if (!_isTv) return child;
    return TvFocusable(autofocus: autofocus, onTap: onTap ?? () {}, child: child);
  }

  Future<void> _backupToCloud() async {
    if (!requireLogin(context, action: 'back up to the cloud')) return;
    final uid = context.read<AuthCubit>().state.user?.$id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      await _cloud().upload(uid, _service.build(_selected));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backed up to cloud')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Cloud backup failed. Check you're online — if it keeps failing, "
            'the cloud backup store may not be set up yet.',
          ),
        ),
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
              ? "Couldn't save the backup file — storage permission may be needed."
              : 'Saved to Downloads › Zangetsu'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromCloud() async {
    if (!requireLogin(context, action: 'restore from the cloud')) return;
    final uid = context.read<AuthCubit>().state.user?.$id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      final p = await _cloud().download(uid);
      if (!mounted) return;
      if (p == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No cloud backup found')),
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
    // TV boxes usually have no document-picker UI, so the system file picker
    // silently no-ops. Instead list the app-readable backup files and let the
    // user pick one with the D-pad.
    final Map<String, dynamic>? p =
        _isTv ? await _pickLocalBackupTv() : await BackupFile().import();
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
        const SnackBar(
          content: Text(
            'No backup files found on this device. Save one first, or use '
            '"Restore from cloud".',
          ),
        ),
      );
      return null;
    }
    final chosen = await showDialog<File>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text('Pick a backup', style: AppText.headline),
        children: [
          for (var i = 0; i < files.length; i++)
            TvFocusable(
              autofocus: i == 0,
              onTap: () => Navigator.pop(ctx, files[i]),
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
          const SnackBar(content: Text("Couldn't read that backup file.")),
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
          BackupBundle.sources => 'Sources & repos',
          BackupBundle.library => 'Library',
          BackupBundle.settings => 'App settings',
        }).join(', ');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Restore complete', style: AppText.headline),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Restored: $names.', style: AppText.body),
            if (r.hasFailures) ...[
              const SizedBox(height: 8),
              Text(
                "Couldn't reinstall:\n${r.failures.join('\n')}",
                style: AppText.body,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Reopen Zangetsu to see restored library & sources.',
              style: AppText.caption,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
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
    // On TV, render as a SettingsTile (a check-box icon reflects selection) so
    // every row on this screen — and every row across the TV Settings — shares
    // one focus-highlight shape. Phones keep the Material CheckboxListTile.
    if (_isTv) {
      return _tvWrap(
        onTap: _busy ? null : toggle,
        child: SettingsTile(
          icon: selected
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          title: label,
          subtitle: subtitle,
          onTap: _busy ? null : toggle,
        ),
      );
    }
    return CheckboxListTile(
      value: selected,
      onChanged: _busy ? null : (v) => toggle(),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
      ),
      subtitle: Text(subtitle, style: AppText.caption),
      activeColor: AppColors.accent,
      controlAffinity: ListTileControlAffinity.leading,
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
    final uid = context.watch<AuthCubit>().state.user?.$id;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Backup & Restore', style: AppText.title),
      ),
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
              const SettingsSectionLabel('Include in the backup'),
              SettingsCard(
                children: [
                  _bundleRow(BackupBundle.sources, 'Sources & repos',
                      'Installed sources and their repo links'),
                  _bundleRow(BackupBundle.library, 'Library',
                      'My List and Continue Watching'),
                  _bundleRow(BackupBundle.settings, 'App settings',
                      'Player, subtitles, quality and preferences'),
                ],
              ),
              const SettingsSectionLabel('Create a backup'),
              SettingsCard(
                children: [
                  _tvWrap(
                    autofocus: true,
                    onTap: _busy ? null : _saveToFile,
                    child: SettingsTile(
                      icon: Icons.save_alt_outlined,
                      title: 'Save to a file',
                      subtitle: 'Save a backup file to your Downloads folder',
                      onTap: _busy ? null : _saveToFile,
                    ),
                  ),
                  _tvWrap(
                    onTap: _busy ? null : _backupToCloud,
                    child: SettingsTile(
                      icon: Icons.cloud_upload_outlined,
                      title: 'Back up to cloud',
                      subtitle: 'Save a copy to your account · needs sign-in',
                      onTap: _busy ? null : _backupToCloud,
                    ),
                  ),
                ],
              ),
              const SettingsSectionLabel('Restore a backup'),
              SettingsCard(
                children: [
                  _tvWrap(
                    onTap: _busy ? null : _restoreFromFile,
                    child: SettingsTile(
                      icon: Icons.folder_open_outlined,
                      title: 'Restore from a file',
                      subtitle: 'Pick a backup file you saved earlier',
                      onTap: _busy ? null : _restoreFromFile,
                    ),
                  ),
                  _tvWrap(
                    onTap: _busy ? null : _restoreFromCloud,
                    child: SettingsTile(
                      icon: Icons.cloud_download_outlined,
                      title: 'Restore from cloud',
                      subtitle: 'Bring back your latest cloud backup',
                      onTap: _busy ? null : _restoreFromCloud,
                    ),
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
                      final label = dt == null ? 'never' : _fmtDt(dt);
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
