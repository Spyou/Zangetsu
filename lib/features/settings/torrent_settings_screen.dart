import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// Per-torrent behavior settings — currently just the mobile-data gate that
/// defaults off (Wi-Fi only) to protect users from unintended data usage.
class TorrentSettingsScreen extends StatefulWidget {
  const TorrentSettingsScreen({super.key});

  @override
  State<TorrentSettingsScreen> createState() => _TorrentSettingsScreenState();
}

class _TorrentSettingsScreenState extends State<TorrentSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Torrents', style: AppText.title),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          const SettingsSectionLabel('Data'),
          SettingsCard(
            children: [
              SwitchListTile.adaptive(
                value: sl<TorrentPrefs>().allowMobileData,
                onChanged: (v) async {
                  await sl<TorrentPrefs>().setAllowMobileData(v);
                  if (mounted) setState(() {});
                },
                activeThumbColor: AppColors.accent,
                contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                secondary: const Icon(
                  Icons.signal_cellular_alt_rounded,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
                title: Text(
                  'Use mobile data for torrents',
                  style: AppText.headline.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Off = torrents only run on Wi-Fi (saves mobile data). '
              'Streaming a torrent uses a lot of data.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
