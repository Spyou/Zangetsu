import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../auth/reconnect.dart';
import '../backup/backup_screen.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import '../notify/subscriptions_screen.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';
import 'connections_screen_tv.dart';
import 'discord_settings_screen.dart';
import 'settings_screen.dart';
import '../shell/tv_source_picker.dart';

/// TV Settings: one flat D-pad list grouped with [SettingsSectionLabel] headers
/// (same section names as mobile where applicable). Sub-screens inherit focus
/// from shared [SettingsTile] / [SettingsCard] widgets.
class SettingsScreenTv extends StatefulWidget {
  const SettingsScreenTv({super.key});

  @override
  State<SettingsScreenTv> createState() => _SettingsScreenTvState();
}

class _SettingsScreenTvState extends State<SettingsScreenTv> {
  int _dnsChoice = CsDns.off;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      CsDns.get().then((c) {
        if (mounted) setState(() => _dnsChoice = c);
      });
    }
  }

  ActiveSourceCubit get _active => context.read<ActiveSourceCubit>();
  ProviderRegistry get _registry => sl<ProviderRegistry>();
  CloudStreamManager get _csManager => sl<CloudStreamManager>();

  Future<void> _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  String _activeLabel(String activeId) {
    if (activeId.startsWith('cs:')) {
      return _csManager.get(activeId)?.displayName ?? activeId;
    }
    final entry = _registry.entryFor(activeId);
    if (entry == null) return activeId;
    return entry.displayName.isNotEmpty ? entry.displayName : entry.name;
  }

  Future<void> _pickDnsTv() async {
    final picked = await showDialog<int>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _TvOptionPicker<int>(
        title: ctx.l10n.dns,
        options: CsDns.labels.entries.map((e) => (e.key, e.value)).toList(),
        current: _dnsChoice,
      ),
    );
    if (picked == null || picked == _dnsChoice) return;
    await CsDns.set(picked);
    if (mounted) setState(() => _dnsChoice = picked);
  }

  void _pickActiveSourceTv() {
    final currentId = _active.state;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => BlocProvider<ActiveSourceCubit>.value(
        value: context.read<ActiveSourceCubit>(),
        child: TvSourcePicker(currentId: currentId),
      ),
    );
  }

  Future<void> _syncLibraryToCloud() async {
    final l10n = context.l10n;
    if (sl<AuthCubit>().state.user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.signInFirst)),
      );
      return;
    }
    final live = await ensureLiveSession(context);
    if (!context.mounted) return;
    if (!live) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.reconnectToSyncLibrary)),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(l10n.syncingLibraryToCloud)),
      );
    final h = (await sl<WatchHistory>().pushAllLocalToCloud()).pushed;
    final l = (await sl<MyListStore>().pushAllLocalToCloud()).pushed;
    if (!context.mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            h == 0 && l == 0
                ? l10n.syncLibraryAlreadySynced
                : l10n.syncLibraryPushed(h, l),
          ),
        ),
      );
  }

  Widget _sectionLabel(String section, {bool first = false}) {
    return SettingsSectionLabel(
      settingsSectionTitle(context.l10n, section),
      first: first,
    );
  }

  Widget _accountCard(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) {
        if (auth.isLoggedIn) {
          final initial = auth.displayName.isNotEmpty ? auth.displayName[0].toUpperCase() : '?';
          return SettingsCard(
            children: [
              TvListFocusable(
                autofocus: true,
                semanticLabel: auth.displayName,
                onTap: () => _push(const ProfileScreen()),
                child: ExcludeSemantics(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: AppColors.surface2,
                      backgroundImage: auth.avatarUrl != null ? CachedNetworkImageProvider(auth.avatarUrl!) : null,
                      child: auth.avatarUrl == null ? Text(initial, style: AppText.headline) : null,
                    ),
                    title: Text(
                      auth.displayName,
                      style: AppText.headline.copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      auth.user?.email ?? '',
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary, size: 22),
                  ),
                ),
              ),
            ],
          );
        }
        return SettingsCard(
          children: [
            SettingsTile(
              autofocus: true,
              icon: Icons.person_outline_rounded,
              title: context.l10n.signIn,
              subtitle: context.l10n.signInSubtitleTv,
              onTap: () => _push(const LoginScreen()),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final activeId = context.watch<ActiveSourceCubit>().state;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 24, 48, 16),
              child: Text(l10n.settingsTitle, style: AppText.largeTitle),
            ),
            Expanded(
              child: ListView(
                clipBehavior: Clip.none,
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  _accountCard(context),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.account, first: true),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sync_alt_rounded,
                        title: l10n.connections,
                        subtitle: l10n.connectionsTvSubtitle,
                        onTap: () async {
                          await _push(const ConnectionsScreenTv());
                          if (mounted) setState(() {});
                        },
                      ),
                      if (!isAppleTv)
                        SettingsTile(
                          icon: Icons.gamepad_outlined,
                          title: l10n.discord,
                          subtitle: l10n.discordSubtitle,
                          onTap: () async {
                            await _push(const DiscordSettingsScreen());
                            if (mounted) setState(() {});
                          },
                        ),
                      SettingsTile(
                        icon: Icons.cloud_sync_outlined,
                        title: l10n.backupAndRestore,
                        subtitle: l10n.backupAndRestoreSubtitle,
                        onTap: () => _push(const BackupScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.cloud_upload_outlined,
                        title: l10n.syncLibraryToCloud,
                        subtitle: l10n.syncLibraryToCloudSubtitle,
                        onTap: _syncLibraryToCloud,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.sources),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.dns_rounded,
                        title: l10n.providers,
                        subtitle: l10n.providersEnabledCount(enabledCount),
                        onTap: () async {
                          await _push(const SourcesScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsTile(
                        icon: Icons.swap_horiz_rounded,
                        title: l10n.activeSource,
                        subtitle: _activeLabel(activeId),
                        onTap: _pickActiveSourceTv,
                      ),
                      SettingsTile(
                        icon: Icons.health_and_safety_outlined,
                        title: l10n.sourceHealth,
                        subtitle: l10n.sourceHealthSubtitle,
                        onTap: () => _push(const SourceHealthScreen()),
                      ),
                      if (Platform.isAndroid)
                        SettingsTile(
                          icon: Icons.update_rounded,
                          title: l10n.sourceUpdates,
                          subtitle: l10n.sourceUpdatesSubtitle,
                          onTap: () async {
                            final cm = sl<CloudStreamManager>();
                            await cm.setNotifyUpdates(!cm.notifyUpdates);
                            if (mounted) setState(() {});
                          },
                          trailing: Switch.adaptive(
                            value: sl<CloudStreamManager>().notifyUpdates,
                            activeThumbColor: AppColors.accent,
                            onChanged: (v) async {
                              await sl<CloudStreamManager>().setNotifyUpdates(v);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                      SettingsTile(
                        icon: Icons.autorenew_rounded,
                        title: l10n.autoUpdateExtensions,
                        subtitle: l10n.autoUpdateExtensionsSubtitle,
                        onTap: () async {
                          final prefs = sl<PlaybackPrefs>();
                          await prefs.setAutoUpdateExtensions(!prefs.autoUpdateExtensions);
                          if (mounted) setState(() {});
                        },
                        trailing: Switch.adaptive(
                          value: sl<PlaybackPrefs>().autoUpdateExtensions,
                          activeThumbColor: AppColors.accent,
                          onChanged: (v) async {
                            await sl<PlaybackPrefs>().setAutoUpdateExtensions(v);
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.playback),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.play_circle_outline,
                        title: l10n.playback,
                        subtitle: l10n.playbackSubtitle,
                        onTap: () => _push(const PlaybackSettingsScreen()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.history),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.history_rounded,
                        title: l10n.history,
                        subtitle: l10n.historySubtitle,
                        onTap: () async {
                          await _push(const HistoryScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.downloads),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.download_outlined,
                        title: l10n.downloads,
                        subtitle: l10n.downloadsSubtitleTv,
                        onTap: () => _push(const DownloadsScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.sd_storage_outlined,
                        title: l10n.storage,
                        subtitle: l10n.storageSubtitle,
                        onTap: () => _push(const StorageSettingsScreen()),
                      ),
                    ],
                  ),
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 8),
                    _sectionLabel(SettingsSection.notifications),
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.notifications_none_rounded,
                          title: l10n.notifications,
                          subtitle: l10n.notificationsSubtitle,
                          onTap: () => _push(const SubscriptionsScreen()),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.advanced),
                  SettingsCard(
                    children: [
                      if (Platform.isAndroid)
                        SettingsTile(
                          icon: Icons.vpn_lock_outlined,
                          title: l10n.dns,
                          subtitle: _dnsChoice == CsDns.off
                              ? l10n.dnsOffTvSubtitle
                              : CsDns.labelFor(_dnsChoice),
                          onTap: _pickDnsTv,
                        ),
                      SettingsTile(
                        icon: Icons.shield_outlined,
                        title: l10n.privacy,
                        subtitle: l10n.privacySubtitle,
                        onTap: () async {
                          await _push(const PrivacySettingsScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _sectionLabel(SettingsSection.about),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.info_outline_rounded,
                        title: l10n.about,
                        subtitle: 'v$kAppVersion',
                        onTap: () => _push(const AboutSettingsScreen()),
                      ),
                    ],
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

/// D-pad option picker dialog (DNS).
class _TvOptionPicker<T> extends StatelessWidget {
  const _TvOptionPicker({super.key, required this.title, required this.options, required this.current});

  final String title;
  final List<(T, String)> options;
  final T current;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(title, style: AppText.title.copyWith(color: AppColors.textPrimary)),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            for (int i = 0; i < options.length; i++)
              TvListFocusable(
                autofocus: options[i].$1 == current,
                onTap: () => Navigator.of(context).pop(options[i].$1),
                semanticLabel: options[i].$2,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(child: Text(options[i].$2, style: AppText.headline)),
                        if (options[i].$1 == current) Icon(Icons.check, color: AppColors.accent, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
