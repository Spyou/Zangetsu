import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/update/update_service.dart';

/// Check for an update and, if one exists, show the update dialog.
///
/// In [manual] mode (the Settings "Check for updates" tap) it also tells the
/// user when they're already up to date. In auto mode (app launch) it stays
/// silent unless a newer, non-skipped release is found — so it never nags.
Future<void> maybeShowUpdateDialog(
  BuildContext context, {
  bool manual = false,
}) async {
  final service = UpdateService();
  final info = await service.checkForUpdate(respectSkip: !manual);
  if (!context.mounted) return;
  if (info == null) {
    if (manual) {
      final v = await service.currentVersion();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "You're on the latest version${v.isEmpty ? '' : ' (v$v)'}.",
          ),
        ),
      );
    }
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _UpdateDialog(info: info, service: service),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.service});

  final UpdateInfo info;
  final UpdateService service;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null until the download starts
  bool _busy = false; // downloading or installing
  String? _error;

  Future<void> _startUpdate() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.service.downloadApk(
        widget.info.apkUrl,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _progress = 1);
      final ok = await widget.service.installApk(file);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(); // installer launched — close the dialog
      } else {
        setState(() {
          _busy = false;
          _error =
              'Couldn\'t open the installer. Enable "Install unknown apps" '
              'for Zangetsu in system settings, then try again.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = 'Download failed — check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.info.notes;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.system_update_rounded,
                  color: AppColors.accent,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Update available', style: AppText.title),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Version ${widget.info.version}',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 14),
            if (notes.isNotEmpty) ...[
              Text("What's new", style: AppText.caption),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    notes,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: AppColors.surface2,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _progress! >= 1
                    ? 'Starting installer…'
                    : 'Downloading… ${(_progress! * 100).round()}%',
                style: AppText.caption,
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: AppText.caption.copyWith(color: AppColors.accent),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!_busy)
                    TextButton(
                      onPressed: () async {
                        await widget.service.skipVersion(widget.info.version);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: Text(
                        'Skip',
                        style: AppText.button.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
                  if (!_busy)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        'Later',
                        style: AppText.button.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                    ),
                    onPressed: _busy ? null : _startUpdate,
                    child: Text(
                      _error != null ? 'Retry' : 'Update',
                      style: AppText.button.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
