import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/discord/discord_config.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
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
    ).showSnackBar(const SnackBar(content: Text('Discord connected')));
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Disconnect Discord?'),
        content: const Text(
          'Rich Presence stops and your token is removed from this device. Your '
          'Discord account is not changed — you can reconnect anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Disconnect', style: TextStyle(color: AppColors.accent)),
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
        title: const Text('Discord'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (!DiscordConfig.configured)
            const SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.warning_amber_rounded,
                  title: 'Not configured',
                  subtitle:
                      'A Discord Application ID must be set in the build first.',
                ),
              ],
            ),
          if (!connected)
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.link_rounded,
                  title: _busy ? 'Connecting…' : 'Connect Discord',
                  subtitle: _busy
                      ? null
                      : 'Sign in so your status can show on your profile',
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
                  title: 'Rich Presence',
                  subtitle: "Show what you're watching on your profile",
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
                  title: 'Disconnect',
                  destructive: true,
                  onTap: _disconnect,
                ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Shows “Watching <title> • Episode N” (and what you’re browsing) on '
              'your Discord profile while the app is open. Uses your Discord '
              'login, stored only on this device. Turn off anytime.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
