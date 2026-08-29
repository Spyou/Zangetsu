import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/discord/discord_config.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/settings_widgets.dart';
import 'discord_login_screen.dart';

/// Connect Discord (capture the user token via a WebView login) and toggle Rich
/// Presence. Presence shows what you're watching/browsing on your profile while
/// the app is open. The token lives only in this device's secure storage.
class DiscordSettingsScreen extends StatefulWidget {
  const DiscordSettingsScreen({super.key});

  @override
  State<DiscordSettingsScreen> createState() => _DiscordSettingsScreenState();
}

class _DiscordSettingsScreenState extends State<DiscordSettingsScreen> {
  DiscordRpc get _rpc => sl<DiscordRpc>();
  bool _busy = false;

  Future<void> _connect() async {
    final token = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DiscordLoginScreen()),
    );
    if (token == null || token.isEmpty || !mounted) return;
    setState(() => _busy = true);
    await _rpc.setToken(token);
    await _rpc.setEnabled(true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.discordConnected)));
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.disconnectDiscord),
        content: Text(
          context.l10n.disconnectDiscordBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(context.l10n.disconnect, style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _rpc.setEnabled(false);
    await _rpc.setToken(null);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = _rpc.loggedIn;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.discord),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (!DiscordConfig.configured)
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.warning_amber_rounded,
                  title: context.l10n.notConfigured,
                  subtitle: context.l10n.aDiscordApplicationIDMustBeSetInTheBuildFirst,
                ),
              ],
            ),
          if (!connected)
            SettingsCard(
              children: [
                SettingsTile(
                  autofocus: true,
                  icon: Icons.link_rounded,
                  title: _busy ? context.l10n.connectingEllipsis : context.l10n.connectDiscord,
                  subtitle: _busy
                      ? null
                      : context.l10n.signInSoYourStatusCanShow,
                  onTap: _busy ? null : _connect,
                  trailing: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ],
            )
          else ...[
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.gamepad_outlined,
                  title: context.l10n.richPresence,
                  subtitle: context.l10n.showWhatYouReWatchingOnYourProfile,
                  onTap: () async {
                    await _rpc.setEnabled(!_rpc.enabled);
                    if (mounted) setState(() {});
                  },
                  trailing: Switch.adaptive(
                    value: _rpc.enabled,
                    activeThumbColor: AppColors.accent,
                    onChanged: (v) async {
                      await _rpc.setEnabled(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              context.l10n.discordPresenceBlurb,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
