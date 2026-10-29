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
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
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
                ),
              ],
            ),
          if (!connected)
            SettingsCard(
              children: [
                SettingsTile(
                  autofocus: true,
                  icon: Icons.link_rounded,
                  title: _busy
                      ? context.l10n.connectingEllipsis
                      : context.l10n.connectDiscord,
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
                      ? CircleAvatar(
                          backgroundImage: NetworkImage(_rpc.avatarUrl),
                          backgroundColor: AppColors.surface2,
                        )
                      : null,
                ),
              ],
            ),
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
            SettingsCard(children: _activityRows()),
            SettingsCard(children: _imageRows()),
            SettingsCard(
              children: [
                _switchRow(
                  icon: Icons.open_in_new_rounded,
                  title: context.l10n.presenceShowButton,
                  value: _rpc.showPresenceButton,
                  save: (v) => _rpc.setPresencePref('showButton', v),
                ),
                _optRow(
                  icon: Icons.edit_outlined,
                  title: context.l10n.presenceButtonLabel,
                  value: _rpc.presenceButtonLabel.isNotEmpty
                      ? _rpc.presenceButtonLabel
                      : context.l10n.presenceButtonLabelHint,
                  onTap: _editButtonLabel,
                ),
                _switchRow(
                  icon: Icons.pause_circle_outline_rounded,
                  title: context.l10n.presenceShowWhenPaused,
                  value: _rpc.showWhenPaused,
                  save: (v) => _rpc.setPresencePref('showPaused', v),
                ),
                _switchRow(
                  icon: Icons.explore_outlined,
                  title: context.l10n.presenceBrowsingTitle,
                  value: _rpc.browsingShowsTitle,
                  save: (v) => _rpc.setPresencePref('browsingTitle', v),
                ),
              ],
            ),
            SettingsCard(children: [_previewRow()]),
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

  // ── Customization (ArchiveTune-style) ───────────────────────────────────
  // Each line of the presence picks its source; defaults reproduce the
  // historical lines exactly, so updating changes nothing until touched.

  List<SettingsTile> _activityRows() {
    final l10n = context.l10n;
    String srcLabel(String v) => switch (v) {
      'title' => l10n.presenceSourceTitle,
      'episode' => l10n.presenceSourceEpisode,
      _ => l10n.presenceSourceApp,
    };
    final sources = [
      ('app', l10n.presenceSourceApp),
      ('title', l10n.presenceSourceTitle),
      ('episode', l10n.presenceSourceEpisode),
    ];
    return [
      _optRow(
        icon: Icons.circle_outlined,
        title: l10n.discordActivityStatus,
        value: _statusLabel(_rpc.presenceStatus),
        onTap: () => _pick(
          title: l10n.discordActivityStatus,
          options: [
            ('online', l10n.presenceOnline),
            ('idle', l10n.presenceIdle),
            ('dnd', l10n.presenceDnd),
          ],
          current: _rpc.presenceStatus,
          save: (v) => _rpc.setPresencePref('presenceStatus', v),
        ),
      ),
      _optRow(
        icon: Icons.title_rounded,
        title: l10n.presenceNameShows,
        value: srcLabel(_rpc.nameSrc),
        onTap: () => _pick(
          title: l10n.presenceNameShows,
          options: sources,
          current: _rpc.nameSrc,
          save: (v) => _rpc.setPresencePref('nameSrc', v),
        ),
      ),
      _optRow(
        icon: Icons.subject_rounded,
        title: l10n.presenceDetailsShows,
        value: srcLabel(_rpc.detailsSrc),
        onTap: () => _pick(
          title: l10n.presenceDetailsShows,
          options: sources,
          current: _rpc.detailsSrc,
          save: (v) => _rpc.setPresencePref('detailsSrc', v),
        ),
      ),
      _optRow(
        icon: Icons.info_outline_rounded,
        title: l10n.presenceStateShows,
        value: srcLabel(_rpc.stateSrc),
        onTap: () => _pick(
          title: l10n.presenceStateShows,
          options: sources,
          current: _rpc.stateSrc,
          save: (v) => _rpc.setPresencePref('stateSrc', v),
        ),
      ),
    ];
  }

  List<SettingsTile> _imageRows() {
    final l10n = context.l10n;
    String imgLabel(String v) => switch (v) {
      'poster' => l10n.presenceImagePoster,
      'logo' => l10n.presenceImageLogo,
      _ => l10n.presenceImageOff,
    };
    return [
      _optRow(
        icon: Icons.image_outlined,
        title: l10n.presenceLargeImage,
        value: imgLabel(_rpc.largeImageSrc),
        onTap: () => _pick(
          title: l10n.presenceLargeImage,
          options: [
            ('poster', l10n.presenceImagePoster),
            ('logo', l10n.presenceImageLogo),
            ('off', l10n.presenceImageOff),
          ],
          current: _rpc.largeImageSrc,
          save: (v) => _rpc.setPresencePref('largeImage', v),
        ),
      ),
      _optRow(
        icon: Icons.photo_size_select_small_outlined,
        title: l10n.presenceSmallImage,
        value: _rpc.smallImageSrc == 'logo'
            ? l10n.presenceImageLogo
            : l10n.presenceImageOff,
        onTap: () => _pick(
          title: l10n.presenceSmallImage,
          options: [
            ('logo', l10n.presenceImageLogo),
            ('off', l10n.presenceImageOff),
          ],
          current: _rpc.smallImageSrc,
          save: (v) => _rpc.setPresencePref('smallImage', v),
        ),
      ),
    ];
  }

  String _statusLabel(String v) => switch (v) {
    'idle' => context.l10n.presenceIdle,
    'dnd' => context.l10n.presenceDnd,
    _ => context.l10n.presenceOnline,
  };

  SettingsTile _optRow({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: value,
      onTap: onTap,
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }

  SettingsTile _switchRow({
    required IconData icon,
    required String title,
    required bool value,
    required Future<void> Function(bool) save,
  }) {
    return SettingsTile(
      icon: icon,
      title: title,
      onTap: () async {
        await save(!value);
        if (mounted) setState(() {});
      },
      trailing: Switch.adaptive(
        value: value,
        activeThumbColor: AppColors.accent,
        onChanged: (v) async {
          await save(v);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _pick({
    required String title,
    required List<(String, String)> options,
    required String current,
    required Future<void> Function(String) save,
  }) async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o.$1),
              child: Row(
                children: [
                  Expanded(child: Text(o.$2)),
                  if (o.$1 == current)
                    const Icon(Icons.check_rounded, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null && v != current && mounted) {
      await save(v);
      setState(() {});
    }
  }

  Future<void> _editButtonLabel() async {
    final ctrl = TextEditingController(text: _rpc.presenceButtonLabel);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.presenceButtonLabel),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.l10n.presenceButtonLabelHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (v != null && mounted) {
      await _rpc.setPresencePref('buttonLabel', v);
      setState(() {});
    }
  }

  /// WYSIWYG line preview with a sample title, like ArchiveTune's card.
  SettingsTile _previewRow() {
    const title = 'Frieren';
    const episode = 'Episode 4';
    final name = discordSourceLine(
      _rpc.nameSrc,
      title: title,
      episode: episode,
      appText: DiscordConfig.appName,
    );
    final details = discordSourceLine(
      _rpc.detailsSrc,
      title: title,
      episode: episode,
      appText: DiscordConfig.appName,
    );
    final state = discordSourceLine(
      _rpc.stateSrc,
      title: title,
      episode: episode,
      appText: 'on ${DiscordConfig.appName}',
    );
    return SettingsTile(
      icon: Icons.visibility_outlined,
      title: context.l10n.presencePreview,
      subtitle: 'Watching $name\n$details\n$state',
      subtitleMaxLines: null,
    );
  }
}
