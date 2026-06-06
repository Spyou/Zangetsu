import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/ui/settings_widgets.dart';

/// Connect / disconnect any [Tracker] (AniList, MyAnimeList, Simkl) and toggle
/// its auto-sync. Connecting opens the provider's OAuth consent in the browser;
/// the token returns via the `zangetsu://…` deep link captured by the service.
class TrackerSettingsScreen extends StatefulWidget {
  const TrackerSettingsScreen({super.key, required this.tracker});

  final Tracker tracker;

  @override
  State<TrackerSettingsScreen> createState() => _TrackerSettingsScreenState();
}

class _TrackerSettingsScreenState extends State<TrackerSettingsScreen> {
  Tracker get _t => widget.tracker;
  bool _busy = false;

  Future<void> _connect() async {
    setState(() => _busy = true);
    final ok = await _t.connect();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Connected as ${_t.viewerName}'
              : '${_t.displayName} connection canceled',
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Disconnect ${_t.displayName}?'),
        content: Text(
          'Auto-sync will stop. Your ${_t.displayName} account is not changed — '
          'you can reconnect anytime.',
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
    if (ok == true) await _t.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(_t.displayName),
      ),
      body: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final connected = _t.isConnected;
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              _header(connected),
              if (!connected)
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.link_rounded,
                      title: _busy ? 'Connecting…' : 'Connect ${_t.displayName}',
                      subtitle: _busy ? null : 'Sign in to link your account',
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
                      icon: Icons.sync_rounded,
                      title: 'Auto-sync',
                      subtitle: 'Update ${_t.displayName} as you watch',
                      trailing: Switch.adaptive(
                        value: _t.autoSync,
                        activeThumbColor: AppColors.accent,
                        onChanged: (v) => setState(() => _t.autoSync = v),
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
                  'When you start an anime it’s marked Watching, each '
                  'episode you finish updates the count, and a status you set on '
                  'a title is pushed to ${_t.displayName}. Anime only.',
                  style: AppText.caption,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(bool connected) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (connected && (_t.viewerAvatar?.isNotEmpty ?? false))
            ClipOval(
              child: CachedNetworkImage(
                imageUrl: _t.viewerAvatar!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _fallbackAvatar(),
              ),
            )
          else
            _fallbackAvatar(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? (_t.viewerName ?? _t.displayName) : _t.displayName,
                  style: AppText.headline.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  connected ? 'Connected' : 'Not connected',
                  style: AppText.caption.copyWith(
                    color: connected ? AppColors.accent : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackAvatar() => Container(
    width: 52,
    height: 52,
    decoration: const BoxDecoration(
      color: AppColors.surface2,
      shape: BoxShape.circle,
    ),
    child: const Icon(Icons.person_rounded, color: AppColors.textTertiary),
  );
}
