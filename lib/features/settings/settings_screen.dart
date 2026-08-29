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
import 'nav_tabs_screen.dart';
import 'reader_settings_screen.dart';
import 'discord_settings_screen.dart';
import 'torrent_settings_screen.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/locale/app_language_picker.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/subtitle_language_picker.dart';
import '../../core/theme/app_text.dart';
import '../../core/update/update_service.dart';
import '../update/update_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/tv/tv_list_focusable.dart';
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
import 'player_controls_screen.dart';
import 'settings_screen_tv.dart';
import 'cubit/settings_cubit.dart';

part 'settings_playback.dart';
part 'settings_storage.dart';
part 'settings_about.dart';
part 'settings_connections.dart';
part 'settings_privacy.dart';

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
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotExportLogs)),
        );
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
      builder: (ctx) {
        final sheetL10n = ctx.l10n;
        return SafeArea(
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
                child: Text(sheetL10n.dns, style: AppText.headline),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  sheetL10n.dnsBlurb,
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
      );
      },
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
      builder: (ctx) {
        final sheetL10n = ctx.l10n;
        return SafeArea(
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
                child: Text(sheetL10n.searchLayout, style: AppText.headline),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  sheetL10n.searchLayoutBlurb,
                  style: AppText.caption,
                ),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            for (final l in SearchLayout.values)
              ListTile(
                title: Text(l.localizedLabel(ctx), style: AppText.body),
                trailing: l == prefs.layout
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, l),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
      },
    );
    if (picked == null) return;
    await prefs.setLayout(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickBatchDownloadStyle() async {
    final prefs = sl<PlaybackPrefs>();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sheetL10n = ctx.l10n;
        final options = <(String, String, String)>[
          ('classic', sheetL10n.batchDownloadClassic, sheetL10n.batchDownloadClassicBlurb),
          ('minimal', sheetL10n.batchDownloadMinimal, sheetL10n.batchDownloadMinimalBlurb),
        ];
        return SafeArea(
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
                child: Text(sheetL10n.batchDownloadStyle, style: AppText.headline),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  sheetL10n.batchDownloadStyleBlurb,
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
      );
      },
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
            title: context.l10n.signIn,
            subtitle: context.l10n.signInSubtitle,
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                context.l10n.signIn,
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
                hintText: context.l10n.settingsSearchHint,
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
    final l10n = context.l10n;
    final connectedCount = <Tracker>[
      sl<AniListService>(),
      sl<MalService>(),
      sl<SimklService>(),
    ].where((t) => t.isConnected).length;

    // Single source of truth for both the grouped list and the search filter.
    final entries = <_SettingsEntry>[
      // Account & sync
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.sync_alt_rounded,
        title: l10n.connections,
        subtitle: connectedCount > 0
            ? l10n.connectedCount(connectedCount)
            : l10n.connectionsTvSubtitle,
        keywords: l10n.connectionsTvSubtitle.toLowerCase(),
        onTap: () async {
          await _push(const ConnectionsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.gamepad_outlined,
        title: l10n.discord,
        subtitle: l10n.discordSubtitle,
        keywords: 'discord rich presence',
        onTap: () async {
          await _push(const DiscordSettingsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.groups_2_outlined,
        title: l10n.watchParty,
        subtitle: l10n.watchPartySubtitle,
        keywords: 'watch party together',
        onTap: () {
          if (sl<AuthCubit>().state.user == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.signInToWatchTogether)),
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WatchPartyLobbyScreen()),
          );
        },
      ),
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.cloud_upload_outlined,
        title: l10n.syncLibraryToCloud,
        subtitle: l10n.syncLibraryToCloudSubtitle,
        keywords:
            'sync cloud upload library history continue watching list device '
            'cross-device re-sync fix restore',
        onTap: () async {
          if (sl<AuthCubit>().state.user == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.signInFirst)),
            );
            return;
          }
          // The session may have lapsed (logged-in from cache only). Get a live
          // one first — otherwise every upsert silently no-ops ("Synced 0").
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
        },
      ),
      _SettingsEntry(
        section: SettingsSection.account,
        icon: Icons.cloud_sync_outlined,
        title: l10n.backupAndRestore,
        subtitle: l10n.backupAndRestoreSubtitle,
        keywords: 'backup restore export import save cloud',
        onTap: () => _push(const BackupScreen()),
      ),
      // Sources
      _SettingsEntry(
        section: SettingsSection.sources,
        icon: Icons.dns_rounded,
        title: l10n.providers,
        subtitle: l10n.providersEnabledCount(enabledCount),
        keywords: 'providers sources extensions plugins cloudstream aniyomi repository',
        onTap: () async {
          await _push(const SourcesScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.sources,
        icon: Icons.swap_horiz_rounded,
        title: l10n.activeSource,
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
        section: SettingsSection.sources,
        icon: Icons.health_and_safety_outlined,
        title: l10n.sourceHealth,
        subtitle: l10n.sourceHealthSubtitle,
        keywords: 'source health test working dead status check',
        onTap: () => _push(const SourceHealthScreen()),
      ),
      if (Platform.isAndroid)
        _SettingsEntry(
          section: SettingsSection.sources,
          icon: Icons.update_rounded,
          title: l10n.sourceUpdates,
          subtitle: l10n.sourceUpdatesSubtitle,
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
        section: SettingsSection.sources,
        icon: Icons.autorenew_rounded,
        title: l10n.autoUpdateExtensions,
        subtitle: l10n.autoUpdateExtensionsSubtitle,
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
        section: SettingsSection.playback,
        icon: Icons.play_circle_outline,
        title: l10n.playback,
        subtitle: l10n.playbackSubtitle,
        keywords: 'playback quality autoplay speed player decoder audio subtitle resume gesture',
        onTap: () => _push(const PlaybackSettingsScreen()),
      ),
      _SettingsEntry(
        section: SettingsSection.reading,
        icon: Icons.menu_book_outlined,
        title: l10n.reader,
        subtitle: l10n.readerSubtitle,
        keywords:
            'reader manga novel reading defaults fit direction fontsize theme orientation preload',
        onTap: () => _push(const ReaderSettingsScreen()),
      ),
      _SettingsEntry(
        section: SettingsSection.history,
        icon: Icons.history_rounded,
        title: l10n.history,
        subtitle: l10n.historySubtitle,
        keywords: 'history watch watched continue recent resume',
        onTap: () async {
          await _push(const HistoryScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.downloads,
        icon: Icons.download_outlined,
        title: l10n.downloads,
        subtitle: l10n.downloadsSubtitle,
        keywords: 'downloads offline episodes save manage',
        onTap: () => _push(const DownloadsScreen()),
      ),
      _SettingsEntry(
        section: SettingsSection.downloads,
        icon: Icons.sd_storage_outlined,
        title: l10n.storage,
        subtitle: l10n.storageSubtitle,
        keywords: 'storage space cache clear disk usage',
        onTap: () => _push(const StorageSettingsScreen()),
      ),
      _SettingsEntry(
        section: SettingsSection.downloads,
        icon: Icons.downloading_outlined,
        title: l10n.torrents,
        subtitle: l10n.torrentsSubtitle,
        keywords: 'torrent magnet streaming seed data wifi',
        onTap: () => _push(const TorrentSettingsScreen()),
      ),
      // Interface & notifications
      _SettingsEntry(
        section: SettingsSection.interface,
        icon: Icons.palette_outlined,
        title: l10n.appearance,
        subtitle: l10n.appearanceSubtitle,
        keywords:
            'appearance accent colour color theme highlight personalise '
            'quality badge poster 4k hd cam',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _value(themeAccentLabel(l10n)),
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
        section: SettingsSection.interface,
        icon: Icons.language_rounded,
        title: l10n.appLanguage,
        subtitle: l10n.appLanguageSubtitle,
        keywords: l10n.appLanguageKeywords,
        trailing: _value(appLanguageValueLabel(context)),
        onTap: () async {
          await pickAppLanguagePhone(context);
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.interface,
        icon: Icons.dashboard_customize_outlined,
        title: l10n.navigationBar,
        subtitle: l10n.navigationBarSubtitle,
        keywords: 'navigation bar tabs dock bottom reorder hide downloads '
            'history customise customize interface',
        onTap: () => _push(const NavTabsScreen()),
      ),
      _SettingsEntry(
        section: SettingsSection.interface,
        icon: Icons.grid_view_rounded,
        title: l10n.searchLayout,
        subtitle: l10n.searchLayoutSubtitle,
        keywords: 'search layout grid list results view interface',
        trailing: _value(sl<SearchPrefs>().layout.localizedLabel(context)),
        onTap: _pickSearchLayout,
      ),
      _SettingsEntry(
        section: SettingsSection.interface,
        icon: Icons.download_rounded,
        title: l10n.batchDownloadStyle,
        subtitle: l10n.batchDownloadStyleSubtitle,
        keywords:
            'batch download style sheet minimal classic wheel episodes multi',
        trailing: _value(
          sl<PlaybackPrefs>().batchDownloadStyle == 'minimal'
              ? l10n.batchDownloadMinimal
              : l10n.batchDownloadClassic,
        ),
        onTap: _pickBatchDownloadStyle,
      ),
      if (Platform.isAndroid)
        _SettingsEntry(
          section: SettingsSection.notifications,
          icon: Icons.notifications_none_rounded,
          title: l10n.notifications,
          subtitle: l10n.notificationsSubtitle,
          keywords: 'notifications alerts new episode subscribe airing',
          onTap: () => _push(const SubscriptionsScreen()),
        ),
      // Advanced
      if (Platform.isAndroid)
        _SettingsEntry(
          section: SettingsSection.advanced,
          icon: Icons.vpn_lock_outlined,
          title: l10n.dns,
          subtitle: l10n.dnsSubtitle,
          keywords: 'dns cloudflare google adguard quad9 isp block bypass private',
          trailing: _value(
            _dnsChoice == CsDns.off ? l10n.off : CsDns.labelFor(_dnsChoice),
          ),
          onTap: _pickDns,
        ),
      _SettingsEntry(
        section: SettingsSection.advanced,
        icon: Icons.shield_outlined,
        title: l10n.privacy,
        subtitle: l10n.privacySubtitle,
        keywords: 'privacy nsfw adult content hide 18',
        onTap: () async {
          await _push(const PrivacySettingsScreen());
          if (mounted) setState(() {});
        },
      ),
      _SettingsEntry(
        section: SettingsSection.advanced,
        icon: Icons.bug_report_outlined,
        title: l10n.shareLogs,
        subtitle: l10n.shareLogsSubtitle,
        keywords: 'logs share diagnostic debug bug report crash',
        onTap: _shareLogs,
      ),
      // About — a single destination holding the app info, contributors,
      // social links, updates, beta toggle and support (so the section opens
      // straight to it — no nested "About" sub-page).
      _SettingsEntry(
        section: SettingsSection.about,
        icon: Icons.info_outline_rounded,
        title: l10n.about,
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

  static const _sectionOrder = SettingsSection.order;

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
      out.add(
        SettingsSectionLabel(
          settingsSectionTitle(context.l10n, section),
          first: first,
        ),
      );
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
              context.l10n.settingsNoMatch(_searchCtrl.text),
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
          icon: settingsSectionIcon(section),
          title: settingsSectionTitle(context.l10n, section),
          subtitle: settingsSectionSummary(context.l10n, section),
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
                settingsSectionTitle(context.l10n, section),
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
          TextSpan(text: context.l10n.settingsTitle),
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
