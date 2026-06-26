import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/app_config.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import '../../core/di/injector.dart';
import '../../core/playback/external_player.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import 'discord_settings_screen.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../update/update_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import 'developers_screen.dart';
import 'donate_screen.dart';
import '../auth/auth_cubit.dart';
import '../watch_together/ui/watch_together_sheet.dart';
import '../auth/auth_screens.dart';
import '../downloads/downloads_screen.dart';
import '../notify/subscriptions_screen.dart';
import 'tracker_settings_screen.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';

/// Top-level Settings screen — a grouped list of cards mirroring the
/// iOS Settings look in our dark/coral language.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Opt-in in-app DNS-over-HTTPS for CloudStream sources (Android-only). Loaded
  // from native on open; CsDns.off (default) until then.
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

  Future<void> _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  /// Bottom sheet to pick the in-app DNS-over-HTTPS provider for CS sources.
  Future<void> _pickDns() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('DNS', style: AppText.headline),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Encrypted DNS for CloudStream sources — helps bypass ISP '
                  'blocking. Off = your normal connection.',
                  style: AppText.caption,
                ),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final e in CsDns.labels.entries)
              ListTile(
                title: Text(e.value, style: AppText.body),
                trailing: e.key == _dnsChoice
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == _dnsChoice) return;
    await CsDns.set(picked);
    if (mounted) setState(() => _dnsChoice = picked);
  }

  /// Bottom sheet to pick the search results layout (grid vs CloudStream-style
  /// rows). Persisted via [SearchPrefs]; the search screen reads it live.
  Future<void> _pickSearchLayout() async {
    final prefs = sl<SearchPrefs>();
    final picked = await showModalBottomSheet<SearchLayout>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Search layout', style: AppText.headline),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'How cross-source results are shown. Vertical = a grid per '
                  'source; Horizontal = a scrolling row per source.',
                  style: AppText.caption,
                ),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final l in SearchLayout.values)
              ListTile(
                title: Text(l.label, style: AppText.body),
                trailing: l == prefs.layout
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, l),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await prefs.setLayout(picked);
    if (mounted) setState(() {});
  }

  String _activeLabel(String activeId) {
    if (activeId.startsWith('cs:')) {
      return _csManager.get(activeId)?.displayName ?? activeId;
    }
    final entry = _registry.entryFor(activeId);
    if (entry == null) return activeId;
    return entry.displayName.isNotEmpty ? entry.displayName : entry.name;
  }

  /// Bottom sheet listing enabled providers; sets the active source on the
  /// [ActiveSourceCubit].
  Future<void> _pickActiveSource() async {
    final enabled = _registry.getAll().where((e) => e.enabled).toList()
      ..sort((a, b) {
        final an = a.displayName.isNotEmpty ? a.displayName : a.name;
        final bn = b.displayName.isNotEmpty ? b.displayName : b.name;
        return an.toLowerCase().compareTo(bn.toLowerCase());
      });
    // CloudStream sources (`cs:<name>`) live outside the registry; surface them
    // alongside the JS providers so the user can switch to one.
    final csSources = _csManager.enabled.toList()
      ..sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        ),
      );
    final currentId = _active.state;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Active source', style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            if (enabled.isEmpty && csSources.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text('No enabled sources', style: AppText.body),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final e in enabled)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, e.name),
                        title: Text(
                          e.displayName.isNotEmpty ? e.displayName : e.name,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: e.name == currentId
                            ? const Icon(Icons.check, color: AppColors.accent)
                            : null,
                      ),
                    for (final p in csSources)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, p.sourceId),
                        title: Text(
                          p.displayName,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        subtitle: Text('CloudStream', style: AppText.caption),
                        trailing: p.sourceId == currentId
                            ? const Icon(Icons.check, color: AppColors.accent)
                            : null,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && picked != currentId) {
      _active.setSource(picked);
      if (mounted) setState(() {});
    }
  }

  /// Prompts for a CloudStream repo URL, installs it via the native channel,
  /// and reports how many sources are now available. Android-only.
  Future<void> _addCloudStreamRepo() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _AddRepoDialog(),
    );
    if (url == null || url.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await _csManager.addRepo(url);
      messenger.showSnackBar(
        SnackBar(content: Text('Added — $count CloudStream source(s) available')),
      );
      if (mounted) setState(() {});
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to add repository: $e')),
      );
    }
  }

  /// Account row — signed-in profile (pfp + name → Profile) or a Sign-in tile.
  Widget _accountCard(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) {
        if (auth.isLoggedIn) {
          final initial = auth.displayName.isNotEmpty
              ? auth.displayName[0].toUpperCase()
              : '?';
          return SettingsCard(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.surface2,
                  backgroundImage: auth.avatarUrl != null
                      ? NetworkImage(auth.avatarUrl!)
                      : null,
                  child: auth.avatarUrl == null
                      ? Text(initial, style: AppText.headline)
                      : null,
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
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                ),
                onTap: () => _push(const ProfileScreen()),
              ),
            ],
          );
        }
        return SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.person_outline_rounded,
              title: 'Sign in',
              subtitle: 'Sync your list & continue watching',
              onTap: () => _push(const LoginScreen()),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final activeId = context.watch<ActiveSourceCubit>().state;
    final connectedCount = <Tracker>[
      sl<AniListService>(),
      sl<MalService>(),
      sl<SimklService>(),
    ].where((t) => t.isConnected).length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('Settings', style: AppText.largeTitle),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  _accountCard(context),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.groups_2_outlined,
                        title: 'Join a watch party',
                        subtitle: 'Enter a code to watch in sync with friends',
                        onTap: () {
                          if (sl<AuthCubit>().state.user == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Sign in to watch together'),
                              ),
                            );
                            return;
                          }
                          promptJoinWatchParty(context);
                        },
                      ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.dns_rounded,
                        title: 'Providers',
                        subtitle: '$enabledCount enabled',
                        onTap: () async {
                          await _push(const SourcesScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsTile(
                        icon: Icons.swap_horiz_rounded,
                        title: 'Active source',
                        subtitle: _activeLabel(activeId),
                        onTap: _pickActiveSource,
                      ),
                      SettingsTile(
                        icon: Icons.health_and_safety_outlined,
                        title: 'Source health',
                        subtitle: 'Test which sources are working',
                        onTap: () => _push(const SourceHealthScreen()),
                      ),
                      if (Platform.isAndroid)
                        SettingsTile(
                          icon: Icons.extension_outlined,
                          title: 'Add CloudStream repository',
                          subtitle: 'Install CloudStream sources',
                          onTap: _addCloudStreamRepo,
                        ),
                      if (Platform.isAndroid)
                        SettingsTile(
                          icon: Icons.vpn_lock_outlined,
                          title: 'DNS',
                          subtitle: _dnsChoice == CsDns.off
                              ? 'Off · bypass ISP blocks on CS sources'
                              : CsDns.labelFor(_dnsChoice),
                          onTap: _pickDns,
                        ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.play_circle_outline,
                        title: 'Playback',
                        subtitle: 'Quality, autoplay, speed',
                        onTap: () => _push(const PlaybackSettingsScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.download_outlined,
                        title: 'Downloads',
                        subtitle: 'Watch offline',
                        onTap: () => _push(const DownloadsScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.search_rounded,
                        title: 'Search layout',
                        subtitle: sl<SearchPrefs>().layout.label,
                        onTap: _pickSearchLayout,
                      ),
                      if (Platform.isAndroid)
                        SettingsTile(
                          icon: Icons.notifications_none_rounded,
                          title: 'Notifications',
                          subtitle: 'New-episode alerts for subscribed shows',
                          onTap: () => _push(const SubscriptionsScreen()),
                        ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sd_storage_outlined,
                        title: 'Storage',
                        onTap: () => _push(const StorageSettingsScreen()),
                      ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sync_alt_rounded,
                        title: 'Connections',
                        subtitle: connectedCount > 0
                            ? '$connectedCount connected'
                            : 'AniList, MyAnimeList, Simkl',
                        onTap: () async {
                          await _push(const ConnectionsScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsTile(
                        icon: Icons.gamepad_outlined,
                        title: 'Discord',
                        subtitle: 'Rich Presence — show your status',
                        onTap: () async {
                          await _push(const DiscordSettingsScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsTile(
                        icon: Icons.shield_outlined,
                        title: 'Privacy',
                        subtitle: 'NSFW sources',
                        onTap: () async {
                          await _push(const PrivacySettingsScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.coffee_rounded,
                        title: 'Support the app',
                        subtitle: 'Buy me a coffee',
                        onTap: () => _push(const DonateScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.people_outline_rounded,
                        title: 'Developers',
                        onTap: () => _push(const DevelopersScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.system_update_rounded,
                        title: 'Check for updates',
                        subtitle: 'Get the latest version from GitHub',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Checking for updates…'),
                            ),
                          );
                          maybeShowUpdateDialog(context, manual: true);
                        },
                      ),
                      SettingsTile(
                        icon: Icons.info_outline_rounded,
                        title: 'About',
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


// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

/// App-wide playback defaults — default quality / audio, autoplay, speed,
/// skip interval, keep-screen-on and resume. Reads and writes the shared
/// [PlaybackPrefs] singleton; rebuilds after each change so the value
/// subtitles stay current.
class PlaybackSettingsScreen extends StatefulWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  State<PlaybackSettingsScreen> createState() => _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState extends State<PlaybackSettingsScreen> {
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  // Ordered (value, label) options for each picker.
  static const List<(String, String)> _qualityOptions = [
    ('auto', 'Auto'),
    ('highest', 'Highest'),
    ('1080p', '1080p'),
    ('720p', '720p'),
    ('480p', '480p'),
  ];

  static const List<(String, String)> _audioOptions = [
    ('sub', 'Sub'),
    ('dub', 'Dub'),
  ];

  static const List<(double, String)> _speedOptions = [
    (0.5, '0.5x'),
    (0.75, '0.75x'),
    (1.0, '1x'),
    (1.25, '1.25x'),
    (1.5, '1.5x'),
    (2.0, '2x'),
  ];

  static const List<(int, String)> _skipOptions = [
    (5, '5s'),
    (10, '10s'),
    (15, '15s'),
    (30, '30s'),
  ];

  String _labelFor<T>(List<(T, String)> options, T value, String fallback) {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return fallback;
  }

  /// Bottom sheet listing [options]; returns the value the user tapped, or
  /// null if dismissed. Mirrors the active-source picker on the Settings list.
  Future<T?> _pick<T>({
    required String title,
    required List<(T, String)> options,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title, style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            ...options.map((opt) {
              final (value, label) = opt;
              final isSelected = value == current;
              return ListTile(
                onTap: () => Navigator.pop(ctx, value),
                title: Text(
                  label,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
                trailing: isSelected
                    ? const Icon(Icons.check, color: AppColors.accent)
                    : null,
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickQuality() async {
    final picked = await _pick<String>(
      title: 'Default quality',
      options: _qualityOptions,
      current: _prefs.defaultQuality,
    );
    if (picked == null) return;
    await _prefs.setDefaultQuality(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickAudio() async {
    final picked = await _pick<String>(
      title: 'Default audio',
      options: _audioOptions,
      current: _prefs.defaultCategory,
    );
    if (picked == null) return;
    await _prefs.setDefaultCategory(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSpeed() async {
    final picked = await _pick<double>(
      title: 'Default speed',
      options: _speedOptions,
      current: _prefs.defaultSpeed,
    );
    if (picked == null) return;
    await _prefs.setDefaultSpeed(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSkip() async {
    final picked = await _pick<int>(
      title: 'Double-tap skip',
      options: _skipOptions,
      current: _prefs.doubleTapSeconds,
    );
    if (picked == null) return;
    await _prefs.setDoubleTapSeconds(picked);
    if (mounted) setState(() {});
  }

  /// Default player picker: Built-in + any installed external players. Streams
  /// then open in the chosen app instead of the in-app player.
  Future<void> _pickPlayer() async {
    final players = await ExternalPlayer().installed();
    if (!mounted) return;
    final options = <(String, String)>[
      ('', 'Built-in player'),
      for (final p in players) (p.package, p.label),
    ];
    if (players.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No external players found. Install MX Player, VLC, mpv, '
            'Just Player or Next Player.',
          ),
        ),
      );
    }
    final picked = await _pick<String>(
      title: 'Default player',
      options: options,
      current: _prefs.externalPlayerPackage,
    );
    if (picked == null) return;
    final label = options
        .firstWhere((o) => o.$1 == picked, orElse: () => ('', ''))
        .$2;
    await _prefs.setExternalPlayer(picked, picked.isEmpty ? '' : label);
    if (mounted) setState(() {});
  }

  /// A boolean row rendered as a [SwitchListTile.adaptive] styled to sit
  /// inside a [SettingsCard] alongside the [SettingsTile] picker rows.
  Widget _toggleRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      activeThumbColor: AppColors.accent,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      secondary: Icon(icon, color: AppColors.textSecondary, size: 22),
      title: Text(
        title,
        style: AppText.headline.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: AppText.caption),
    );
  }

  /// MegaSkip jump-size slider (5–180s), shown under the MegaSkip toggle. Holds
  /// the value locally while dragging (smooth, no per-tick Hive writes) and
  /// persists on release.
  Widget _megaSkipDurationRow() {
    double val = _prefs.megaSkipSeconds.toDouble();
    return StatefulBuilder(
      builder: (context, setLocal) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.timer_outlined,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'MegaSkip duration',
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  '${val.round()}s',
                  style: AppText.headline.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text('${PlaybackPrefs.megaSkipMin}', style: AppText.caption),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppColors.accent,
                      thumbColor: AppColors.accent,
                      inactiveTrackColor: AppColors.textSecondary.withValues(
                        alpha: 0.3,
                      ),
                      overlayColor: AppColors.accent.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      min: PlaybackPrefs.megaSkipMin.toDouble(),
                      max: PlaybackPrefs.megaSkipMax.toDouble(),
                      divisions:
                          PlaybackPrefs.megaSkipMax - PlaybackPrefs.megaSkipMin,
                      value: val,
                      label: '${val.round()}s',
                      onChanged: (v) => setLocal(() => val = v),
                      onChangeEnd: (v) async {
                        await _prefs.setMegaSkipSeconds(v.round());
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                Text('${PlaybackPrefs.megaSkipMax}', style: AppText.caption),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Playback', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          // ── Quality & audio ─────────────────────────────────────────────
          const SettingsSectionLabel('Quality & audio'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.high_quality_outlined,
                title: 'Default quality',
                subtitle: _labelFor(
                  _qualityOptions,
                  _prefs.defaultQuality,
                  _prefs.defaultQuality,
                ),
                onTap: _pickQuality,
              ),
              SettingsTile(
                icon: Icons.translate_rounded,
                title: 'Default audio (anime sub/dub)',
                subtitle: _labelFor(
                  _audioOptions,
                  _prefs.defaultCategory,
                  _prefs.defaultCategory,
                ),
                onTap: _pickAudio,
              ),
              SettingsTile(
                icon: Icons.speed_outlined,
                title: 'Default speed',
                subtitle: _labelFor(
                  _speedOptions,
                  _prefs.defaultSpeed,
                  '${_prefs.defaultSpeed}x',
                ),
                onTap: _pickSpeed,
              ),
            ],
          ),

          // ── Player (external app handoff — Android) ─────────────────────
          if (Platform.isAndroid) ...[
            const SettingsSectionLabel('Player'),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.smart_display_outlined,
                  title: 'Default player',
                  subtitle: _prefs.externalPlayerPackage.isEmpty
                      ? 'Built-in'
                      : (_prefs.externalPlayerLabel.isNotEmpty
                            ? _prefs.externalPlayerLabel
                            : 'External app'),
                  onTap: _pickPlayer,
                ),
              ],
            ),
          ],

          // ── Playback behaviour ──────────────────────────────────────────
          const SettingsSectionLabel('Playback'),
          SettingsCard(
            children: [
              _toggleRow(
                icon: Icons.history_outlined,
                title: 'Resume playback',
                subtitle: 'Continue from where you left off',
                value: _prefs.autoResume,
                onChanged: (v) async {
                  await _prefs.setAutoResume(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.skip_next_outlined,
                title: 'Autoplay next episode',
                value: _prefs.autoplayNext,
                onChanged: (v) async {
                  await _prefs.setAutoplayNext(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_outlined,
                title: 'Skip intro button',
                subtitle: 'Show Skip opening/ending on anime (when detected)',
                value: _prefs.skipIntro,
                onChanged: (v) async {
                  await _prefs.setSkipIntro(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.keyboard_double_arrow_right_rounded,
                title: 'MegaSkip button',
                subtitle: 'A jump-forward button in the player (any video)',
                value: _prefs.megaSkip,
                onChanged: (v) async {
                  await _prefs.setMegaSkip(v);
                  if (mounted) setState(() {});
                },
              ),
              if (_prefs.megaSkip) _megaSkipDurationRow(),
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen on',
                value: _prefs.keepScreenOn,
                onChanged: (v) async {
                  await _prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.image_outlined,
                title: 'Seek preview (online)',
                subtitle: 'Thumbnail while scrubbing — uses a little data',
                value: _prefs.seekPreviewOnline,
                onChanged: (v) async {
                  await _prefs.setSeekPreviewOnline(v);
                  if (mounted) setState(() {});
                },
              ),
              if (Platform.isAndroid)
                _toggleRow(
                  icon: Icons.picture_in_picture_alt_outlined,
                  title: 'Auto picture-in-picture',
                  subtitle: 'Shrink to a floating window when you leave the app',
                  value: _prefs.autoPip,
                  onChanged: (v) async {
                    await _prefs.setAutoPip(v);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),

          // ── Gestures ────────────────────────────────────────────────────
          const SettingsSectionLabel('Gestures'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.touch_app_outlined,
                title: 'Double-tap skip',
                subtitle: _labelFor(
                  _skipOptions,
                  _prefs.doubleTapSeconds,
                  '${_prefs.doubleTapSeconds}s',
                ),
                onTap: _pickSkip,
              ),
              _toggleRow(
                icon: Icons.swipe_outlined,
                title: 'Gesture controls',
                subtitle: 'Swipe left for brightness, right for volume',
                value: _prefs.gestureControls,
                onChanged: (v) async {
                  await _prefs.setGestureControls(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: 'Hold for 2× speed',
                subtitle: 'Long-press the video to play at 2× while held',
                value: _prefs.holdSpeed,
                onChanged: (v) async {
                  await _prefs.setHoldSpeed(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),

          // ── Subtitles ───────────────────────────────────────────────────
          const SettingsSectionLabel('Subtitles'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.format_size_rounded,
                title: 'Size',
                subtitle: _labelFor(
                  _subSizeOptions,
                  _prefs.subtitleScale,
                  'Medium',
                ),
                onTap: _pickSubSize,
              ),
              SettingsTile(
                icon: Icons.palette_outlined,
                title: 'Colour',
                subtitle: _labelFor(
                  _subColorOptions,
                  _prefs.subtitleColor,
                  'White',
                ),
                onTap: _pickSubColor,
              ),
              _toggleRow(
                icon: Icons.subtitles_outlined,
                title: 'Background',
                subtitle: 'Draw a box behind the text',
                value: _prefs.subtitleBackground,
                onChanged: (v) async {
                  await _prefs.setSubtitleBackground(v);
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile(
                icon: Icons.vpn_key_outlined,
                title: 'OpenSubtitles API key',
                subtitle: _prefs.subtitleApiKey.trim().isEmpty
                    ? 'Required for online subtitle search'
                    : 'Key saved — online search enabled',
                onTap: _editSubtitleApiKey,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Prompts for the OpenSubtitles API key and saves it to [PlaybackPrefs].
  /// A free key is created at opensubtitles.com → Consumers.
  Future<void> _editSubtitleApiKey() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => _ApiKeyDialog(initial: _prefs.subtitleApiKey),
    );
    if (key == null) return; // dismissed
    await _prefs.setSubtitleApiKey(key.trim());
    if (mounted) setState(() {});
  }

  static const List<(double, String)> _subSizeOptions = [
    (0.8, 'Small'),
    (1.0, 'Medium'),
    (1.3, 'Large'),
  ];
  static const List<(String, String)> _subColorOptions = [
    ('white', 'White'),
    ('yellow', 'Yellow'),
  ];

  Future<void> _pickSubSize() async {
    final v = await _pick(
      title: 'Subtitle size',
      options: _subSizeOptions,
      current: _prefs.subtitleScale,
    );
    if (v != null) {
      await _prefs.setSubtitleScale(v);
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickSubColor() async {
    final v = await _pick(
      title: 'Subtitle colour',
      options: _subColorOptions,
      current: _prefs.subtitleColor,
    );
    if (v != null) {
      await _prefs.setSubtitleColor(v);
      if (mounted) setState(() {});
    }
  }
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  Future<void> _clearImageCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      // Best-effort — clearing the live image cache above is the part
      // that matters for freeing memory immediately.
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Image cache cleared')),
    );
  }

  Future<void> _clearProviderCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await sl<ProviderDownloader>().clear();
    messenger.showSnackBar(
      const SnackBar(content: Text('Provider cache cleared')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Storage', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.image_outlined,
                title: 'Clear image cache',
                onTap: () => _clearImageCache(context),
              ),
              SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear provider cache',
                subtitle: 'Cached source .js files',
                onTap: () => _clearProviderCache(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  static const String _discussionUrl = 'https://t.me/+9mQlsdvDlo83Mjk1';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('About', style: AppText.title),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 28, 0, 28),
        children: [
          // App logo.
          Center(
            child: Container(
              width: 96,
              height: 96,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(24),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(kAppName, style: AppText.largeTitle.copyWith(fontSize: 24)),
          ),
          const SizedBox(height: 4),
          Center(child: Text('Version $kAppVersion', style: AppText.caption)),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Your anime, movies and series — one sleek, ad-free home. '
              'Add community sources to browse and stream in 4K, download for '
              'offline, and pick up right where you left off across devices.',
              style: AppText.body.copyWith(height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 28),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.forum_rounded,
                title: 'Discussion group',
                subtitle: 'Join the community on Telegram',
                onTap: () => _open(_discussionUrl),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              '© ${DateTime.now().year}  $kAppName',
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connections (trackers)
// ---------------------------------------------------------------------------

/// Lists the trackers (AniList / MyAnimeList / Simkl); each opens its own
/// connect/disconnect screen.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  @override
  Widget build(BuildContext context) {
    final trackers = <Tracker>[
      sl<AniListService>(),
      sl<MalService>(),
      sl<SimklService>(),
    ];
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('Connections'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              for (final t in trackers)
                SettingsTile(
                  icon: Icons.sync_alt_rounded,
                  title: t.displayName,
                  subtitle: t.isConnected
                      ? (t.viewerName ?? 'Connected')
                      : 'Sync progress as you watch',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrackerSettingsScreen(tracker: t),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Sync watch progress and list status to your accounts. Anime syncs '
              'to all three; movies and series sync to Simkl.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Privacy
// ---------------------------------------------------------------------------

/// NSFW-source toggle. Enabling pops a confirmation; disabling demotes the
/// active source if it's now hidden.
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool get _nsfw => sl<PlaybackPrefs>().nsfwSources;

  Future<void> _onNsfwChanged(bool value) async {
    final prefs = sl<PlaybackPrefs>();
    if (value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Enable NSFW sources?', style: AppText.title),
          content: Text(
            'This shows sources marked 18+ in the source list and switcher. '
            'Only turn this on if you want adult content.',
            style: AppText.body,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await prefs.setNsfwSources(true);
    } else {
      await prefs.setNsfwSources(false);
      _demoteNsfwActiveSource();
    }
    if (mounted) setState(() {});
  }

  /// When NSFW is turned off and the active source is now hidden, switch to the
  /// first non-NSFW enabled source so Home stops showing it.
  void _demoteNsfwActiveSource() {
    final registry = sl<ProviderRegistry>();
    final active = sl<ActiveSourceCubit>();
    final blocked = registry.nsfwSourceIds();
    if (!blocked.contains(active.state)) return;
    for (final e in registry.getAll()) {
      if (e.enabled && !blocked.contains(e.name)) {
        active.setSource(e.name);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('Privacy'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Enable NSFW sources',
                subtitle: 'Show sources marked 18+',
                trailing: Switch.adaptive(
                  value: _nsfw,
                  activeThumbColor: AppColors.accent,
                  onChanged: _onNsfwChanged,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Sources marked 18+ stay hidden from the source list and switcher '
              'unless this is on.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

/// Self-contained URL-entry dialog for adding a CloudStream repository. Owns its
/// own [TextEditingController] and disposes it on unmount (after the route's
/// exit animation finishes) — avoids the "used after dispose" crash that a
/// caller-owned controller disposed right after `await showDialog` would hit.
/// Text-entry dialog for the OpenSubtitles API key. Returns the entered string
/// on save (empty clears the key) or null when dismissed. Mirrors
/// [_AddRepoDialog] for visual consistency.
class _ApiKeyDialog extends StatefulWidget {
  const _ApiKeyDialog({required this.initial});
  final String initial;

  @override
  State<_ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<_ApiKeyDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('OpenSubtitles API key', style: AppText.headline),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            cursorColor: AppColors.accent,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'API key',
              hintText: 'Paste your key',
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
          const SizedBox(height: 10),
          Text(
            'Create a free key at opensubtitles.com → Consumers.',
            style: AppText.caption,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddRepoDialog extends StatefulWidget {
  const _AddRepoDialog();

  @override
  State<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends State<_AddRepoDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add CloudStream repository', style: AppText.headline),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        cursorColor: AppColors.accent,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: const InputDecoration(
          labelText: 'Repository URL',
          hintText: 'https://.../repo.json',
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
