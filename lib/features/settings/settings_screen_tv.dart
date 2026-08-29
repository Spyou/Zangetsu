import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/search_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/cs_dns.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
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

/// TV Settings list: same sections as the phone [SettingsScreen]. Tappable
/// rows use the TV-aware [SettingsTile] (white pill focus). Pickers open
/// D-pad dialogs. Sub-screens inherit focus from shared [SettingsTile] /
/// [SettingsCard] widgets.
class SettingsScreenTv extends StatefulWidget {
  const SettingsScreenTv({super.key});

  @override
  State<SettingsScreenTv> createState() => _SettingsScreenTvState();
}

class _SettingsScreenTvState extends State<SettingsScreenTv> {
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
        title: 'DNS',
        options: CsDns.labels.entries.map((e) => (e.key, e.value)).toList(),
        current: _dnsChoice,
      ),
    );
    if (picked == null || picked == _dnsChoice) return;
    await CsDns.set(picked);
    if (mounted) setState(() => _dnsChoice = picked);
  }

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

  Future<void> _addCloudStreamRepo() async {
    final url = await showDialog<String>(context: context, builder: (_) => const _TvAddRepoDialog());
    if (url == null || url.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await _csManager.addRepo(url);
      messenger.showSnackBar(SnackBar(content: Text('Added — $count CloudStream source(s) available')));
      if (mounted) setState(() {});
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to add repository: $e')));
    }
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 24, 48, 16),
              child: Text('Settings', style: AppText.largeTitle),
            ),
            Expanded(
              child: ListView(
                clipBehavior: Clip.none,
                padding: const EdgeInsets.only(top: 4, bottom: 24),

                children: [
                  _accountCard(context),
                  const SizedBox(height: 8),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.cloud_sync_outlined,
                        title: 'Backup & Restore',
                        subtitle: 'Save your sources, list & settings',
                        onTap: () => _push(const BackupScreen()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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
                        onTap: _pickActiveSourceTv,
                      ),
                      SettingsTile(
                        icon: Icons.health_and_safety_outlined,
                        title: 'Source health',
                        subtitle: 'Test which sources are working',
                        onTap: () => _push(const SourceHealthScreen()),
                      ),
                      if (Platform.isAndroid) ...[
                        SettingsTile(
                          icon: Icons.extension_outlined,
                          title: 'Add CloudStream repository',
                          subtitle: 'Install CloudStream sources',
                          onTap: _addCloudStreamRepo,
                        ),
                        SettingsTile(
                          icon: Icons.vpn_lock_outlined,
                          title: 'DNS',
                          subtitle: _dnsChoice == CsDns.off
                              ? 'Off · bypass ISP blocks on CS sources'
                              : CsDns.labelFor(_dnsChoice),
                          onTap: _pickDnsTv,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.help_outline_rounded,
                        title: 'How it works',
                        subtitle: 'New here? A quick guide',
                        onTap: () => _push(const HowItWorksScreen()),
                      ),
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
                        onTap: _pickSearchLayoutTv,
                      ),
                      if (Platform.isAndroid) ...[
                        SettingsTile(
                          icon: Icons.notifications_none_rounded,
                          title: 'Notifications',
                          subtitle: 'New-episode alerts for subscribed shows',
                          onTap: () => _push(const SubscriptionsScreen()),
                        ),
                        SettingsTile(
                          icon: Icons.update_rounded,
                          title: 'Source updates',
                          subtitle: 'Notify when installed sources have updates',
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
                          icon: Icons.science_outlined,
                          title: 'Beta updates',
                          subtitle: 'Get pre-release builds early — may be unstable',
                          subtitleMaxLines: null,
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
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sd_storage_outlined,
                        title: 'Storage',
                        onTap: () => _push(const StorageSettingsScreen()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sync_alt_rounded,
                        title: 'Connections',
                        subtitle: 'AniList, MyAnimeList, Simkl',
                        onTap: () async {
                          await _push(const ConnectionsScreenTv());
                          if (mounted) setState(() {});
                        },
                      ),
                      if (!isAppleTv)
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
                  const SizedBox(height: 8),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.coffee_rounded,
                        title: 'Support the app',
                        subtitle: 'Buy me a coffee',
                        onTap: () => _push(const DonateScreen()),
                      ),
                      SettingsTile(
                        icon: Icons.system_update_rounded,
                        title: 'Check for updates',
                        subtitle: 'Get the latest version from GitHub',
                        onTap: () {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('Checking for updates…')));
                          maybeShowUpdateDialog(context, manual: true);
                        },
                      ),
                      if (kExoSpikeEnabled)
                        SettingsTile(
                          icon: Icons.speed_rounded,
                          title: 'ExoPlayer spike (dev)',
                          subtitle: 'SP0 — test SurfaceView playback smoothness',
                          onTap: () => _push(const TvExoSpikeScreen()),
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

/// D-pad option picker dialog (DNS / search layout).
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

class _TvAddRepoDialog extends StatefulWidget {
  const _TvAddRepoDialog();

  @override
  State<_TvAddRepoDialog> createState() => _TvAddRepoDialogState();
}

class _TvAddRepoDialogState extends State<_TvAddRepoDialog> {
  final _controller = TextEditingController();
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
              decoration: const InputDecoration(labelText: 'Repository URL', hintText: 'https://.../repo.json'),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
          ],
        ),
      ),
      actions: [
        TvFocusable(
          variant: TvFocusVariant.pill,
          onTap: () => Navigator.pop(context),
          semanticLabel: 'Cancel',
          builder: (focused) => ExcludeSemantics(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: AppText.body.copyWith(color: focused ? Colors.black : AppColors.textSecondary),
              ),
            ),
          ),
        ),
        TvFocusable(
          variant: TvFocusVariant.pill,
          onTap: () => Navigator.pop(context, _controller.text.trim()),
          semanticLabel: 'Add',
          builder: (focused) => ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: focused ? Colors.black : AppColors.accent,
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
