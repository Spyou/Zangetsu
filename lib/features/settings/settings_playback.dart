// Playback settings: quality, autoplay, speed, subtitles.
part of 'settings_screen.dart';



// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

/// App-wide playback defaults — default quality / audio, autoplay, speed,
/// skip interval, keep-screen-on and resume. Reads and writes the shared
/// [PlaybackPrefs] singleton; rebuilds after each change so the value
/// subtitles stay current.
class PlaybackSettingsScreen extends StatefulWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  State<PlaybackSettingsScreen> createState() => _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState extends State<PlaybackSettingsScreen> {
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  int _cacheBytes = 0;
  bool _shadersReady = ShaderPresets.downloaded;
  bool _shaderDownloading = false;
  double _shaderProgress = 0;

  // The main picker: Off + the three filters. The GPU tier (Mid/High) is a
  // separate row below.
  static const List<(String, String)> _shaderStyleOptions = [
    ('off', 'Off'),
    ('a', 'Sharpen — clean 1080p sources'),
    ('b', 'De-blur — blurry / soft sources'),
    ('c', 'Denoise — grainy / compressed'),
  ];
  static const List<(String, String)> _shaderTierOptions = [
    ('mid', 'Mid-range GPU — light, smooth'),
    ('high', 'High-end GPU — heavier, sharpest'),
  ];

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
    ShaderPresets.refreshDownloaded().then((v) {
      if (mounted) setState(() => _shadersReady = v);
    });
  }

  // ── Video enhancement (GLSL upscaling shaders, downloaded on demand) ────────
  Future<void> _downloadShaders() async {
    if (_shaderDownloading) return;
    setState(() {
      _shaderDownloading = true;
      _shaderProgress = 0;
    });
    final ok = await ShaderPresets.download(
      onProgress: (p) {
        if (mounted) setState(() => _shaderProgress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _shaderDownloading = false;
      _shadersReady = ok;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shader download failed — check network')),
      );
    } else {
      // Default to Sharpen so the download has an immediate, visible effect.
      if (_prefs.videoShaderStyle == 'off') {
        await _prefs.setVideoShaderStyle('a');
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickShaderStyle() async {
    final picked = await _pick<String>(
      title: 'Anime4K Enhancement',
      options: _shaderStyleOptions,
      current: _prefs.videoShaderStyle,
    );
    if (picked == null) return;
    await _prefs.setVideoShaderStyle(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickShaderTier() async {
    final picked = await _pick<String>(
      title: 'Anime4K GPU tier',
      options: _shaderTierOptions,
      current: _prefs.videoShaderTier,
    );
    if (picked == null) return;
    await _prefs.setVideoShaderTier(picked);
    if (mounted) setState(() {});
  }


  Future<void> _loadCacheSize() async {
    final n = await MediaCache.sizeBytes();
    if (mounted) setState(() => _cacheBytes = n);
  }

  Future<void> _clearCache() async {
    await MediaCache.clear();
    await _loadCacheSize();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Cache cleared')));
  }

  static const List<(String, String)> _bufferSizeOptions = [
    ('low', 'Low (32 MB) — low-RAM / TV'),
    ('default', 'Default (128 MB)'),
    ('high', 'High (512 MB) — smoother'),
  ];
  static const List<(String, String)> _bufferLengthOptions = [
    ('low', 'Low (15s) — low-RAM / TV'),
    ('default', 'Default (60s)'),
    ('high', 'High (120s) — smoother'),
  ];

  Future<void> _pickBufferSize() async {
    final picked = await _pick<String>(
      title: 'Video buffer size',
      options: _bufferSizeOptions,
      current: _prefs.videoBufferSize,
    );
    if (picked == null) return;
    await _prefs.setVideoBufferSize(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickBufferLength() async {
    final picked = await _pick<String>(
      title: 'Video buffer length',
      options: _bufferLengthOptions,
      current: _prefs.videoBufferLength,
    );
    if (picked == null) return;
    await _prefs.setVideoBufferLength(picked);
    if (mounted) setState(() {});
  }

  /// Multi-select of which fields the in-player info overlay shows.
  Future<void> _pickPlayerInfo() async {
    final selected = _prefs.playerInfoFields.toSet();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Player info overlay', style: AppText.headline),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Pick what shows over the video (appears with the '
                    'controls). Like YouTube\'s "Stats for nerds".',
                    style: AppText.caption,
                  ),
                ),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final f in kPlayerInfoFields)
                        CheckboxListTile(
                          value: selected.contains(f.$1),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(f.$1);
                            } else {
                              selected.remove(f.$1);
                            }
                          }),
                          title: Text(f.$2, style: AppText.body),
                          activeColor: AppColors.accent,
                          controlAffinity: ListTileControlAffinity.trailing,
                          dense: true,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    // Persist the ticked fields in canonical (display) order.
    final ordered = [
      for (final f in kPlayerInfoFields)
        if (selected.contains(f.$1)) f.$1,
    ];
    await _prefs.setPlayerInfoFields(ordered);
    if (mounted) setState(() {});
  }

  // Ordered (value, label) options for each picker.
  static const List<(String, String)> _qualityOptions = [
    ('auto', 'Auto'),
    ('highest', 'Highest'),
    ('1080p', '1080p'),
    ('720p', '720p'),
    ('480p', '480p'),
  ];

  static const List<(String, String)> _audioOptions = [
    ('sub', 'Sub'),
    ('dub', 'Dub'),
  ];

  static const List<(double, String)> _speedOptions = [
    (0.5, '0.5x'),
    (0.75, '0.75x'),
    (1.0, '1x'),
    (1.25, '1.25x'),
    (1.5, '1.5x'),
    (2.0, '2x'),
  ];

  static const List<(int, String)> _skipOptions = [
    (5, '5s'),
    (10, '10s'),
    (15, '15s'),
    (30, '30s'),
  ];

  static const List<(String, String)> _decoderOptions = [
    ('copy', 'Hardware+ (recommended)'),
    ('direct', 'Hardware (faster)'),
    ('sw', 'Software (most compatible)'),
    ('auto', 'Auto'),
  ];

  // How mpv paints the video. Only worth changing when the video is black but
  // the audio and controls work — that's the GPU renderer failing on a device
  // whose driver can't run it, and no source or decoder change will help.
  // MediaCodec Embed skips that renderer entirely (the decoder draws straight
  // to the surface), at the cost of Anime4K and burned-in subtitle styling.
  static const List<(String, String)> _rendererOptions = [
    ('auto', 'Auto (recommended)'),
    ('gpu', 'GPU — standard renderer'),
    ('gpu-next', 'GPU Next — Vulkan, experimental'),
    ('mediacodec_embed', 'MediaCodec Embed — fixes black video'),
  ];

  static const List<(String, String)> _closeConfirmOptions = [
    ('double_back', 'Double back — press back twice to exit'),
    ('confirm', 'Close confirmation — ask before leaving'),
    ('direct', 'Close directly — exit immediately'),
  ];

  String _labelFor<T>(List<(T, String)> options, T value, String fallback) {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return fallback;
  }

  /// Bottom sheet listing [options]; returns the value the user tapped, or
  /// null if dismissed. Mirrors the active-source picker on the Settings list.
  Future<T?> _pick<T>({
    required String title,
    required List<(T, String)> options,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
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
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title, style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            // Scroll a long option list (e.g. the ~25-language "Translate to"
            // picker) instead of overflowing the sheet. Short lists
            // (quality/decoder) stay shorter than the cap, so shrinkWrap sizes
            // them to their content and they look unchanged.
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final (value, label) in options)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, value),
                        title: Text(
                          label,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: value == current
                            ? Icon(Icons.check, color: AppColors.accent)
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickQuality() async {
    final picked = await _pick<String>(
      title: 'Default quality',
      options: _qualityOptions,
      current: _prefs.defaultQuality,
    );
    if (picked == null) return;
    await _prefs.setDefaultQuality(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickDecoder() async {
    final picked = await _pick<String>(
      title: 'Video decoder',
      options: _decoderOptions,
      current: _prefs.videoDecoder,
    );
    if (picked == null) return;
    await _prefs.setVideoDecoder(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickRenderer() async {
    final picked = await _pick<String>(
      title: 'Video renderer',
      options: _rendererOptions,
      current: _prefs.videoOutput,
    );
    if (picked == null) return;
    await _prefs.setVideoOutput(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickAudio() async {
    final picked = await _pick<String>(
      title: 'Default audio',
      options: _audioOptions,
      current: _prefs.defaultCategory,
    );
    if (picked == null) return;
    await _prefs.setDefaultCategory(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSpeed() async {
    final picked = await _pick<double>(
      title: 'Default speed',
      options: _speedOptions,
      current: _prefs.defaultSpeed,
    );
    if (picked == null) return;
    await _prefs.setDefaultSpeed(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSkip() async {
    final picked = await _pick<int>(
      title: 'Double-tap skip',
      options: _skipOptions,
      current: _prefs.doubleTapSeconds,
    );
    if (picked == null) return;
    await _prefs.setDoubleTapSeconds(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickCloseConfirmation() async {
    final picked = await _pick<String>(
      title: 'Close confirmation',
      options: _closeConfirmOptions,
      current: _prefs.closeConfirmation,
    );
    if (picked == null) return;
    await _prefs.setCloseConfirmation(picked);
    if (mounted) setState(() {});
  }

  // TV picker options for MegaSkip duration (the phone uses the inline slider).
  static const List<(int, String)> _megaSkipDurationOptions = [
    (10, '10s'),
    (15, '15s'),
    (30, '30s'),
    (60, '60s'),
    (85, '85s'),
    (90, '90s'),
    (120, '120s'),
    (180, '180s'),
  ];

  Future<void> _pickMegaSkipDuration() async {
    final picked = await _pick<int>(
      title: 'MegaSkip duration',
      options: _megaSkipDurationOptions,
      current: _prefs.megaSkipSeconds,
    );
    if (picked == null) return;
    await _prefs.setMegaSkipSeconds(picked);
    if (mounted) setState(() {});
  }

  /// Default player picker: Built-in + any installed external players. Streams
  /// then open in the chosen app instead of the in-app player.
  Future<void> _pickPlayer() async {
    final players = await ExternalPlayer().installed();
    if (!mounted) return;
    final options = <(String, String)>[
      ('', 'Built-in player'),
      for (final p in players) (p.package, p.label),
    ];
    if (players.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No external players found. Install MX Player, VLC, mpv, '
            'Just Player or Next Player.',
          ),
        ),
      );
    }
    final picked = await _pick<String>(
      title: 'Default player',
      options: options,
      current: _prefs.externalPlayerPackage,
    );
    if (picked == null) return;
    final label = options
        .firstWhere((o) => o.$1 == picked, orElse: () => ('', ''))
        .$2;
    await _prefs.setExternalPlayer(picked, picked.isEmpty ? '' : label);
    if (mounted) setState(() {});
  }

  /// A boolean row rendered as a [SwitchListTile.adaptive] styled to sit
  /// inside a [SettingsCard] alongside the [SettingsTile] picker rows.
  Widget _toggleRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    // A SettingsTile with a trailing Switch — identical geometry (icon inset,
    // size, gap, right padding) to every other row, so icons and labels line up
    // in one clean column. subtitleMaxLines:null lets long descriptions wrap.
    return SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: null,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.accent,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// MegaSkip jump-size slider (5–180s), shown under the MegaSkip toggle. Holds
  /// the value locally while dragging (smooth, no per-tick Hive writes) and
  /// persists on release.
  Widget _megaSkipDurationRow() {
    double val = _prefs.megaSkipSeconds.toDouble();
    return StatefulBuilder(
      builder: (context, setLocal) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.timer_outlined,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'MegaSkip duration',
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  '${val.round()}s',
                  style: AppText.headline.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text('${PlaybackPrefs.megaSkipMin}', style: AppText.caption),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppColors.accent,
                      thumbColor: AppColors.accent,
                      inactiveTrackColor: AppColors.textSecondary.withValues(
                        alpha: 0.3,
                      ),
                      overlayColor: AppColors.accent.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      min: PlaybackPrefs.megaSkipMin.toDouble(),
                      max: PlaybackPrefs.megaSkipMax.toDouble(),
                      divisions:
                          PlaybackPrefs.megaSkipMax - PlaybackPrefs.megaSkipMin,
                      value: val,
                      label: '${val.round()}s',
                      onChanged: (v) => setLocal(() => val = v),
                      onChangeEnd: (v) async {
                        await _prefs.setMegaSkipSeconds(v.round());
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                Text('${PlaybackPrefs.megaSkipMax}', style: AppText.caption),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Playback'),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          // ── Quality & audio ─────────────────────────────────────────────
          const SettingsSectionLabel('Quality & audio'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.high_quality_outlined,
                title: 'Default quality',
                subtitle: _labelFor(
                  _qualityOptions,
                  _prefs.defaultQuality,
                  _prefs.defaultQuality,
                ),
                onTap: _pickQuality,
              ),
              SettingsTile(
                icon: Icons.translate_rounded,
                title: 'Default audio (anime sub/dub)',
                subtitle: _labelFor(
                  _audioOptions,
                  _prefs.defaultCategory,
                  _prefs.defaultCategory,
                ),
                onTap: _pickAudio,
              ),
              SettingsTile(
                icon: Icons.speed_outlined,
                title: 'Default speed',
                subtitle: _labelFor(
                  _speedOptions,
                  _prefs.defaultSpeed,
                  '${_prefs.defaultSpeed}x',
                ),
                onTap: _pickSpeed,
              ),
              // Video decoder + Anime4K are mpv-renderer-only — the native TV
              // player (ExoPlayer) ignores them, so hide them on TV.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.memory_outlined,
                  title: 'Video decoder',
                  subtitle: _labelFor(
                    _decoderOptions,
                    _prefs.videoDecoder,
                    'Hardware+ (recommended)',
                  ),
                  onTap: _pickDecoder,
                ),
              // Escape hatch for black video with working audio — see
              // _rendererOptions. Takes effect on the next player open (mpv
              // can't swap its video output on a live player).
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.display_settings_outlined,
                  title: 'Video renderer',
                  subtitle: _labelFor(
                    _rendererOptions,
                    _prefs.videoOutput,
                    'Auto (recommended)',
                  ),
                  onTap: _pickRenderer,
                ),
              // Anime4K GLSL upscaling — downloaded on demand. One row = Off /
              // Mid / High (GPU tier). Anime-tuned; may over-sharpen live action.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Anime4K Enhancement',
                  subtitle: _shaderDownloading
                      ? 'Downloading… ${(_shaderProgress * 100).round()}%'
                      : (!_shadersReady
                            ? 'Tap to download shaders (~0.8 MB)'
                            : ShaderPresets.styleById(
                                _prefs.videoShaderStyle,
                              ).label),
                  trailing: _shaderDownloading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _shaderDownloading
                      ? null
                      : (!_shadersReady ? _downloadShaders : _pickShaderStyle),
                ),
              if (!sl<AppMode>().isTv &&
                  _shadersReady &&
                  _prefs.videoShaderStyle != 'off')
                SettingsTile(
                  icon: Icons.speed_outlined,
                  title: 'Anime4K GPU tier',
                  subtitle: ShaderPresets.tierLabel(_prefs.videoShaderTier),
                  onTap: _pickShaderTier,
                ),
            ],
          ),

          // ── Player (external app handoff — Android) ─────────────────────
          // External-player handoff is phone-only; the TV plays in its own
          // native player, so hide this whole section on TV.
          if (Platform.isAndroid && !sl<AppMode>().isTv) ...[
            const SettingsSectionLabel('Player'),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.smart_display_outlined,
                  title: 'Default player',
                  subtitle: _prefs.externalPlayerPackage.isEmpty
                      ? 'Built-in'
                      : (_prefs.externalPlayerLabel.isNotEmpty
                            ? _prefs.externalPlayerLabel
                            : 'External app'),
                  onTap: _pickPlayer,
                ),
                SettingsTile(
                  icon: Icons.tune_rounded,
                  title: 'Player controls',
                  subtitle: 'Reorder or hide the buttons on the player bar',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PlayerControlsScreen(),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ],

          // ── Playback behaviour ──────────────────────────────────────────
          const SettingsSectionLabel('Playback'),
          SettingsCard(
            children: [
              _toggleRow(
                icon: Icons.history_outlined,
                title: 'Resume playback',
                subtitle: 'Continue from where you left off',
                value: _prefs.autoResume,
                onChanged: (v) async {
                  await _prefs.setAutoResume(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.playlist_add_check_rounded,
                title: 'Auto-add to My List',
                subtitle: 'Add a title to My List when you start watching it',
                value: _prefs.autoAddToMyList,
                onChanged: (v) async {
                  await _prefs.setAutoAddToMyList(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.sync_rounded,
                title: 'Auto-track',
                subtitle:
                    'Update AniList, MyAnimeList and Simkl as you watch. '
                    'Off still lets you track a title by hand',
                value: _prefs.autoTrack,
                onChanged: (v) async {
                  await _prefs.setAutoTrack(v);
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile(
                icon: Icons.exit_to_app_outlined,
                title: 'Close confirmation',
                subtitle: switch (_prefs.closeConfirmation) {
                  'confirm' => 'Ask before leaving the player',
                  'direct' => 'Exit immediately',
                  _ => 'Press back twice to exit',
                },
                onTap: _pickCloseConfirmation,
              ),
              _toggleRow(
                icon: Icons.skip_next_outlined,
                title: 'Autoplay next episode',
                value: _prefs.autoplayNext,
                onChanged: (v) async {
                  await _prefs.setAutoplayNext(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_outlined,
                title: 'Auto-skip filler episodes',
                subtitle: 'On autoplay, jump past filler (anime only)',
                value: _prefs.autoSkipFiller,
                onChanged: (v) async {
                  await _prefs.setAutoSkipFiller(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.movie_outlined,
                title: 'Autoplay trailer',
                subtitle: 'Play a title\'s trailer on its detail page',
                value: _prefs.autoplayTrailer,
                onChanged: (v) async {
                  await _prefs.setAutoplayTrailer(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: 'Play trailers in HD',
                subtitle: 'Up to 1080p when available — falls back to standard '
                    'if not. Uses more data',
                value: _prefs.trailerHd,
                onChanged: (v) async {
                  await _prefs.setTrailerHd(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_outlined,
                title: 'Skip intro button',
                subtitle: 'Show Skip opening/ending on anime (when detected)',
                value: _prefs.skipIntro,
                onChanged: (v) async {
                  await _prefs.setSkipIntro(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: 'Auto-skip opening',
                subtitle: 'Jump past the OP on its own, no tap',
                value: _prefs.autoSkipOp,
                onChanged: (v) async {
                  await _prefs.setAutoSkipOp(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: 'Auto-skip ending',
                subtitle: 'Jump past the ED on its own, no tap',
                value: _prefs.autoSkipEd,
                onChanged: (v) async {
                  await _prefs.setAutoSkipEd(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.keyboard_double_arrow_right_rounded,
                title: 'MegaSkip button',
                subtitle: 'A jump-forward button in the player (any video)',
                value: _prefs.megaSkip,
                onChanged: (v) async {
                  await _prefs.setMegaSkip(v);
                  if (mounted) setState(() {});
                },
              ),
              // On TV the inline slider traps D-pad focus (↑/↓ change the value
              // instead of moving on), so use a picker row there instead.
              if (_prefs.megaSkip)
                sl<AppMode>().isTv
                    ? SettingsTile(
                        icon: Icons.timer_outlined,
                        title: 'MegaSkip duration',
                        subtitle: '${_prefs.megaSkipSeconds}s',
                        onTap: _pickMegaSkipDuration,
                      )
                    : _megaSkipDurationRow(),
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen on',
                value: _prefs.keepScreenOn,
                onChanged: (v) async {
                  await _prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
              if (sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.tv_outlined,
                  title: 'Native TV player',
                  subtitle: 'Recommended. Turn off only if you prefer the old '
                      'player',
                  value: _prefs.nativeTvPlayer,
                  onChanged: (v) async {
                    await _prefs.setNativeTvPlayer(v);
                    if (mounted) setState(() {});
                  },
                ),
              if (sl<AppMode>().isTv && _prefs.nativeTvPlayer)
                _toggleRow(
                  icon: Icons.surround_sound_outlined,
                  title: 'Software audio (Dolby/DTS)',
                  subtitle: 'Turn on only if Dolby/DTS audio is silent — may be '
                      'unstable on some TVs',
                  value: _prefs.tvSoftwareDecoding,
                  onChanged: (v) async {
                    await _prefs.setTvSoftwareDecoding(v);
                    if (mounted) setState(() {});
                  },
                ),
              // Seek preview (online) removed — the streaming engine was flaky
              // and re-downloaded video just for thumbnails. Download-file
              // previews still work (instant + free), so no toggle is needed.
              /*
              _toggleRow(
                icon: Icons.image_outlined,
                title: 'Seek preview (online)',
                subtitle: 'Thumbnails while scrubbing streams — costs extra data',
                value: _prefs.seekPreviewOnline,
                onChanged: (v) async {
                  await _prefs.setSeekPreviewOnline(v);
                  if (mounted) setState(() {});
                },
              ),
              */
              if (Platform.isAndroid && !sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.picture_in_picture_alt_outlined,
                  title: 'Auto picture-in-picture',
                  subtitle: 'Shrink to a floating window when you leave the app',
                  value: _prefs.autoPip,
                  onChanged: (v) async {
                    await _prefs.setAutoPip(v);
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile(
                icon: Icons.info_outline_rounded,
                title: 'Player info overlay',
                subtitle: _prefs.playerInfoFields.isEmpty
                    ? 'Off'
                    : '${_prefs.playerInfoFields.length} fields (ⓘ button)',
                onTap: _pickPlayerInfo,
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: 'Show quality label',
                subtitle: 'Plain quality text (e.g. 1080p) on the top-bar right',
                value: _prefs.alwaysShowQuality,
                onChanged: (v) async {
                  await _prefs.setAlwaysShowQuality(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),

          // ── Gestures (touch-only — hidden on TV) ────────────────────────
          if (!sl<AppMode>().isTv) ...[
          const SettingsSectionLabel('Gestures'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.touch_app_outlined,
                title: 'Double-tap skip',
                subtitle: _labelFor(
                  _skipOptions,
                  _prefs.doubleTapSeconds,
                  '${_prefs.doubleTapSeconds}s',
                ),
                onTap: _pickSkip,
              ),
              _toggleRow(
                icon: Icons.swipe_outlined,
                title: 'Gesture controls',
                subtitle: 'Swipe left for brightness, right for volume',
                value: _prefs.gestureControls,
                onChanged: (v) async {
                  await _prefs.setGestureControls(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.swap_horiz_rounded,
                title: 'Swipe to seek',
                subtitle: 'Drag left or right across the video to scrub',
                value: _prefs.swipeSeek,
                onChanged: (v) async {
                  await _prefs.setSwipeSeek(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: 'Hold for 2× speed',
                subtitle: 'Long-press the video to play at 2× while held',
                value: _prefs.holdSpeed,
                onChanged: (v) async {
                  await _prefs.setHoldSpeed(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          ],

          // ── Cache (buffering + clear) ───────────────────────────────────
          const SettingsSectionLabel('Cache'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.memory_rounded,
                title: 'Video buffer size',
                subtitle: _labelFor(
                  _bufferSizeOptions,
                  _prefs.videoBufferSize,
                  'Default (128 MB)',
                ),
                onTap: _pickBufferSize,
              ),
              SettingsTile(
                icon: Icons.timelapse_rounded,
                title: 'Video buffer length',
                subtitle: _labelFor(
                  _bufferLengthOptions,
                  _prefs.videoBufferLength,
                  'Default (60s)',
                ),
                onTap: _pickBufferLength,
              ),
              SettingsTile(
                icon: Icons.delete_outline_rounded,
                title: 'Clear image & video cache',
                subtitle: MediaCache.formatBytes(_cacheBytes),
                onTap: _clearCache,
              ),
            ],
          ),

          // ── Subtitles ───────────────────────────────────────────────────
          const SettingsSectionLabel('Subtitles'),
          SettingsCard(
            children: [
              // libass is the mpv renderer's .ass styling — the native TV
              // player styles subtitles via ExoPlayer instead, so hide on TV.
              if (!sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.subtitles_outlined,
                  title: 'Styled subtitles (libass)',
                  subtitle: 'Real .ass styling — fonts, positions, karaoke, '
                      'signs. Best for anime. Applies from the next episode.',
                  value: _prefs.styledSubtitles,
                  onChanged: (v) async {
                    await _prefs.setStyledSubtitles(v);
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile(
                icon: Icons.text_fields_rounded,
                title: 'Subtitle style',
                subtitle: 'Font, colour, outline, opacity, size, position — '
                    'with live preview',
                onTap: () => openSubtitleStyleSheet(
                  context,
                  null,
                  () {
                    if (mounted) setState(() {});
                  },
                ),
              ),
              SettingsTile(
                icon: Icons.vpn_key_outlined,
                title: 'OpenSubtitles API key',
                subtitle: _prefs.subtitleApiKey.trim().isEmpty
                    ? 'Required for online subtitle search'
                    : 'Key saved — online search enabled',
                onTap: _editSubtitleApiKey,
              ),
              SettingsTile(
                icon: Icons.language_outlined,
                title: 'Subtitle language',
                subtitle: () {
                  final p = _prefs.subtitlePreference;
                  if (p.isEmpty) return 'Auto';
                  if (p == 'off') return 'Off';
                  return languageByPref(p)?.name ?? p.toUpperCase();
                }(),
                onTap: _pickSubtitleLanguage,
              ),
              _toggleRow(
                icon: Icons.download_outlined,
                title: 'Auto-download subtitles',
                subtitle:
                    'When the source has no subtitle in your language',
                value: _prefs.autoDownloadSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoDownloadSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.translate_outlined,
                title: 'Auto-translate subtitles',
                subtitle:
                    'Translate to your language on play (when the source has none)',
                value: _prefs.autoTranslateSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoTranslateSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              if (_prefs.autoTranslateSubtitles)
                SettingsTile(
                  icon: Icons.g_translate_outlined,
                  title: 'Translate subtitles to',
                  subtitle: _prefs.translateSubtitleTo.isEmpty
                      ? 'Pick a language'
                      : (languageByPref(_prefs.translateSubtitleTo)?.name ??
                            _prefs.translateSubtitleTo.toUpperCase()),
                  onTap: _pickTranslateLanguage,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickTranslateLanguage() async {
    final picked = await _pick<String>(
      title: 'Translate subtitles to',
      options: [for (final l in kSubtitleLanguages) (l.iso1, l.name)],
      current: _prefs.translateSubtitleTo,
    );
    if (picked == null) return;
    await _prefs.setTranslateSubtitleTo(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSubtitleLanguage() async {
    final picked = await showSubtitleLanguagePicker(
      context,
      _prefs.subtitlePreference,
    );
    if (picked == null) return; // dismissed
    await _prefs.setSubtitlePreference(picked);
    if (mounted) setState(() {});
  }

  /// Prompts for the OpenSubtitles API key and saves it to [PlaybackPrefs].
  /// A free key is created at opensubtitles.com → Consumers.
  Future<void> _editSubtitleApiKey() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => _ApiKeyDialog(initial: _prefs.subtitleApiKey),
    );
    if (key == null) return; // dismissed
    await _prefs.setSubtitleApiKey(key.trim());
    if (mounted) setState(() {});
  }

}
