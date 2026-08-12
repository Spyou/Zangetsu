import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/app_config.dart';
import '../../core/app_mode.dart';
import '../../core/cache/media_cache.dart';
import '../../core/logging/app_logger.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import '../player/player_screen.dart' show openSubtitleStyleSheet;
import '../player/shader_presets.dart';
import '../../core/di/injector.dart';
import '../../core/playback/external_player.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../auth/reconnect.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import '../../core/provider/provider_manager.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import 'appearance_screen.dart';
import 'reader_settings_screen.dart';
import 'discord_settings_screen.dart';
import 'torrent_settings_screen.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/subtitle_language_picker.dart';
import '../../core/theme/app_text.dart';
import '../../core/update/update_service.dart';
import '../update/update_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/dock_visibility.dart';
import '../../core/ui/team_section.dart';
import 'contributors_screen.dart';
import 'donate_screen.dart';
import '../auth/auth_cubit.dart';
import '../backup/backup_screen.dart';
import '../watch_together/ui/watch_party_lobby_screen.dart';
import '../auth/auth_screens.dart';
import '../onboarding/how_it_works.dart';
import '../notify/subscriptions_screen.dart';
import 'tracker_settings_screen.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';
import '../sources/zangetsu_sources_screen.dart';
import 'settings_screen_tv.dart';
import 'cubit/settings_cubit.dart';

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

  final TextEditingController _searchCtrl = TextEditingController();
  // Search text + which section's sub-page is open. Held in a Cubit so the
  // drill-down/search state is testable; the async prefs mirror below
  // (_dnsChoice) and subtitle refreshes stay local setState.
  late final SettingsCubit _settingsCubit = SettingsCubit();

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      CsDns.get().then((c) {
        if (mounted) setState(() => _dnsChoice = c);
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _settingsCubit.close();
    dockHiddenBySection.value = false; // never leave the dock stuck hidden
    shellBackIntercepted.value = false;
    super.dispose();
  }

  ActiveSourceCubit get _active => context.read<ActiveSourceCubit>();

  ProviderRegistry get _registry => sl<ProviderRegistry>();

  CloudStreamManager get _csManager => sl<CloudStreamManager>();

  Future<void> _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  /// Bottom sheet to pick the in-app DNS-over-HTTPS provider for CS sources.
  Future<void> _shareLogs() async {
    final file = await AppLogger.instance.exportFile();
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Could not export logs')));
      return;
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'Zangetsu logs'),
    );
  }

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
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
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
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
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

  Future<void> _pickBatchDownloadStyle() async {
    final prefs = sl<PlaybackPrefs>();
    // (id, label, blurb)
    const options = <(String, String, String)>[
      (
        'classic',
        'Classic',
        'The full sheet with a per-episode thumbnail grid.',
      ),
      ('minimal', 'Minimal', 'A number wheel — pick how many episodes to grab.'),
    ];
    final picked = await showModalBottomSheet<String>(
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
                child: Text('Batch download style', style: AppText.headline),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'The sheet shown when you download a whole season. Both '
                  'download exactly the same — only the picker looks different.',
                  style: AppText.caption,
                ),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final o in options)
              ListTile(
                title: Text(o.$2, style: AppText.body),
                subtitle: Text(o.$3, style: AppText.caption),
                trailing: o.$1 == prefs.batchDownloadStyle
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, o.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await prefs.setBatchDownloadStyle(picked);
    if (mounted) setState(() {});
  }

  String _activeLabel(String activeId) {
    if (activeId.startsWith('cs:')) {
      return _csManager.get(activeId)?.displayName ?? activeId;
    }
    if (activeId.startsWith('ani:')) {
      return sl<AniyomiManager>().get(activeId)?.displayName ?? activeId;
    }
    if (activeId.startsWith('mihon:')) {
      return sl<MihonManager>().get(activeId)?.displayName ?? activeId;
    }
    final entry = _registry.entryFor(activeId);
    if (entry == null) return activeId;
    return entry.displayName.isNotEmpty ? entry.displayName : entry.name;
  }

  /// Opens the SAME source picker as the Home header (tabbed anime/movies with
  /// CS·/Ani· labels + repo tags) and applies the chosen source. Reuses
  /// [SourceSwitcher.showPicker] so Settings and Home stay in sync.
  void _pickActiveSource() {
    SourceSwitcher(
      currentId: _active.state,
      onChanged: (id) {
        if (id != _active.state) {
          _active.setSource(id);
          if (mounted) setState(() {});
        }
      },
      onInstallSources: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    ).showPicker(context);
  }

  /// Prompts for a CloudStream repo URL, installs it via the native channel,
  /// and reports how many sources are now available. Android-only.
  /// Account header — a single profile card at the top of Settings. Signed in:
  /// avatar + name + email → Profile. Signed out: an avatar placeholder + a
  /// clear "Sign in" call-to-action → Login (its own card, so it no longer
  /// reads as a flat duplicate of the "Account & sync" row below it).
  Widget _accountCard(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) {
        final Widget row;
        if (auth.isLoggedIn) {
          final initial = auth.displayName.isNotEmpty
              ? auth.displayName[0].toUpperCase()
              : '?';
          row = _accountRow(
            onTap: () => _push(const ProfileScreen()),
            avatar: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.surface2,
              backgroundImage: auth.avatarUrl != null
                  ? CachedNetworkImageProvider(auth.avatarUrl!)
                  : null,
              child: auth.avatarUrl == null
                  ? Text(initial, style: AppText.headline.copyWith(fontSize: 18))
                  : null,
            ),
            title: auth.displayName,
            subtitle: auth.user?.email ?? '',
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
              size: 20,
            ),
          );
        } else {
          row = _accountRow(
            onTap: () => _push(const LoginScreen()),
            avatar: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.accentSoft,
              child: Icon(
                Icons.person_outline_rounded,
                color: AppColors.accent,
                size: 24,
              ),
            ),
            title: 'Sign in',
            subtitle: 'Sync your list, history & continue watching',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Sign in',
                style: AppText.caption.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SettingsCard(children: [row]),
        );
      },
    );
  }

  Widget _accountRow({
    required VoidCallback onTap,
    required Widget avatar,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.headline.copyWith(fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            trailing,
          ],
        ),
      ),
    );
  }

  /// A plain grey value shown at the row's trailing edge (before the chevron).
  /// Used for e.g. "Rows", "Off", "2 linked".
  Widget _value(String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(text, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
      const SizedBox(width: 6),
      const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.textTertiary,
        size: 20,
      ),
    ],
  );

  /// Live "Search settings" field — filters every setting as you type
  /// (title, description and keyword synonyms), Samsung-style. A clear (×)
  /// button appears once there's a query.
  Widget _searchField(String query) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
    child: Container(
      decoration: BoxDecoration(
        color: AppColors.settingsCard,
        borderRadius: BorderRadius.circular(13),
      ),
      padding: const EdgeInsets.only(left: 14, right: 4),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: AppColors.textTertiary, size: 20),
          const SizedBox(width: 11),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => _settingsCubit.setQuery(v.trim()),
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              cursorColor: AppColors.accent,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                border: InputBorder.none,
                hintText: 'Search settings',
                hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
          if (query.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                _searchCtrl.clear();
                _settingsCubit.setQuery('');
                FocusScope.of(context).unfocus();
              },
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.close_rounded,
                  color: AppColors.textSecondary,
                  size: 18,
                ),
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SettingsScreenTv();
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final activeId = context.watch<ActiveSourceCubit>().state;
    final connectedCount = <Tracker>[
      sl<AniListService>(),
      sl<MalService>(),
      sl<SimklService>(),
    ].where((t) => t.isConnected).length;

    // Single source of truth for both the grouped list and the search filter.
    final entries = <_SettingsEntry>[
      // Account & sync
      _SettingsEntry(
        section: 'Account & sync',
        icon: Icons.sync_alt_rounded,
        title: 'Connections',
        subtitle: connectedCount > 0
            ? '$connectedCount connected'
            : 'AniList, MyAnimeList, Simkl',
        keywords: 'anilist myanimelist mal simkl tracker sync account login connect',
        onTap: () async {
          await _push(const ConnectionsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: 'Account & sync',
        icon: Icons.gamepad_outlined,
        title: 'Discord',
        subtitle: 'Rich Presence — show your status',
        keywords: 'discord rich presence status rpc',
        onTap: () async {
          await _push(const DiscordSettingsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: 'Account & sync',
        icon: Icons.groups_2_outlined,
        title: 'Watch Party',
        subtitle: 'Create or join a watch party with friends',
        keywords: 'watch party together sync friends room',
        onTap: () {
          if (sl<AuthCubit>().state.user == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sign in to watch together')),
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WatchPartyLobbyScreen()),
          );
        },
      ),
      _SettingsEntry(
        section: 'Account & sync',
        icon: Icons.cloud_upload_outlined,
        title: 'Sync library to cloud',
        subtitle: 'Re-upload history & list to this account',
        keywords:
            'sync cloud upload library history continue watching list device '
            'cross-device re-sync fix restore',
        onTap: () async {
          if (sl<AuthCubit>().state.user == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sign in first')),
            );
            return;
          }
          // The session may have lapsed (logged-in from cache only). Get a live
          // one first — otherwise every upsert silently no-ops ("Synced 0").
          final live = await ensureLiveSession(context);
          if (!context.mounted) return;
          if (!live) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Reconnect to sync your library.')),
            );
            return;
          }
          final messenger = ScaffoldMessenger.of(context);
          messenger
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(content: Text('Syncing your library to cloud…')),
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
                      ? 'Your library is already synced to this account.'
                      : 'Synced $h history + $l list items to your account.',
                ),
              ),
            );
        },
      ),
      _SettingsEntry(
        section: 'Account & sync',
        icon: Icons.cloud_sync_outlined,
        title: 'Backup & Restore',
        subtitle: 'Save your sources, list & settings',
        keywords: 'backup restore export import save cloud',
        onTap: () => _push(const BackupScreen()),
      ),
      // Sources
      _SettingsEntry(
        section: 'Sources',
        icon: Icons.dns_rounded,
        title: 'Providers',
        subtitle: '$enabledCount enabled',
        keywords: 'providers sources extensions plugins cloudstream aniyomi repository',
        onTap: () async {
          await _push(const SourcesScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: 'Sources',
        icon: Icons.swap_horiz_rounded,
        title: 'Active source',
        subtitle: _activeLabel(activeId),
        keywords: 'active source default provider switch',
        // The one coral accent here: an "active" dot before the chevron.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            _AccentDot(),
            SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
              size: 20,
            ),
          ],
        ),
        onTap: _pickActiveSource,
      ),
      _SettingsEntry(
        section: 'Sources',
        icon: Icons.health_and_safety_outlined,
        title: 'Source health',
        subtitle: 'Test which sources are working',
        keywords: 'source health test working dead status check',
        onTap: () => _push(const SourceHealthScreen()),
      ),
      if (Platform.isAndroid)
        _SettingsEntry(
          section: 'Sources',
          icon: Icons.update_rounded,
          title: 'Source updates',
          subtitle: 'Notify when installed sources have updates',
          keywords: 'source updates notify extensions upgrade',
          trailing: Switch.adaptive(
            value: sl<CloudStreamManager>().notifyUpdates,
            activeThumbColor: AppColors.accent,
            onChanged: (v) async {
              await sl<CloudStreamManager>().setNotifyUpdates(v);
              if (mounted) setState(() {});
            },
          ),
        ),
      _SettingsEntry(
        section: 'Sources',
        icon: Icons.autorenew_rounded,
        title: 'Auto-update extensions',
        subtitle: 'Update installed sources automatically on launch',
        keywords:
            'auto update extensions sources plugins automatic upgrade cloudstream aniyomi',
        trailing: Switch.adaptive(
          value: sl<PlaybackPrefs>().autoUpdateExtensions,
          activeThumbColor: AppColors.accent,
          onChanged: (v) async {
            await sl<PlaybackPrefs>().setAutoUpdateExtensions(v);
            if (mounted) setState(() {});
          },
        ),
      ),
      // Playback & downloads
      _SettingsEntry(
        section: 'Playback',
        icon: Icons.play_circle_outline,
        title: 'Playback',
        subtitle: 'Quality, autoplay, speed',
        keywords: 'playback quality autoplay speed player decoder audio subtitle resume gesture',
        onTap: () => _push(const PlaybackSettingsScreen()),
      ),
      _SettingsEntry(
        section: 'Reading',
        icon: Icons.menu_book_outlined,
        title: 'Reader',
        subtitle: 'Manga & novel reading defaults',
        keywords:
            'reader manga novel reading defaults fit direction fontsize theme orientation preload',
        onTap: () => _push(const ReaderSettingsScreen()),
      ),
      _SettingsEntry(
        section: 'History',
        icon: Icons.history_rounded,
        title: 'History',
        subtitle: 'Shows you\'ve watched',
        keywords: 'history watch watched continue recent resume',
        onTap: () async {
          await _push(const HistoryScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: 'Downloads',
        icon: Icons.download_outlined,
        title: 'Downloads',
        subtitle: 'Manage your downloaded episodes',
        keywords: 'downloads offline episodes save manage',
        onTap: () => _push(const DownloadsScreen()),
      ),
      _SettingsEntry(
        section: 'Downloads',
        icon: Icons.sd_storage_outlined,
        title: 'Storage',
        subtitle: 'Manage space used by the app',
        keywords: 'storage space cache clear disk usage',
        onTap: () => _push(const StorageSettingsScreen()),
      ),
      _SettingsEntry(
        section: 'Downloads',
        icon: Icons.downloading_outlined,
        title: 'Torrents',
        subtitle: 'Streaming & data settings',
        keywords: 'torrent magnet streaming seed data wifi',
        onTap: () => _push(const TorrentSettingsScreen()),
      ),
      // Interface & notifications
      _SettingsEntry(
        section: 'Interface',
        icon: Icons.palette_outlined,
        title: 'Appearance',
        subtitle: 'Accent colour',
        keywords:
            'appearance accent colour color theme highlight personalise',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _value(ThemeController.accentLabel),
            const SizedBox(width: 10),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.hairline),
              ),
            ),
          ],
        ),
        onTap: () => _push(const AppearanceScreen()),
      ),
      _SettingsEntry(
        section: 'Interface',
        icon: Icons.grid_view_rounded,
        title: 'Search layout',
        subtitle: 'How cross-source results are shown',
        keywords: 'search layout grid list results view interface',
        trailing: _value(sl<SearchPrefs>().layout.label),
        onTap: _pickSearchLayout,
      ),
      _SettingsEntry(
        section: 'Interface',
        icon: Icons.download_rounded,
        title: 'Batch download style',
        subtitle: 'How the multi-episode sheet looks',
        keywords:
            'batch download style sheet minimal classic wheel episodes multi',
        trailing: _value(
          sl<PlaybackPrefs>().batchDownloadStyle == 'minimal'
              ? 'Minimal'
              : 'Classic',
        ),
        onTap: _pickBatchDownloadStyle,
      ),
      if (Platform.isAndroid)
        _SettingsEntry(
          section: 'Notifications',
          icon: Icons.notifications_none_rounded,
          title: 'Notifications',
          subtitle: 'New-episode alerts for subscribed shows',
          keywords: 'notifications alerts new episode subscribe airing',
          onTap: () => _push(const SubscriptionsScreen()),
        ),
      // Advanced
      if (Platform.isAndroid)
        _SettingsEntry(
          section: 'Advanced',
          icon: Icons.vpn_lock_outlined,
          title: 'DNS',
          subtitle: 'Bypass ISP blocks on CS sources',
          keywords: 'dns cloudflare google adguard quad9 isp block bypass private',
          trailing: _value(
            _dnsChoice == CsDns.off ? 'Off' : CsDns.labelFor(_dnsChoice),
          ),
          onTap: _pickDns,
        ),
      _SettingsEntry(
        section: 'Advanced',
        icon: Icons.shield_outlined,
        title: 'Privacy',
        subtitle: 'NSFW sources',
        keywords: 'privacy nsfw adult content hide 18',
        onTap: () async {
          await _push(const PrivacySettingsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: 'Advanced',
        icon: Icons.bug_report_outlined,
        title: 'Share logs',
        subtitle: 'Send a diagnostic log to help fix an issue',
        keywords: 'logs share diagnostic debug bug report crash',
        onTap: _shareLogs,
      ),
      // About — a single destination holding the app info, contributors,
      // social links, updates, beta toggle and support (so the section opens
      // straight to it — no nested "About" sub-page).
      _SettingsEntry(
        section: 'About',
        icon: Icons.info_outline_rounded,
        title: 'About',
        subtitle: 'v$kAppVersion',
        keywords: 'about version app info license developers credits team '
            'contributors social discord telegram how it works guide '
            'check updates upgrade latest beta prerelease support donate coffee',
        onTap: () => _push(const AboutSettingsScreen()),
      ),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      // bottom: false — the shell's floating dock overlays the content
      // (extendBody); a full SafeArea would clip the list at the dock's top
      // edge, leaving a dead band on both sides of the capsule.
      body: SafeArea(
        bottom: false,
        child: BlocConsumer<SettingsCubit, SettingsState>(
          bloc: _settingsCubit,
          // Hide the shell's floating dock while a section sub-page is open, so
          // it reads as a full page. The shell also gates on the active tab.
          listener: (context, s) {
            dockHiddenBySection.value = s.openSection != null;
            // When a section or search is open our PopScope owns Back — tell the
            // shell to stand down so it doesn't also fire the exit toast.
            shellBackIntercepted.value =
                s.openSection != null || s.query.isNotEmpty;
          },
          builder: (context, s) {
            final section = s.openSection;
            final query = s.query;
            final children = <Widget>[];
            if (section != null) {
              // Drill-down: a back header, then just this section's rows
              // (lead row accent-tinted).
              final items =
                  entries.where((e) => e.section == section).toList();
              children
                ..add(_sectionHeader(section))
                ..add(
                  SettingsCard(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        items[i].toTile(iconAccent: i == 0),
                    ],
                  ),
                );
            } else {
              children
                ..add(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                    child: _settingsWordmark(size: 30),
                  ),
                )
                ..add(_searchField(query));
              if (query.isEmpty) {
                // Browse view: account row + one tappable row per section.
                children
                  ..add(_accountCard(context))
                  ..addAll(_categoryRows(entries));
              } else {
                // Search cuts across every section (unchanged behaviour).
                children.addAll(_buildSettingsList(entries, query));
              }
            }
            return PopScope(
              // Top level with no search → back leaves Settings. Otherwise
              // intercept: a section backs out to the categories, a search
              // clears first.
              canPop: section == null && query.isEmpty,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (section != null) {
                  _settingsCubit.back();
                } else if (query.isNotEmpty) {
                  _searchCtrl.clear();
                  _settingsCubit.setQuery('');
                  FocusScope.of(context).unfocus();
                }
              },
              // Slide the drill-down in like a real pushed page (matching the
              // native transition you get opening e.g. Providers). Keyed by
              // which "page" is showing so the switcher animates category↔section
              // but NOT search-as-you-type (both are the same '_root' key).
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: CustomScrollView(
                  key: ValueKey(section ?? '_root'),
                  slivers: [
                    SliverPadding(
                      // Bottom: clear the floating dock (its height arrives as
                      // MediaQuery bottom padding thanks to extendBody).
                      padding: EdgeInsets.only(
                        bottom: 24 + MediaQuery.paddingOf(context).bottom,
                      ),
                      sliver: SliverList.list(children: children),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static const _sectionOrder = <String>[
    'Account & sync',
    'Sources',
    'Playback',
    'Reading',
    'History',
    'Downloads',
    'Interface',
    'Notifications',
    'Advanced',
    'About',
  ];

  /// Renders [entries] grouped by section. When there's a query, only matching
  /// entries survive; sections that end up empty are dropped, and an empty
  /// result shows a "no matches" line.
  List<Widget> _buildSettingsList(List<_SettingsEntry> entries, String query) {
    final q = query.toLowerCase();
    final out = <Widget>[];
    var first = true;
    for (final section in _sectionOrder) {
      final items = entries
          .where((e) => e.section == section && (q.isEmpty || e.matches(q)))
          .toList();
      if (items.isEmpty) continue;
      out.add(SettingsSectionLabel(section, first: first));
      first = false;
      out.add(
        SettingsCard(
          children: [
            for (var i = 0; i < items.length; i++)
              items[i].toTile(iconAccent: i == 0),
          ],
        ),
      );
    }
    if (out.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 40, 22, 40),
          child: Center(
            child: Text(
              'No settings match "${_searchCtrl.text}"',
              style: AppText.body.copyWith(color: AppColors.textTertiary),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// One tappable row per section (browse view). Each drills into the section's
  /// sub-page. Built from the same [entries], so counts/conditionals stay in
  /// sync — an empty section (e.g. all-Android entries on iOS) is skipped.
  List<Widget> _categoryRows(List<_SettingsEntry> entries) {
    final tiles = <Widget>[];
    for (final section in _sectionOrder) {
      final items = entries.where((e) => e.section == section).toList();
      if (items.isEmpty) continue;
      tiles.add(
        SettingsTile(
          icon: _sectionIcon(section),
          title: section,
          subtitle: _sectionSummary(section),
          iconAccent: tiles.isEmpty, // accent the lead row
          // A section with a single destination (Playback, History,
          // Notifications) opens it directly — no redundant one-row sub-page.
          onTap: items.length == 1
              ? items.first.onTap
              : () => _settingsCubit.open(section),
        ),
      );
    }
    return [SettingsCard(children: tiles)];
  }

  /// Compact app-bar-style header for a section sub-page: a small back chevron
  /// + an 18px title with a hairline underneath (replaces the oversized title).
  Widget _sectionHeader(String section) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary,
                size: 18,
              ),
              onPressed: _settingsCubit.back,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                section,
                style: AppText.headline.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Divider(height: 1, thickness: 1, color: AppColors.hairline),
        const SizedBox(height: 14),
      ],
    ),
  );

  IconData _sectionIcon(String section) => switch (section) {
    'Account & sync' => Icons.person_outline_rounded,
    'Sources' => Icons.dns_rounded,
    'Playback' => Icons.play_circle_outline_rounded,
    'Reading' => Icons.menu_book_outlined,
    'History' => Icons.history_rounded,
    'Downloads' => Icons.download_outlined,
    'Interface' => Icons.tune_rounded,
    'Notifications' => Icons.notifications_none_rounded,
    'Advanced' => Icons.build_outlined,
    'About' => Icons.info_outline_rounded,
    _ => Icons.settings_outlined,
  };

  String _sectionSummary(String section) => switch (section) {
    'Account & sync' => 'Trackers, Discord, backup, sync',
    'Sources' => 'Providers, active source, updates',
    'Playback' => 'Quality, autoplay, speed',
    'Reading' => 'Manga & novel reader defaults',
    'History' => 'Shows you\'ve watched',
    'Downloads' => 'Downloads, storage, torrents',
    'Interface' => 'Appearance, search layout',
    'Notifications' => 'New-episode alerts',
    'Advanced' => 'DNS, privacy, logs',
    'About' => 'Updates, support, version',
    _ => '',
  };

  /// "Settings" with a coral "." — used both big (the scroll-away title) and
  /// small (the centered nav-bar title that fades in on collapse).
  Widget _settingsWordmark({required double size}) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: size,
          letterSpacing: -0.5,
        ),
        children: [
          TextSpan(text: 'Settings'),
          TextSpan(text: '.', style: TextStyle(color: AppColors.accent)),
        ],
      ),
    );
  }
}

/// The 6px coral "active source" dot.
class _AccentDot extends StatelessWidget {
  const _AccentDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      color: AppColors.accent,
      shape: BoxShape.circle,
    ),
  );
}

/// One searchable settings row — the single source of truth for both the
/// grouped list and the "Search settings" filter.
class _SettingsEntry {
  const _SettingsEntry({
    required this.section,
    required this.icon,
    required this.title,
    this.subtitle,
    this.keywords = '',
    this.trailing,
    this.onTap,
  });

  final String section;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Extra search terms (synonyms) that never render but widen matches.
  final String keywords;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// [q] is already lower-cased by the caller.
  bool matches(String q) =>
      '$title ${subtitle ?? ''} $keywords $section'.toLowerCase().contains(q);

  SettingsTile toTile({bool iconAccent = false}) => SettingsTile(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailing: trailing,
    onTap: onTap,
    iconAccent: iconAccent,
  );
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

  int _cacheBytes = 0;
  bool _shadersReady = ShaderPresets.downloaded;
  bool _shaderDownloading = false;
  double _shaderProgress = 0;

  // The main picker: Off + the three filters. The GPU tier (Mid/High) is a
  // separate row below.
  static const List<(String, String)> _shaderStyleOptions = [
    ('off', 'Off'),
    ('a', 'Sharpen — clean 1080p sources'),
    ('b', 'De-blur — blurry / soft sources'),
    ('c', 'Denoise — grainy / compressed'),
  ];
  static const List<(String, String)> _shaderTierOptions = [
    ('mid', 'Mid-range GPU — light, smooth'),
    ('high', 'High-end GPU — heavier, sharpest'),
  ];

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
    ShaderPresets.refreshDownloaded().then((v) {
      if (mounted) setState(() => _shadersReady = v);
    });
  }

  // ── Video enhancement (GLSL upscaling shaders, downloaded on demand) ────────
  Future<void> _downloadShaders() async {
    if (_shaderDownloading) return;
    setState(() {
      _shaderDownloading = true;
      _shaderProgress = 0;
    });
    final ok = await ShaderPresets.download(
      onProgress: (p) {
        if (mounted) setState(() => _shaderProgress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _shaderDownloading = false;
      _shadersReady = ok;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shader download failed — check network')),
      );
    } else {
      // Default to Sharpen so the download has an immediate, visible effect.
      if (_prefs.videoShaderStyle == 'off') {
        await _prefs.setVideoShaderStyle('a');
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickShaderStyle() async {
    final picked = await _pick<String>(
      title: 'Anime4K Enhancement',
      options: _shaderStyleOptions,
      current: _prefs.videoShaderStyle,
    );
    if (picked == null) return;
    await _prefs.setVideoShaderStyle(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickShaderTier() async {
    final picked = await _pick<String>(
      title: 'Anime4K GPU tier',
      options: _shaderTierOptions,
      current: _prefs.videoShaderTier,
    );
    if (picked == null) return;
    await _prefs.setVideoShaderTier(picked);
    if (mounted) setState(() {});
  }


  Future<void> _loadCacheSize() async {
    final n = await MediaCache.sizeBytes();
    if (mounted) setState(() => _cacheBytes = n);
  }

  Future<void> _clearCache() async {
    await MediaCache.clear();
    await _loadCacheSize();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Cache cleared')));
  }

  static const List<(String, String)> _bufferSizeOptions = [
    ('low', 'Low (32 MB) — low-RAM / TV'),
    ('default', 'Default (128 MB)'),
    ('high', 'High (512 MB) — smoother'),
  ];
  static const List<(String, String)> _bufferLengthOptions = [
    ('low', 'Low (15s) — low-RAM / TV'),
    ('default', 'Default (60s)'),
    ('high', 'High (120s) — smoother'),
  ];

  Future<void> _pickBufferSize() async {
    final picked = await _pick<String>(
      title: 'Video buffer size',
      options: _bufferSizeOptions,
      current: _prefs.videoBufferSize,
    );
    if (picked == null) return;
    await _prefs.setVideoBufferSize(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickBufferLength() async {
    final picked = await _pick<String>(
      title: 'Video buffer length',
      options: _bufferLengthOptions,
      current: _prefs.videoBufferLength,
    );
    if (picked == null) return;
    await _prefs.setVideoBufferLength(picked);
    if (mounted) setState(() {});
  }

  /// Multi-select of which fields the in-player info overlay shows.
  Future<void> _pickPlayerInfo() async {
    final selected = _prefs.playerInfoFields.toSet();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Player info overlay', style: AppText.headline),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Pick what shows over the video (appears with the '
                    'controls). Like YouTube\'s "Stats for nerds".',
                    style: AppText.caption,
                  ),
                ),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final f in kPlayerInfoFields)
                        CheckboxListTile(
                          value: selected.contains(f.$1),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(f.$1);
                            } else {
                              selected.remove(f.$1);
                            }
                          }),
                          title: Text(f.$2, style: AppText.body),
                          activeColor: AppColors.accent,
                          controlAffinity: ListTileControlAffinity.trailing,
                          dense: true,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    // Persist the ticked fields in canonical (display) order.
    final ordered = [
      for (final f in kPlayerInfoFields)
        if (selected.contains(f.$1)) f.$1,
    ];
    await _prefs.setPlayerInfoFields(ordered);
    if (mounted) setState(() {});
  }

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

  static const List<(String, String)> _decoderOptions = [
    ('copy', 'Hardware+ (recommended)'),
    ('direct', 'Hardware (faster)'),
    ('sw', 'Software (most compatible)'),
    ('auto', 'Auto'),
  ];

  // How mpv paints the video. Only worth changing when the video is black but
  // the audio and controls work — that's the GPU renderer failing on a device
  // whose driver can't run it, and no source or decoder change will help.
  // MediaCodec Embed skips that renderer entirely (the decoder draws straight
  // to the surface), at the cost of Anime4K and burned-in subtitle styling.
  static const List<(String, String)> _rendererOptions = [
    ('auto', 'Auto (recommended)'),
    ('gpu', 'GPU — standard renderer'),
    ('gpu-next', 'GPU Next — Vulkan, experimental'),
    ('mediacodec_embed', 'MediaCodec Embed — fixes black video'),
  ];

  static const List<(String, String)> _closeConfirmOptions = [
    ('double_back', 'Double back — press back twice to exit'),
    ('confirm', 'Close confirmation — ask before leaving'),
    ('direct', 'Close directly — exit immediately'),
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
      isScrollControlled: true,
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
            // Scroll a long option list (e.g. the ~25-language "Translate to"
            // picker) instead of overflowing the sheet. Short lists
            // (quality/decoder) stay shorter than the cap, so shrinkWrap sizes
            // them to their content and they look unchanged.
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final (value, label) in options)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, value),
                        title: Text(
                          label,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: value == current
                            ? Icon(Icons.check, color: AppColors.accent)
                            : null,
                      ),
                  ],
                ),
              ),
            ),
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

  Future<void> _pickDecoder() async {
    final picked = await _pick<String>(
      title: 'Video decoder',
      options: _decoderOptions,
      current: _prefs.videoDecoder,
    );
    if (picked == null) return;
    await _prefs.setVideoDecoder(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickRenderer() async {
    final picked = await _pick<String>(
      title: 'Video renderer',
      options: _rendererOptions,
      current: _prefs.videoOutput,
    );
    if (picked == null) return;
    await _prefs.setVideoOutput(picked);
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

  Future<void> _pickCloseConfirmation() async {
    final picked = await _pick<String>(
      title: 'Close confirmation',
      options: _closeConfirmOptions,
      current: _prefs.closeConfirmation,
    );
    if (picked == null) return;
    await _prefs.setCloseConfirmation(picked);
    if (mounted) setState(() {});
  }

  // TV picker options for MegaSkip duration (the phone uses the inline slider).
  static const List<(int, String)> _megaSkipDurationOptions = [
    (10, '10s'),
    (15, '15s'),
    (30, '30s'),
    (60, '60s'),
    (85, '85s'),
    (90, '90s'),
    (120, '120s'),
    (180, '180s'),
  ];

  Future<void> _pickMegaSkipDuration() async {
    final picked = await _pick<int>(
      title: 'MegaSkip duration',
      options: _megaSkipDurationOptions,
      current: _prefs.megaSkipSeconds,
    );
    if (picked == null) return;
    await _prefs.setMegaSkipSeconds(picked);
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
    // A SettingsTile with a trailing Switch — identical geometry (icon inset,
    // size, gap, right padding) to every other row, so icons and labels line up
    // in one clean column. subtitleMaxLines:null lets long descriptions wrap.
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: null,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.accent,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
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
      appBar: settingsAppBar('Playback'),
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
              // Video decoder + Anime4K are mpv-renderer-only — the native TV
              // player (ExoPlayer) ignores them, so hide them on TV.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.memory_outlined,
                  title: 'Video decoder',
                  subtitle: _labelFor(
                    _decoderOptions,
                    _prefs.videoDecoder,
                    'Hardware+ (recommended)',
                  ),
                  onTap: _pickDecoder,
                ),
              // Escape hatch for black video with working audio — see
              // _rendererOptions. Takes effect on the next player open (mpv
              // can't swap its video output on a live player).
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.display_settings_outlined,
                  title: 'Video renderer',
                  subtitle: _labelFor(
                    _rendererOptions,
                    _prefs.videoOutput,
                    'Auto (recommended)',
                  ),
                  onTap: _pickRenderer,
                ),
              // Anime4K GLSL upscaling — downloaded on demand. One row = Off /
              // Mid / High (GPU tier). Anime-tuned; may over-sharpen live action.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Anime4K Enhancement',
                  subtitle: _shaderDownloading
                      ? 'Downloading… ${(_shaderProgress * 100).round()}%'
                      : (!_shadersReady
                            ? 'Tap to download shaders (~0.8 MB)'
                            : ShaderPresets.styleById(
                                _prefs.videoShaderStyle,
                              ).label),
                  trailing: _shaderDownloading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _shaderDownloading
                      ? null
                      : (!_shadersReady ? _downloadShaders : _pickShaderStyle),
                ),
              if (!sl<AppMode>().isTv &&
                  _shadersReady &&
                  _prefs.videoShaderStyle != 'off')
                SettingsTile(
                  icon: Icons.speed_outlined,
                  title: 'Anime4K GPU tier',
                  subtitle: ShaderPresets.tierLabel(_prefs.videoShaderTier),
                  onTap: _pickShaderTier,
                ),
            ],
          ),

          // ── Player (external app handoff — Android) ─────────────────────
          // External-player handoff is phone-only; the TV plays in its own
          // native player, so hide this whole section on TV.
          if (Platform.isAndroid && !sl<AppMode>().isTv) ...[
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
                icon: Icons.playlist_add_check_rounded,
                title: 'Auto-add to My List',
                subtitle: 'Add a title to My List when you start watching it',
                value: _prefs.autoAddToMyList,
                onChanged: (v) async {
                  await _prefs.setAutoAddToMyList(v);
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile(
                icon: Icons.exit_to_app_outlined,
                title: 'Close confirmation',
                subtitle: switch (_prefs.closeConfirmation) {
                  'confirm' => 'Ask before leaving the player',
                  'direct' => 'Exit immediately',
                  _ => 'Press back twice to exit',
                },
                onTap: _pickCloseConfirmation,
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
                title: 'Auto-skip filler episodes',
                subtitle: 'On autoplay, jump past filler (anime only)',
                value: _prefs.autoSkipFiller,
                onChanged: (v) async {
                  await _prefs.setAutoSkipFiller(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.movie_outlined,
                title: 'Autoplay trailer',
                subtitle: 'Play a title\'s trailer on its detail page',
                value: _prefs.autoplayTrailer,
                onChanged: (v) async {
                  await _prefs.setAutoplayTrailer(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: 'Play trailers in HD',
                subtitle: 'Up to 1080p when available — falls back to standard '
                    'if not. Uses more data',
                value: _prefs.trailerHd,
                onChanged: (v) async {
                  await _prefs.setTrailerHd(v);
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
                icon: Icons.fast_forward_rounded,
                title: 'Auto-skip opening',
                subtitle: 'Jump past the OP on its own, no tap',
                value: _prefs.autoSkipOp,
                onChanged: (v) async {
                  await _prefs.setAutoSkipOp(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: 'Auto-skip ending',
                subtitle: 'Jump past the ED on its own, no tap',
                value: _prefs.autoSkipEd,
                onChanged: (v) async {
                  await _prefs.setAutoSkipEd(v);
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
              // On TV the inline slider traps D-pad focus (↑/↓ change the value
              // instead of moving on), so use a picker row there instead.
              if (_prefs.megaSkip)
                sl<AppMode>().isTv
                    ? SettingsTile(
                        icon: Icons.timer_outlined,
                        title: 'MegaSkip duration',
                        subtitle: '${_prefs.megaSkipSeconds}s',
                        onTap: _pickMegaSkipDuration,
                      )
                    : _megaSkipDurationRow(),
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen on',
                value: _prefs.keepScreenOn,
                onChanged: (v) async {
                  await _prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
              if (sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.tv_outlined,
                  title: 'Native TV player',
                  subtitle: 'Recommended. Turn off only if you prefer the old '
                      'player',
                  value: _prefs.nativeTvPlayer,
                  onChanged: (v) async {
                    await _prefs.setNativeTvPlayer(v);
                    if (mounted) setState(() {});
                  },
                ),
              if (sl<AppMode>().isTv && _prefs.nativeTvPlayer)
                _toggleRow(
                  icon: Icons.surround_sound_outlined,
                  title: 'Software audio (Dolby/DTS)',
                  subtitle: 'Turn on only if Dolby/DTS audio is silent — may be '
                      'unstable on some TVs',
                  value: _prefs.tvSoftwareDecoding,
                  onChanged: (v) async {
                    await _prefs.setTvSoftwareDecoding(v);
                    if (mounted) setState(() {});
                  },
                ),
              // Seek preview (online) removed — the streaming engine was flaky
              // and re-downloaded video just for thumbnails. Download-file
              // previews still work (instant + free), so no toggle is needed.
              /*
              _toggleRow(
                icon: Icons.image_outlined,
                title: 'Seek preview (online)',
                subtitle: 'Thumbnails while scrubbing streams — costs extra data',
                value: _prefs.seekPreviewOnline,
                onChanged: (v) async {
                  await _prefs.setSeekPreviewOnline(v);
                  if (mounted) setState(() {});
                },
              ),
              */
              if (Platform.isAndroid && !sl<AppMode>().isTv)
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
              SettingsTile(
                icon: Icons.info_outline_rounded,
                title: 'Player info overlay',
                subtitle: _prefs.playerInfoFields.isEmpty
                    ? 'Off'
                    : '${_prefs.playerInfoFields.length} fields (ⓘ button)',
                onTap: _pickPlayerInfo,
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: 'Show quality label',
                subtitle: 'Plain quality text (e.g. 1080p) on the top-bar right',
                value: _prefs.alwaysShowQuality,
                onChanged: (v) async {
                  await _prefs.setAlwaysShowQuality(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),

          // ── Gestures (touch-only — hidden on TV) ────────────────────────
          if (!sl<AppMode>().isTv) ...[
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
          ],

          // ── Cache (buffering + clear) ───────────────────────────────────
          const SettingsSectionLabel('Cache'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.memory_rounded,
                title: 'Video buffer size',
                subtitle: _labelFor(
                  _bufferSizeOptions,
                  _prefs.videoBufferSize,
                  'Default (128 MB)',
                ),
                onTap: _pickBufferSize,
              ),
              SettingsTile(
                icon: Icons.timelapse_rounded,
                title: 'Video buffer length',
                subtitle: _labelFor(
                  _bufferLengthOptions,
                  _prefs.videoBufferLength,
                  'Default (60s)',
                ),
                onTap: _pickBufferLength,
              ),
              SettingsTile(
                icon: Icons.delete_outline_rounded,
                title: 'Clear image & video cache',
                subtitle: MediaCache.formatBytes(_cacheBytes),
                onTap: _clearCache,
              ),
            ],
          ),

          // ── Subtitles ───────────────────────────────────────────────────
          const SettingsSectionLabel('Subtitles'),
          SettingsCard(
            children: [
              // libass is the mpv renderer's .ass styling — the native TV
              // player styles subtitles via ExoPlayer instead, so hide on TV.
              if (!sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.subtitles_outlined,
                  title: 'Styled subtitles (libass)',
                  subtitle: 'Real .ass styling — fonts, positions, karaoke, '
                      'signs. Best for anime. Applies from the next episode.',
                  value: _prefs.styledSubtitles,
                  onChanged: (v) async {
                    await _prefs.setStyledSubtitles(v);
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile(
                icon: Icons.text_fields_rounded,
                title: 'Subtitle style',
                subtitle: 'Font, colour, outline, opacity, size, position — '
                    'with live preview',
                onTap: () => openSubtitleStyleSheet(
                  context,
                  null,
                  () {
                    if (mounted) setState(() {});
                  },
                ),
              ),
              SettingsTile(
                icon: Icons.vpn_key_outlined,
                title: 'OpenSubtitles API key',
                subtitle: _prefs.subtitleApiKey.trim().isEmpty
                    ? 'Required for online subtitle search'
                    : 'Key saved — online search enabled',
                onTap: _editSubtitleApiKey,
              ),
              SettingsTile(
                icon: Icons.language_outlined,
                title: 'Subtitle language',
                subtitle: () {
                  final p = _prefs.subtitlePreference;
                  if (p.isEmpty) return 'Auto';
                  if (p == 'off') return 'Off';
                  return languageByPref(p)?.name ?? p.toUpperCase();
                }(),
                onTap: _pickSubtitleLanguage,
              ),
              _toggleRow(
                icon: Icons.download_outlined,
                title: 'Auto-download subtitles',
                subtitle:
                    'When the source has no subtitle in your language',
                value: _prefs.autoDownloadSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoDownloadSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.translate_outlined,
                title: 'Auto-translate subtitles',
                subtitle:
                    'Translate to your language on play (when the source has none)',
                value: _prefs.autoTranslateSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoTranslateSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              if (_prefs.autoTranslateSubtitles)
                SettingsTile(
                  icon: Icons.g_translate_outlined,
                  title: 'Translate subtitles to',
                  subtitle: _prefs.translateSubtitleTo.isEmpty
                      ? 'Pick a language'
                      : (languageByPref(_prefs.translateSubtitleTo)?.name ??
                            _prefs.translateSubtitleTo.toUpperCase()),
                  onTap: _pickTranslateLanguage,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickTranslateLanguage() async {
    final picked = await _pick<String>(
      title: 'Translate subtitles to',
      options: [for (final l in kSubtitleLanguages) (l.iso1, l.name)],
      current: _prefs.translateSubtitleTo,
    );
    if (picked == null) return;
    await _prefs.setTranslateSubtitleTo(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSubtitleLanguage() async {
    final picked = await showSubtitleLanguagePicker(
      context,
      _prefs.subtitlePreference,
    );
    if (picked == null) return; // dismissed
    await _prefs.setSubtitlePreference(picked);
    if (mounted) setState(() {});
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
      appBar: settingsAppBar('Storage'),
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

class AboutSettingsScreen extends StatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  State<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends State<AboutSettingsScreen> {
  static const String _websiteUrl = 'https://zangetsu.online';
  static const String _telegramUrl = 'https://t.me/+9mQlsdvDlo83Mjk1';
  static const String _discordUrl = 'https://discord.gg/938JJBn44';
  static const String _githubUrl = 'https://github.com/Spyou/Zangetsu';

  final UpdateService _updateService = UpdateService();
  bool _betaUpdates = false;

  @override
  void initState() {
    super.initState();
    _updateService.betaOptIn().then((v) {
      if (mounted) setState(() => _betaUpdates = v);
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('About'),
      body: ListView(
        padding: const EdgeInsets.only(top: 24, bottom: 30),
        children: [
          const _ProfileCard(),
          const SizedBox(height: 24),
          // Contributors — above Social, opens the full list.
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.group_rounded,
                title: 'Contributors',
                onTap: () => _push(const ContributorsScreen()),
              ),
            ],
          ),
          const SettingsSectionLabel('Social', muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.language_rounded,
                title: 'Website',
                subtitle: 'zangetsu.online',
                onTap: () => _open(_websiteUrl),
              ),
              SettingsTile(
                icon: Icons.send_rounded,
                title: 'Telegram',
                subtitle: 'Community chat',
                onTap: () => _open(_telegramUrl),
              ),
              SettingsTile(
                icon: Icons.discord,
                title: 'Discord',
                subtitle: 'Join the server',
                onTap: () => _open(_discordUrl),
              ),
              SettingsTile(
                icon: Icons.code_rounded,
                title: 'GitHub',
                subtitle: 'View the source code',
                onTap: () => _open(_githubUrl),
              ),
            ],
          ),
          const SettingsSectionLabel('App', muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.help_outline_rounded,
                title: 'How it works',
                subtitle: 'New here? A quick guide',
                onTap: () => _push(const HowItWorksScreen()),
              ),
              SettingsTile(
                icon: Icons.system_update_rounded,
                title: 'Check for updates',
                subtitle: 'Get the latest version from GitHub',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Checking for updates…')),
                  );
                  maybeShowUpdateDialog(context, manual: true);
                },
              ),
              SettingsTile(
                icon: Icons.science_outlined,
                title: 'Beta updates',
                subtitle: 'Get pre-release builds early — may be unstable',
                subtitleMaxLines: null,
                trailing: Switch.adaptive(
                  value: _betaUpdates,
                  activeThumbColor: AppColors.accent,
                  onChanged: (v) async {
                    // Turning it on: confirm first so it's never a silent opt-in.
                    if (v && !await confirmJoinBeta(context)) return;
                    await _updateService.setBetaOptIn(v);
                    if (!mounted) return;
                    setState(() => _betaUpdates = v);
                    // Then check right away so a waiting beta shows up.
                    if (v && context.mounted) {
                      maybeShowUpdateDialog(context, manual: true);
                    }
                  },
                ),
              ),
              SettingsTile(
                icon: Icons.favorite_border_rounded,
                title: 'Support the app',
                subtitle: 'Buy me a coffee',
                onTap: () => _push(const DonateScreen()),
              ),
            ],
          ),
          const SizedBox(height: 24),
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

/// The app header: the clean logo mark, name and version floating on the page
/// (no grey box), then the lead-developer card.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 6),
        Image.asset('assets/icon/logo_mark.png', height: 96),
        const SizedBox(height: 16),
        Text(kAppName, style: AppText.largeTitle.copyWith(fontSize: 25)),
        const SizedBox(height: 3),
        Text(
          'v$kAppVersion',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 20),
        const _DeveloperRow(),
      ],
    );
  }
}

/// The "Developer" row inside the profile card.
class _DeveloperRow extends StatelessWidget {
  const _DeveloperRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final uri = Uri.parse('https://github.com/spyou');
            if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
              await launchUrl(uri, mode: LaunchMode.platformDefault);
            }
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              // One solid dark grey, matching the app's cards.
              color: AppColors.settingsCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const TeamAvatar(
                  url: 'https://github.com/spyou.png?size=200',
                  name: 'Krishna',
                  size: 46,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Krishna Vishwakarma',
                        style: AppText.headline.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Lead Developer',
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.code_rounded, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
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
      appBar: settingsAppBar('Connections'),
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
  bool get _nsfwAni => sl<PlaybackPrefs>().showNsfwAniyomi;

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

  Future<void> _onNsfwAniChanged(bool value) async {
    final prefs = sl<PlaybackPrefs>();
    if (value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Show NSFW Aniyomi sources?', style: AppText.title),
          content: Text(
            'This shows Aniyomi extensions flagged as 18+ in the source list '
            'and switcher. Only turn this on if you want adult content.',
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
      await prefs.setShowNsfwAniyomi(true);
    } else {
      await prefs.setShowNsfwAniyomi(false);
      _demoteNsfwAniActiveSource();
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

  /// When the Aniyomi NSFW toggle is turned off and the active source is an
  /// NSFW Aniyomi provider, switch to the first non-NSFW enabled source.
  void _demoteNsfwAniActiveSource() {
    final active = sl<ActiveSourceCubit>();
    if (!active.state.startsWith('ani:')) return;
    final aniManager = sl<AniyomiManager>();
    final currentProvider = aniManager.get(active.state);
    if (currentProvider is! AniyomiProvider || !currentProvider.info.nsfw) {
      return;
    }
    // Try another non-NSFW Aniyomi source first.
    for (final p in aniManager.all) {
      if (p is AniyomiProvider && !p.info.nsfw) {
        active.setSource(p.sourceId);
        return;
      }
    }
    // Fall back to first enabled JS source.
    final registry = sl<ProviderRegistry>();
    for (final e in registry.getAll()) {
      if (e.enabled) {
        active.setSource(e.name);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Privacy'),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.visibility_off_outlined,
                title: 'Incognito mode',
                subtitle: 'Pause history, tracking & Discord presence',
                trailing: ValueListenableBuilder<bool>(
                  valueListenable: IncognitoMode.notifier,
                  builder: (_, on, _) => Switch.adaptive(
                    value: on,
                    activeThumbColor: AppColors.accent,
                    onChanged: (v) => IncognitoMode.set(v),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Text(
              'While on, searches, watch history, tracker scrobbling and Discord '
              'presence are paused — nothing is recorded until you turn it off.',
              style: AppText.caption,
            ),
          ),
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
              SettingsTile(
                icon: Icons.extension_outlined,
                title: 'Show NSFW sources',
                subtitle: 'Adult Aniyomi extensions',
                trailing: Switch.adaptive(
                  value: _nsfwAni,
                  activeThumbColor: AppColors.accent,
                  onChanged: _onNsfwAniChanged,
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

/// Text-entry dialog for the OpenSubtitles API key. Returns the entered string
/// on save (empty clears the key) or null when dismissed. Owns its own
/// [TextEditingController] and disposes it on unmount (after the route's exit
/// animation) — avoids the "used after dispose" crash a caller-owned controller
/// disposed right after `await showDialog` would hit.
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

