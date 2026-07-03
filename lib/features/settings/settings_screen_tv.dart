import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../downloads/downloads_screen.dart';
import '../notify/subscriptions_screen.dart';
import '../onboarding/how_it_works.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';
import '../update/update_dialog.dart';
import '../watch_together/ui/watch_party_lobby_screen.dart';
import 'developers_screen.dart';
import 'discord_settings_screen.dart';
import 'donate_screen.dart';
import 'settings_screen.dart';
import '../shell/tv_source_picker.dart';

// Shared trailing chevron used on all nav tiles to show navigability even when
// the SettingsTile's own onTap is null (touch-disabled on TV).
const Widget _kChevron = Icon(
  Icons.chevron_right_rounded,
  color: AppColors.textTertiary,
  size: 22,
);

/// TV Settings list: the same sections and SettingsTile rows as the phone
/// [SettingsScreen], but every tile is wrapped in [TvFocusable] so the D-pad
/// navigates the list and OK fires the same action the phone tap fires.
///
/// Pickers (DNS / search-layout / active-source) open D-pad-navigable
/// [showDialog] overlays instead of the phone's touch bottom sheets.
/// Sub-screens (Playback, Storage, Connections, etc.) are pushed as-is —
/// they render their phone layout for now (TV adaptation is a follow-up).
///
/// The phone [SettingsScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const SettingsScreenTv();` branch at the
/// top of [_SettingsScreenState.build].
class SettingsScreenTv extends StatefulWidget {
  const SettingsScreenTv({super.key});

  @override
  State<SettingsScreenTv> createState() => _SettingsScreenTvState();
}

class _SettingsScreenTvState extends State<SettingsScreenTv> {
  /// Mirrors [_SettingsScreenState._dnsChoice] — the in-app DNS provider
  /// currently active for CS sources.
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

  // ── Getters (mirror phone state) ──────────────────────────────────────────

  ActiveSourceCubit get _active => context.read<ActiveSourceCubit>();
  ProviderRegistry get _registry => sl<ProviderRegistry>();
  CloudStreamManager get _csManager => sl<CloudStreamManager>();

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  /// Same logic as phone's [_SettingsScreenState._activeLabel].
  String _activeLabel(String activeId) {
    if (activeId.startsWith('cs:')) {
      return _csManager.get(activeId)?.displayName ?? activeId;
    }
    final entry = _registry.entryFor(activeId);
    if (entry == null) return activeId;
    return entry.displayName.isNotEmpty ? entry.displayName : entry.name;
  }

  // ── TV pickers (replace phone's touch bottom sheets) ──────────────────────

  /// D-pad DNS picker. Replaces [_SettingsScreenState._pickDns] bottom sheet.
  Future<void> _pickDnsTv() async {
    final picked = await showDialog<int>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _TvOptionPicker<int>(
        title: 'DNS',
        options: CsDns.labels.entries.map((e) => (e.key, e.value)).toList(),
        current: _dnsChoice,
      ),
    );
    if (picked == null || picked == _dnsChoice) return;
    await CsDns.set(picked);
    if (mounted) setState(() => _dnsChoice = picked);
  }

  /// D-pad search-layout picker. Replaces [_SettingsScreenState._pickSearchLayout].
  Future<void> _pickSearchLayoutTv() async {
    final prefs = sl<SearchPrefs>();
    final picked = await showDialog<SearchLayout>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _TvOptionPicker<SearchLayout>(
        title: 'Search layout',
        options: SearchLayout.values.map((l) => (l, l.label)).toList(),
        current: prefs.layout,
      ),
    );
    if (picked == null) return;
    await prefs.setLayout(picked);
    if (mounted) setState(() {});
  }

  /// TV active-source picker: reuses [TvSourcePicker] (the same D-pad dialog
  /// the rail source indicator uses). Updates [ActiveSourceCubit] in place.
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

  /// Same CS repo-add flow as the phone. The text-entry dialog works on TV
  /// since Android TV shows a software keyboard when a TextField is focused.
  Future<void> _addCloudStreamRepo() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _TvAddRepoDialog(),
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

  // ── Account card ──────────────────────────────────────────────────────────

  /// The first card in the list. Signed-in: profile tile → ProfileScreen.
  /// Guest: "Sign in" tile → LoginScreen. First TvFocusable carries autofocus.
  Widget _accountCard(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, auth) {
        if (auth.isLoggedIn) {
          final initial = auth.displayName.isNotEmpty
              ? auth.displayName[0].toUpperCase()
              : '?';
          return SettingsCard(
            children: [
              TvFocusable(
                autofocus: true,
                onTap: () => _push(const ProfileScreen()),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.surface2,
                    backgroundImage: auth.avatarUrl != null
                        ? CachedNetworkImageProvider(auth.avatarUrl!)
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
                  trailing: _kChevron,
                  // Touch-disabled on TV; TvFocusable handles OK-key activation.
                  onTap: null,
                ),
              ),
            ],
          );
        }
        // Guest state
        return SettingsCard(
          children: [
            TvFocusable(
              autofocus: true,
              onTap: () => _push(const LoginScreen()),
              child: const SettingsTile(
                icon: Icons.person_outline_rounded,
                title: 'Sign in',
                subtitle: 'Sync your list & continue watching',
                trailing: _kChevron,
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final activeId = context.watch<ActiveSourceCubit>().state;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Page title (wider TV margins)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
              child: Text('Settings', style: AppText.largeTitle),
            ),
            // ── Scrollable settings list
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  // ── Account ─────────────────────────────────────────────
                  _accountCard(context),

                  // ── Watch Party ─────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () {
                          if (sl<AuthCubit>().state.user == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Sign in to watch together'),
                              ),
                            );
                            return;
                          }
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WatchPartyLobbyScreen(),
                            ),
                          );
                        },
                        child: const SettingsTile(
                          icon: Icons.groups_2_outlined,
                          title: 'Watch Party',
                          subtitle: 'Create or join a watch party with friends',
                          trailing: _kChevron,
                        ),
                      ),
                    ],
                  ),

                  // ── Sources ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () async {
                          await _push(const SourcesScreen());
                          if (mounted) setState(() {});
                        },
                        child: SettingsTile(
                          icon: Icons.dns_rounded,
                          title: 'Providers',
                          subtitle: '$enabledCount enabled',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: _pickActiveSourceTv,
                        child: SettingsTile(
                          icon: Icons.swap_horiz_rounded,
                          title: 'Active source',
                          subtitle: _activeLabel(activeId),
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () => _push(const SourceHealthScreen()),
                        child: const SettingsTile(
                          icon: Icons.health_and_safety_outlined,
                          title: 'Source health',
                          subtitle: 'Test which sources are working',
                          trailing: _kChevron,
                        ),
                      ),
                      if (Platform.isAndroid) ...[
                        TvFocusable(
                          onTap: _addCloudStreamRepo,
                          child: const SettingsTile(
                            icon: Icons.extension_outlined,
                            title: 'Add CloudStream repository',
                            subtitle: 'Install CloudStream sources',
                            trailing: _kChevron,
                          ),
                        ),
                        TvFocusable(
                          onTap: _pickDnsTv,
                          child: SettingsTile(
                            icon: Icons.vpn_lock_outlined,
                            title: 'DNS',
                            subtitle: _dnsChoice == CsDns.off
                                ? 'Off · bypass ISP blocks on CS sources'
                                : CsDns.labelFor(_dnsChoice),
                            trailing: _kChevron,
                          ),
                        ),
                      ],
                    ],
                  ),

                  // ── App ─────────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () => _push(const HowItWorksScreen()),
                        child: const SettingsTile(
                          icon: Icons.help_outline_rounded,
                          title: 'How it works',
                          subtitle: 'New here? A quick guide',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () => _push(const PlaybackSettingsScreen()),
                        child: const SettingsTile(
                          icon: Icons.play_circle_outline,
                          title: 'Playback',
                          subtitle: 'Quality, autoplay, speed',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () => _push(const DownloadsScreen()),
                        child: const SettingsTile(
                          icon: Icons.download_outlined,
                          title: 'Downloads',
                          subtitle: 'Watch offline',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: _pickSearchLayoutTv,
                        child: SettingsTile(
                          icon: Icons.search_rounded,
                          title: 'Search layout',
                          subtitle: sl<SearchPrefs>().layout.label,
                          trailing: _kChevron,
                        ),
                      ),
                      if (Platform.isAndroid) ...[
                        TvFocusable(
                          onTap: () => _push(const SubscriptionsScreen()),
                          child: const SettingsTile(
                            icon: Icons.notifications_none_rounded,
                            title: 'Notifications',
                            subtitle: 'New-episode alerts for subscribed shows',
                            trailing: _kChevron,
                          ),
                        ),
                        // Toggle: OK flips the setting; Switch shows current state.
                        TvFocusable(
                          onTap: () async {
                            final cm = sl<CloudStreamManager>();
                            await cm.setNotifyUpdates(!cm.notifyUpdates);
                            if (mounted) setState(() {});
                          },
                          child: SettingsTile(
                            icon: Icons.update_rounded,
                            title: 'Source updates',
                            subtitle:
                                'Notify when installed sources have updates',
                            // onTap null so InkWell is disabled; TvFocusable owns OK.
                            trailing: Switch.adaptive(
                              value: sl<CloudStreamManager>().notifyUpdates,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) async {
                                await sl<CloudStreamManager>().setNotifyUpdates(v);
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // ── Storage ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () => _push(const StorageSettingsScreen()),
                        child: const SettingsTile(
                          icon: Icons.sd_storage_outlined,
                          title: 'Storage',
                          trailing: _kChevron,
                        ),
                      ),
                    ],
                  ),

                  // ── Connections ─────────────────────────────────────────
                  // Note: connectedCount is omitted on TV to avoid importing tracker
                  // services. Static subtitle matches the phone's fallback state.
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () async {
                          await _push(const ConnectionsScreen());
                          if (mounted) setState(() {});
                        },
                        child: const SettingsTile(
                          icon: Icons.sync_alt_rounded,
                          title: 'Connections',
                          subtitle: 'AniList, MyAnimeList, Simkl',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () async {
                          await _push(const DiscordSettingsScreen());
                          if (mounted) setState(() {});
                        },
                        child: const SettingsTile(
                          icon: Icons.gamepad_outlined,
                          title: 'Discord',
                          subtitle: 'Rich Presence — show your status',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () async {
                          await _push(const PrivacySettingsScreen());
                          if (mounted) setState(() {});
                        },
                        child: const SettingsTile(
                          icon: Icons.shield_outlined,
                          title: 'Privacy',
                          subtitle: 'NSFW sources',
                          trailing: _kChevron,
                        ),
                      ),
                    ],
                  ),

                  // ── Support ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(
                        onTap: () => _push(const DonateScreen()),
                        child: const SettingsTile(
                          icon: Icons.coffee_rounded,
                          title: 'Support the app',
                          subtitle: 'Buy me a coffee',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () => _push(const DevelopersScreen()),
                        child: const SettingsTile(
                          icon: Icons.people_outline_rounded,
                          title: 'Developers',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Checking for updates…'),
                            ),
                          );
                          maybeShowUpdateDialog(context, manual: true);
                        },
                        child: const SettingsTile(
                          icon: Icons.system_update_rounded,
                          title: 'Check for updates',
                          subtitle: 'Get the latest version from GitHub',
                          trailing: _kChevron,
                        ),
                      ),
                      TvFocusable(
                        onTap: () => _push(const AboutSettingsScreen()),
                        child: SettingsTile(
                          icon: Icons.info_outline_rounded,
                          title: 'About',
                          subtitle: 'v$kAppVersion',
                          trailing: _kChevron,
                        ),
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

// ── D-pad option picker dialog ────────────────────────────────────────────────

/// Generic D-pad-navigable option picker. Mirrors the phone's bottom-sheet
/// pattern but as a [showDialog] with [TvFocusable] rows. Returns the value
/// the user selected, or null if dismissed with BACK.
///
/// Reused for DNS and Search-layout pickers. Active-source picking uses
/// [TvSourcePicker] directly (it has richer grouping).
class _TvOptionPicker<T> extends StatelessWidget {
  const _TvOptionPicker({
    super.key,
    required this.title,
    required this.options,
    required this.current,
  });

  final String title;

  /// Each entry is (value, display label).
  final List<(T, String)> options;

  /// The currently-selected value; its row gets autofocus when the dialog opens.
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
            // ── Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(
                title,
                style: AppText.title.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            // ── Option rows
            for (int i = 0; i < options.length; i++)
              TvFocusable(
                // Autofocus on the current value so D-pad lands there on open.
                autofocus: options[i].$1 == current,
                onTap: () => Navigator.of(context).pop(options[i].$1),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(options[i].$2, style: AppText.headline),
                      ),
                      if (options[i].$1 == current)
                        const Icon(
                          Icons.check,
                          color: AppColors.accent,
                          size: 20,
                        ),
                    ],
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

// ── CloudStream repo-add dialog ───────────────────────────────────────────────

/// Text-entry dialog for adding a CloudStream repo URL on TV. Functionally
/// identical to the phone's private `_AddRepoDialog`; defined here to avoid a
/// circular import with [SettingsScreen] / [settings_screen.dart].
class _TvAddRepoDialog extends StatefulWidget {
  const _TvAddRepoDialog();

  @override
  State<_TvAddRepoDialog> createState() => _TvAddRepoDialogState();
}

class _TvAddRepoDialogState extends State<_TvAddRepoDialog> {
  final _controller = TextEditingController();
  // Explicit FocusNode + postFrameCallback reliably raises the leanback IME on
  // Android TV, where autofocus: true alone often fails inside an AlertDialog.
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add CloudStream repository', style: AppText.headline),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
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
        TvFocusable(
          scale: 1.0,
          onTap: () => Navigator.pop(context),
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(
          scale: 1.0,
          onTap: () => Navigator.pop(context, _controller.text.trim()),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}
