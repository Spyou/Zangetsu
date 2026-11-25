import 'package:flutter/material.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/di/injector.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/mangabaka_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../auth/tv_tracker_connect_screen.dart';
import 'discord_settings_screen.dart';
import 'tracker_settings_screen.dart';

typedef _TrackerRow = ({String id, String name, Tracker tracker});

List<_TrackerRow> _trackerRows() => [
  (id: 'anilist', name: 'AniList', tracker: sl<AniListService>()),
  (id: 'mal', name: 'MyAnimeList', tracker: sl<MalService>()),
  (id: 'simkl', name: 'Simkl', tracker: sl<SimklService>()),
  if (sl.isRegistered<MangaBakaService>())
    (id: 'mangabaka', name: 'MangaBaka', tracker: sl<MangaBakaService>()),
];

class ConnectedServicesScreen extends StatefulWidget {
  const ConnectedServicesScreen({super.key, required this.isTv});

  final bool isTv;

  static int get connectedTrackerCount =>
      _trackerRows().where((row) => row.tracker.isConnected).length;

  @override
  State<ConnectedServicesScreen> createState() =>
      _ConnectedServicesScreenState();
}

class _ConnectedServicesScreenState extends State<ConnectedServicesScreen> {
  Future<void> _open(Widget screen) async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  Future<void> _manageTracker(_TrackerRow row) async {
    if (!widget.isTv) {
      await _open(TrackerSettingsScreen(tracker: row.tracker));
    } else if (row.tracker.isConnected) {
      await row.tracker.disconnect();
      if (mounted) setState(() {});
    } else {
      await _open(TvTrackerConnectScreen(trackerId: row.id));
    }
  }

  Widget _serviceLogo(String id) {
    final discord = id == 'discord';
    return Container(
      width: 34,
      height: 34,
      padding: discord ? const EdgeInsets.all(7) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: discord ? const Color(0xFF5865F2) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon/providers/$id.png',
        fit: BoxFit.contain,
        excludeFromSemantics: true,
      ),
    );
  }

  SettingsTile _trackerTile(_TrackerRow row, {required bool autofocus}) {
    final l10n = context.l10n;
    final connected = row.tracker.isConnected;
    final name = connected ? row.tracker.viewerName : null;
    final status = name != null && name.isNotEmpty
        ? l10n.connectedAs(name)
        : connected
        ? l10n.connected
        : l10n.notConnected;
    return SettingsTile(
      icon: Icons.menu_book_outlined,
      leading: _serviceLogo(row.id),
      title: row.name,
      subtitle: status,
      semanticLabel: '${row.name}, $status',
      autofocus: autofocus,
      trailing: widget.isTv
          ? Text(
              connected ? l10n.disconnect : l10n.connect,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            )
          : null,
      onTap: () => _manageTracker(row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final trackers = _trackerRows();
    final discord = sl.isRegistered<DiscordRpc>() ? sl<DiscordRpc>() : null;
    final discordStatus = discord != null && discord.loggedIn && discord.enabled
        ? l10n.on
        : l10n.off;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        settingsSectionTitle(l10n, SettingsSection.account),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            clipBehavior: widget.isTv ? Clip.none : Clip.hardEdge,
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              const SettingsSectionLabel('Watch tracking', first: true),
              SettingsCard(
                radius: 26,
                children: [
                  for (var i = 0; i < trackers.length; i++)
                    _trackerTile(trackers[i], autofocus: widget.isTv && i == 0),
                ],
              ),
              if (discord != null && (!widget.isTv || !isAppleTv)) ...[
                const SettingsSectionLabel('Activity sharing'),
                SettingsCard(
                  radius: 26,
                  children: [
                    SettingsTile(
                      icon: Icons.gamepad_outlined,
                      leading: _serviceLogo('discord'),
                      title: l10n.discord,
                      subtitle: 'Show what you’re watching on Discord',
                      subtitleMaxLines: 2,
                      semanticLabel: '${l10n.discord}, $discordStatus',
                      trailing: Text(
                        discordStatus,
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      onTap: () => _open(const DiscordSettingsScreen()),
                    ),
                  ],
                ),
              ],
              if (widget.isTv)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 18, 20, 0),
                  child: Text(
                    l10n.disconnectingHereOnlySignsThisTrackerOutOnTheTVYourPhoneStaysConnected,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
