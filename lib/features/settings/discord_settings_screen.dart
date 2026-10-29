import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/discord/discord_config.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/settings_widgets.dart';

/// Connect Discord (OAuth in the external browser — no token scraping) and
/// toggle Rich Presence. Presence shows what you're watching/browsing on your
/// profile while the app is open. Tokens live only on this device.
class DiscordSettingsScreen extends StatefulWidget {
  const DiscordSettingsScreen({super.key});

  @override
  State<DiscordSettingsScreen> createState() => _DiscordSettingsScreenState();
}

class _DiscordSettingsScreenState extends State<DiscordSettingsScreen> {
  DiscordRpc get _rpc => sl<DiscordRpc>();
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await _rpc.connect();
    } catch (_) {
      _rpc.lastAuthError =
          'Could not complete Discord login. Please try again.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_rpc.lastAuthError ?? 'Discord login failed')),
      );
      return;
    }
    await _rpc.setEnabled(true);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.discordConnected)));
  }

  Future<void> _disconnect() async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.disconnectDiscord,
      message: context.l10n.disconnectDiscordBody,
      confirmLabel: context.l10n.disconnect,
      destructive: true,
    );
    if (ok != true) return;
    await _rpc.logout();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = _rpc.loggedIn;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.discord),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              if (!DiscordConfig.configured)
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.warning_amber_rounded,
                      title: context.l10n.notConfigured,
                      subtitle: context
                          .l10n
                          .aDiscordApplicationIDMustBeSetInTheBuildFirst,
                      subtitleMaxLines: null,
                    ),
                  ],
                ),
              SettingsCard(
                children: [
                  if (connected)
                    SettingsTile(
                      icon: Icons.person_rounded,
                      title: _rpc.displayName.isNotEmpty
                          ? _rpc.displayName
                          : _rpc.username.isNotEmpty
                          ? _rpc.username
                          : context.l10n.discord,
                      subtitle: _rpc.username.isNotEmpty
                          ? '@${_rpc.username}'
                          : null,
                      leading: _rpc.avatarUrl.isNotEmpty
                          ? ClipOval(
                              child: Image.network(
                                _rpc.avatarUrl,
                                width: 42,
                                height: 42,
                                fit: BoxFit.cover,
                                errorBuilder: (_, error, stackTrace) =>
                                    const SizedBox(
                                      width: 42,
                                      height: 42,
                                      child: Icon(Icons.person_rounded),
                                    ),
                              ),
                            )
                          : null,
                    )
                  else
                    SettingsTile(
                      autofocus: true,
                      icon: Icons.link_rounded,
                      iconAccent: true,
                      title: _busy
                          ? context.l10n.connectingEllipsis
                          : context.l10n.connectDiscord,
                      subtitle: _busy
                          ? null
                          : context.l10n.signInSoYourStatusCanShow,
                      subtitleMaxLines: null,
                      onTap: _busy ? null : _connect,
                      trailing: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                    ),
                  if (connected)
                    SettingsTile(
                      autofocus: true,
                      icon: Icons.gamepad_outlined,
                      iconAccent: true,
                      title: context.l10n.richPresence,
                      subtitle: context.l10n.showWhatYouReWatchingOnYourProfile,
                      subtitleMaxLines: null,
                      onTap: () => _setEnabled(!_rpc.enabled),
                      trailing: Switch.adaptive(
                        value: _rpc.enabled,
                        activeThumbColor: AppColors.accent,
                        onChanged: _setEnabled,
                      ),
                    ),
                ],
              ),
              if (connected) ...[
                const SizedBox(height: 12),
                SettingsCard(
                  children: [
                    _switchRow(
                      icon: Icons.pause_circle_outline_rounded,
                      title: context.l10n.presenceShowWhenPaused,
                      value: _rpc.showWhenPaused,
                      preference: 'showPaused',
                    ),
                    _switchRow(
                      icon: Icons.explore_outlined,
                      title: context.l10n.presenceBrowsingTitle,
                      value: _rpc.browsingShowsTitle,
                      preference: 'browsingTitle',
                    ),
                  ],
                ),
              ],
              SettingsSectionLabel(context.l10n.presencePreview, muted: true),
              _preview(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                child: Text(
                  context.l10n.discordPresenceBlurb,
                  style: AppText.caption,
                ),
              ),
              if (connected)
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.logout_rounded,
                      title: context.l10n.disconnect,
                      destructive: true,
                      onTap: _disconnect,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setEnabled(bool value) async {
    await _rpc.setEnabled(value);
    if (mounted) setState(() {});
  }

  SettingsTile _switchRow({
    required IconData icon,
    required String title,
    required bool value,
    required String preference,
  }) {
    Future<void> save(bool next) async {
      await _rpc.setPresencePref(preference, next);
      if (mounted) setState(() {});
    }

    return SettingsTile(
      icon: icon,
      title: title,
      onTap: () => save(!value),
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: AppColors.accent,
        onChanged: save,
      ),
    );
  }

  Widget _preview() {
    const title = 'BLEACH: Thousand-Year Blood War';
    const episode = 'Episode 1 · The Blood Warfare';
    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Watching ${discordSourceLine(_rpc.nameSrc, title: title, episode: episode, appText: DiscordConfig.appName)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 88,
                    height: 88,
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            'https://images.metahub.space/poster/small/tt14986406/img',
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            cacheWidth: 240,
                            excludeFromSemantics: true,
                            errorBuilder: (_, error, stackTrace) => Container(
                              width: 80,
                              height: 80,
                              color: AppColors.surface2,
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.movie_outlined,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: AppColors.settingsCard,
                              shape: BoxShape.circle,
                            ),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/icon/app_icon.png',
                                width: 28,
                                height: 28,
                                excludeFromSemantics: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          discordSourceLine(
                            _rpc.detailsSrc,
                            title: title,
                            episode: episode,
                            appText: DiscordConfig.appName,
                          ),
                          style: AppText.headline.copyWith(height: 1.3),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          discordSourceLine(
                            _rpc.stateSrc,
                            title: title,
                            episode: episode,
                            appText: 'on ${DiscordConfig.appName}',
                          ),
                          style: AppText.body.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: 0.5,
                minHeight: 3,
                borderRadius: BorderRadius.circular(4),
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('12:00', style: AppText.caption),
                  Text('24:00', style: AppText.caption),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  context.l10n.presenceButtonLabelHint,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
