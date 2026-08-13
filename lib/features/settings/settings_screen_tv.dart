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
import '../../core/update/update_service.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../backup/backup_screen.dart';
import '../downloads/downloads_screen.dart';
import '../notify/subscriptions_screen.dart';
import '../onboarding/how_it_works.dart';
import '../player/tv_exo_spike_screen.dart';
import '../sources/source_health_screen.dart';
import '../sources/sources_screen.dart';
import '../update/update_dialog.dart';
import 'connections_screen_tv.dart';
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

  final UpdateService _updateService = UpdateService();
  bool _betaUpdates = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      CsDns.get().then((c) {
        if (mounted) setState(() => _dnsChoice = c);
      });
    }
    _updateService.betaOptIn().then((v) {
      if (mounted) setState(() => _betaUpdates = v);
    });
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
              TvFocusable(scale: 1.0,
                autofocus: true,
                onTap: () => _push(const ProfileScreen()),
                semanticLabel: auth.displayName,
                // Whole tile is excluded — semanticLabel above is the one
                // announcement (name only, not the email subtitle).
                child: ExcludeSemantics(
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
              ),
            ],
          );
        }
        // Guest state
        return SettingsCard(
          children: [
            TvFocusable(scale: 1.0,
              autofocus: true,
              onTap: () => _push(const LoginScreen()),
              semanticLabel: 'Sign in',
              child: const ExcludeSemantics(
                child: SettingsTile(
                  icon: Icons.person_outline_rounded,
                  title: 'Sign in',
                  subtitle: 'Sync your list & continue watching',
                  trailing: _kChevron,
                ),
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

                  // ── Backup & Restore ────────────────────────────────────
                  // Watch Party is intentionally phone-only: on TV a party
                  // forces the mobile Flutter player, which the native TV player
                  // exists to replace, and chat needs a keyboard.
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const BackupScreen()),
                        semanticLabel: 'Backup & Restore',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.cloud_sync_outlined,
                            title: 'Backup & Restore',
                            subtitle: 'Save your sources, list & settings',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // ── Sources ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () async {
                          await _push(const SourcesScreen());
                          if (mounted) setState(() {});
                        },
                        semanticLabel: 'Providers',
                        child: ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.dns_rounded,
                            title: 'Providers',
                            subtitle: '$enabledCount enabled',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: _pickActiveSourceTv,
                        semanticLabel: 'Active source',
                        child: ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.swap_horiz_rounded,
                            title: 'Active source',
                            subtitle: _activeLabel(activeId),
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const SourceHealthScreen()),
                        semanticLabel: 'Source health',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.health_and_safety_outlined,
                            title: 'Source health',
                            subtitle: 'Test which sources are working',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      if (Platform.isAndroid) ...[
                        TvFocusable(scale: 1.0,
                          onTap: _addCloudStreamRepo,
                          semanticLabel: 'Add CloudStream repository',
                          child: const ExcludeSemantics(
                            child: SettingsTile(
                              icon: Icons.extension_outlined,
                              title: 'Add CloudStream repository',
                              subtitle: 'Install CloudStream sources',
                              trailing: _kChevron,
                            ),
                          ),
                        ),
                        TvFocusable(scale: 1.0,
                          onTap: _pickDnsTv,
                          semanticLabel: 'DNS',
                          child: ExcludeSemantics(
                            child: SettingsTile(
                              icon: Icons.vpn_lock_outlined,
                              title: 'DNS',
                              subtitle: _dnsChoice == CsDns.off
                                  ? 'Off · bypass ISP blocks on CS sources'
                                  : CsDns.labelFor(_dnsChoice),
                              trailing: _kChevron,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // ── App ─────────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const HowItWorksScreen()),
                        semanticLabel: 'How it works',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.help_outline_rounded,
                            title: 'How it works',
                            subtitle: 'New here? A quick guide',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const PlaybackSettingsScreen()),
                        semanticLabel: 'Playback',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.play_circle_outline,
                            title: 'Playback',
                            subtitle: 'Quality, autoplay, speed',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const DownloadsScreen()),
                        semanticLabel: 'Downloads',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.download_outlined,
                            title: 'Downloads',
                            subtitle: 'Watch offline',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: _pickSearchLayoutTv,
                        semanticLabel: 'Search layout',
                        child: ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.search_rounded,
                            title: 'Search layout',
                            subtitle: sl<SearchPrefs>().layout.label,
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      if (Platform.isAndroid) ...[
                        TvFocusable(scale: 1.0,
                          onTap: () => _push(const SubscriptionsScreen()),
                          semanticLabel: 'Notifications',
                          child: const ExcludeSemantics(
                            child: SettingsTile(
                              icon: Icons.notifications_none_rounded,
                              title: 'Notifications',
                              subtitle: 'New-episode alerts for subscribed shows',
                              trailing: _kChevron,
                            ),
                          ),
                        ),
                        // Toggle: OK flips the setting; Switch shows current state.
                        TvFocusable(scale: 1.0,
                          onTap: () async {
                            final cm = sl<CloudStreamManager>();
                            await cm.setNotifyUpdates(!cm.notifyUpdates);
                            if (mounted) setState(() {});
                          },
                          semanticLabel: 'Source updates, '
                              '${sl<CloudStreamManager>().notifyUpdates ? 'on' : 'off'}',
                          // Whole tile excluded, including the Switch — its
                          // on/off state is already in semanticLabel above.
                          child: ExcludeSemantics(
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
                        ),
                        TvFocusable(scale: 1.0,
                          onTap: () async {
                            final v = !_betaUpdates;
                            if (v && !await confirmJoinBeta(context)) return;
                            await _updateService.setBetaOptIn(v);
                            if (!mounted) return;
                            setState(() => _betaUpdates = v);
                            if (v && context.mounted) {
                              maybeShowUpdateDialog(context, manual: true);
                            }
                          },
                          semanticLabel:
                              'Beta updates, ${_betaUpdates ? 'on' : 'off'}',
                          child: ExcludeSemantics(
                            child: SettingsTile(
                              icon: Icons.science_outlined,
                              title: 'Beta updates',
                              subtitle:
                                  'Get pre-release builds early — may be unstable',
                              subtitleMaxLines: null,
                              trailing: Switch.adaptive(
                                value: _betaUpdates,
                                activeThumbColor: AppColors.accent,
                                onChanged: (v) async {
                                  if (v && !await confirmJoinBeta(context)) {
                                    return;
                                  }
                                  await _updateService.setBetaOptIn(v);
                                  if (!mounted) return;
                                  setState(() => _betaUpdates = v);
                                  if (v && context.mounted) {
                                    maybeShowUpdateDialog(context, manual: true);
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // ── Storage ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const StorageSettingsScreen()),
                        semanticLabel: 'Storage',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.sd_storage_outlined,
                            title: 'Storage',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // ── Connections ─────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () async {
                          await _push(const ConnectionsScreenTv());
                          if (mounted) setState(() {});
                        },
                        semanticLabel: 'Connections',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.sync_alt_rounded,
                            title: 'Connections',
                            subtitle: 'AniList, MyAnimeList, Simkl',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () async {
                          await _push(const DiscordSettingsScreen());
                          if (mounted) setState(() {});
                        },
                        semanticLabel: 'Discord',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.gamepad_outlined,
                            title: 'Discord',
                            subtitle: 'Rich Presence — show your status',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () async {
                          await _push(const PrivacySettingsScreen());
                          if (mounted) setState(() {});
                        },
                        semanticLabel: 'Privacy',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.shield_outlined,
                            title: 'Privacy',
                            subtitle: 'NSFW sources',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // ── Support ─────────────────────────────────────────────
                  SettingsCard(
                    children: [
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const DonateScreen()),
                        semanticLabel: 'Support the app',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.coffee_rounded,
                            title: 'Support the app',
                            subtitle: 'Buy me a coffee',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      TvFocusable(scale: 1.0,
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Checking for updates…'),
                            ),
                          );
                          maybeShowUpdateDialog(context, manual: true);
                        },
                        semanticLabel: 'Check for updates',
                        child: const ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.system_update_rounded,
                            title: 'Check for updates',
                            subtitle: 'Get the latest version from GitHub',
                            trailing: _kChevron,
                          ),
                        ),
                      ),
                      if (kExoSpikeEnabled)
                        TvFocusable(
                          scale: 1.0,
                          onTap: () => _push(const TvExoSpikeScreen()),
                          semanticLabel: 'ExoPlayer spike (dev)',
                          child: const ExcludeSemantics(
                            child: SettingsTile(
                              icon: Icons.speed_rounded,
                              title: 'ExoPlayer spike (dev)',
                              subtitle: 'SP0 — test SurfaceView playback smoothness',
                            ),
                          ),
                        ),
                      TvFocusable(scale: 1.0,
                        onTap: () => _push(const AboutSettingsScreen()),
                        semanticLabel: 'About',
                        child: ExcludeSemantics(
                          child: SettingsTile(
                            icon: Icons.info_outline_rounded,
                            title: 'About',
                            subtitle: 'v$kAppVersion',
                            trailing: _kChevron,
                          ),
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
              TvFocusable(scale: 1.0,
                // Autofocus on the current value so D-pad lands there on open.
                autofocus: options[i].$1 == current,
                onTap: () => Navigator.of(context).pop(options[i].$1),
                semanticLabel: options[i].$2,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(options[i].$2, style: AppText.headline),
                        ),
                        if (options[i].$1 == current)
                          Icon(
                            Icons.check,
                            color: AppColors.accent,
                            size: 20,
                          ),
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
  // Not auto-focused on purpose: auto-focusing the field would raise the
  // leanback IME and cover the dialog. D-pad to the field + OK to type a URL.
  final _focusNode = FocusNode();

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
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
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
          ],
        ),
      ),
      actions: [
        TvFocusable(scale: 1.0,
          onTap: () => Navigator.pop(context),
          semanticLabel: 'Cancel',
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
        TvFocusable(scale: 1.0,
          onTap: () => Navigator.pop(context, _controller.text.trim()),
          semanticLabel: 'Add',
          child: ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, _controller.text.trim()),
              child: const Text('Add'),
            ),
          ),
        ),
      ],
    );
  }
}
