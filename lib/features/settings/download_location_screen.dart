import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// Lets the user pick a custom SAF directory for MP4 downloads, or reset
/// back to the default Downloads › Zangetsu location.
class DownloadLocationScreen extends StatefulWidget {
  const DownloadLocationScreen({super.key});

  @override
  State<DownloadLocationScreen> createState() => _DownloadLocationScreenState();
}

class _DownloadLocationScreenState extends State<DownloadLocationScreen> {
  @override
  Widget build(BuildContext context) {
    final prefs = sl<DownloadPrefs>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Download location', style: AppText.title),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          const SettingsSectionLabel('Current location'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        prefs.locationLabel ?? 'Downloads › Zangetsu',
                        style: AppText.body,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.folder_open_outlined,
                title: 'Choose folder…',
                onTap: () async {
                  final uri = await FileDownloader().uri.pickDirectory(
                    persistedUriPermission: true,
                  );
                  if (uri == null) return; // canceled
                  final decoded = Uri.decodeComponent(
                    uri.pathSegments.isNotEmpty
                        ? uri.pathSegments.last
                        : 'Folder',
                  );
                  final label = decoded.split('/').last.split(':').last;
                  await sl<DownloadPrefs>().setLocation(
                    uri.toString(),
                    label.isEmpty ? 'Folder' : label,
                  );
                  if (mounted) setState(() {});
                },
              ),
              if (prefs.locationUri != null)
                SettingsTile(
                  icon: Icons.restore_rounded,
                  title: 'Reset to default',
                  onTap: () async {
                    await sl<DownloadPrefs>().setLocation(null, null);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'New downloads save here. Existing downloads and streaming '
              '(HLS) downloads stay in Downloads › Zangetsu.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
