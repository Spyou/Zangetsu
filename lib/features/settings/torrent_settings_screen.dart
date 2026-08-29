import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
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
      appBar: settingsAppBar(context.l10n.torrents),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.dataSection),
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
                  context.l10n.useMobileDataForTorrents,
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
              context.l10n.torrentsOffWifiBlurb,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
