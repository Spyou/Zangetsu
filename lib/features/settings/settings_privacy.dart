// Privacy and advanced: DNS, incognito, logs, API keys.
part of 'settings_screen.dart';


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
                autofocus: true,
                icon: Icons.visibility_off_outlined,
                title: 'Incognito mode',
                subtitle: 'Pause history, tracking & Discord presence',
                onTap: () => IncognitoMode.set(!IncognitoMode.on),
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
                onTap: () => _onNsfwChanged(!_nsfw),
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
                onTap: () => _onNsfwAniChanged(!_nsfwAni),
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

