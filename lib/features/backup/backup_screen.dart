import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/appwrite/appwrite_service.dart';
import '../../core/backup/backup_cloud.dart';
import '../../core/backup/backup_file.dart';
import '../../core/backup/backup_payload.dart';
import '../../core/backup/backup_service.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToFile() async {
    await BackupFile().export(_service.build(_selected));
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
    final p = await BackupFile().import();
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

  Widget _bundleRow(BackupBundle bundle, String label) {
    return CheckboxListTile(
      value: _selected.contains(bundle),
      onChanged: _busy
          ? null
          : (v) => setState(() {
                if (v == true) {
                  _selected.add(bundle);
                } else {
                  _selected.remove(bundle);
                }
              }),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
      ),
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
              const SettingsSectionLabel('Bundles'),
              SettingsCard(
                children: [
                  _bundleRow(BackupBundle.sources, 'Sources & repos'),
                  _bundleRow(BackupBundle.library, 'Library'),
                  _bundleRow(BackupBundle.settings, 'App settings'),
                ],
              ),
              const SettingsSectionLabel('Back up'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.cloud_upload_outlined,
                    title: 'Back up to cloud',
                    onTap: _busy ? null : _backupToCloud,
                  ),
                  SettingsTile(
                    icon: Icons.save_alt_outlined,
                    title: 'Save to file',
                    onTap: _busy ? null : _saveToFile,
                  ),
                ],
              ),
              const SettingsSectionLabel('Restore'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.cloud_download_outlined,
                    title: 'Restore from cloud',
                    onTap: _busy ? null : _restoreFromCloud,
                  ),
                  SettingsTile(
                    icon: Icons.folder_open_outlined,
                    title: 'Restore from file',
                    onTap: _busy ? null : _restoreFromFile,
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
