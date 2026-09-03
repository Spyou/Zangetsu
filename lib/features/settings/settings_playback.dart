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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.shaderDownloadFailedCheckNetwork)));
    } else {
      // Default to Sharpen so the download has an immediate, visible effect.
      if (_prefs.videoShaderStyle == 'off') {
        await _prefs.setVideoShaderStyle('a');
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickShaderStyle() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(
      title: l10n.anime4kEnhancement,
      options: shaderStylePickerOptions(l10n),
      current: _prefs.videoShaderStyle,
    );
    if (picked == null) return;
    await _prefs.setVideoShaderStyle(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickShaderTier() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(
      title: l10n.anime4kGPUTier,
      options: shaderTierPickerOptions(l10n),
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
      ..showSnackBar(SnackBar(content: Text(context.l10n.cacheCleared)));
  }

  static List<(String, String)> _bufferSizeOptions(AppLocalizations l10n) => [
    ('low', l10n.bufferSizeLow),
    ('default', l10n.bufferSizeDefault),
    ('high', l10n.bufferSizeHigh),
  ];
  static List<(String, String)> _bufferLengthOptions(AppLocalizations l10n) => [
    ('low', l10n.bufferLengthLow),
    ('default', l10n.bufferLengthDefault),
    ('high', l10n.bufferLengthHigh),
    ('max', l10n.bufferLengthMax),
  ];

  Future<void> _pickBufferSize() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(
      title: l10n.videoBufferSize,
      options: _bufferSizeOptions(l10n),
      current: _prefs.videoBufferSize,
    );
    if (picked == null) return;
    await _prefs.setVideoBufferSize(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickBufferLength() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(
      title: l10n.videoBufferLength,
      options: _bufferLengthOptions(l10n),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(context.l10n.playerInfoOverlay, style: AppText.headline),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.pickWhatShowsOverVideo,
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

  static const List<(String, String)> _audioOptions = [('sub', 'Sub'), ('dub', 'Dub')];

  static const List<(double, String)> _speedOptions = [
    (0.5, '0.5x'),
    (0.75, '0.75x'),
    (1.0, '1x'),
    (1.25, '1.25x'),
    (1.5, '1.5x'),
    (2.0, '2x'),
  ];

  static const List<(int, String)> _skipOptions = [(5, '5s'), (10, '10s'), (15, '15s'), (30, '30s')];

  String _labelFor<T>(List<(T, String)> options, T value, String fallback) {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return fallback;
  }

  /// Option picker: bottom sheet on phone, D-pad dialog on TV (Material sheet
  /// focus paints behind opaque rows and is invisible at 10 feet).
  Future<T?> _pick<T>({required String title, required List<(T, String)> options, required T current}) {
    if (sl<AppMode>().isTv) {
      return showDialog<T>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => Dialog(
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
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
                    child: ListView(
                      shrinkWrap: true,
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        for (final (value, label) in options)
                          TvListFocusable(
                            autofocus: value == current,
                            semanticLabel: label,
                            onTap: () => Navigator.pop(ctx, value),
                            child: ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                child: Row(
                                  children: [
                                    Expanded(child: Text(label, style: AppText.headline)),
                                    if (value == current) Icon(Icons.check, color: AppColors.accent, size: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final (value, label) in options)
                      ListTile(
                        onTap: () => Navigator.pop(ctx, value),
                        title: Text(label, style: AppText.body.copyWith(color: AppColors.textPrimary)),
                        trailing: value == current ? Icon(Icons.check, color: AppColors.accent) : null,
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
      title: context.l10n.defaultQuality,
      options: _qualityOptions,
      current: _prefs.defaultQuality,
    );
    if (picked == null) return;
    await _prefs.setDefaultQuality(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickDecoder() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(title: l10n.videoDecoder, options: videoDecoderOptions(l10n), current: _prefs.videoDecoder);
    if (picked == null) return;
    await _prefs.setVideoDecoder(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickRenderer() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(title: l10n.videoRenderer, options: videoRendererOptions(l10n), current: _prefs.videoOutput);
    if (picked == null) return;
    await _prefs.setVideoOutput(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickAudio() async {
    final picked = await _pick<String>(title: context.l10n.defaultAudio, options: _audioOptions, current: _prefs.defaultCategory);
    if (picked == null) return;
    await _prefs.setDefaultCategory(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSpeed() async {
    final picked = await _pick<double>(title: context.l10n.defaultSpeed, options: _speedOptions, current: _prefs.defaultSpeed);
    if (picked == null) return;
    await _prefs.setDefaultSpeed(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSkip() async {
    final picked = await _pick<int>(title: context.l10n.doubleTapSkip, options: _skipOptions, current: _prefs.doubleTapSeconds);
    if (picked == null) return;
    await _prefs.setDoubleTapSeconds(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickCloseConfirmation() async {
    final l10n = context.l10n;
    final picked = await _pick<String>(
      title: l10n.closeConfirmation,
      options: closeConfirmPickerOptions(l10n),
      current: _prefs.closeConfirmation,
    );
    if (picked == null) return;
    await _prefs.setCloseConfirmation(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSeekSecondsForTV() async {
    final picked = await _pick<int>(
      title: context.l10n.seekButtonDuration,
      options: _skipOptions,
      current: _prefs.tvSeekSeconds,
    );
    if (picked == null) return;
    await _prefs.setTvSeekSeconds(picked);
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
      title: context.l10n.megaSkipDuration,
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
    // Already known-first from the native side. The ones past the known block
    // still play — header-gated streams included, since those route through the
    // local proxy for any player that isn't MX/Just — but we don't know which
    // extras they read, so external subtitles and the resume position may be
    // dropped. Flagged rather than hidden: it's a real caveat, not a blocker.
    final options = <(String, String)>[
      ('', context.l10n.builtInPlayer),
      for (final p in players) (p.package, p.known ? p.label : '${p.label}${context.l10n.noSubsResumeSuffix}'),
    ];
    if (players.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noOtherVideoAppsFound)),
      );
    }
    final picked = await _pick<String>(
      title: context.l10n.defaultPlayer,
      options: options,
      current: _prefs.externalPlayerPackage,
    );
    if (picked == null) return;
    // From `players`, not `options` — the option label carries the "no headers"
    // hint, which belongs in the picker but not in the saved name shown on the
    // settings row afterwards.
    final match = players.where((p) => p.package == picked);
    final label = match.isEmpty ? '' : match.first.label;
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
                Icon(Icons.timer_outlined, color: AppColors.textSecondary, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    context.l10n.megaSkipDuration,
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  context.l10n.secondsShort(val.round()),
                  style: AppText.headline.copyWith(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 15),
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
                      inactiveTrackColor: AppColors.textSecondary.withValues(alpha: 0.3),
                      overlayColor: AppColors.accent.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      min: PlaybackPrefs.megaSkipMin.toDouble(),
                      max: PlaybackPrefs.megaSkipMax.toDouble(),
                      divisions: PlaybackPrefs.megaSkipMax - PlaybackPrefs.megaSkipMin,
                      value: val,
                      label: context.l10n.secondsShort(val.round()),
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
      appBar: settingsAppBar(context.l10n.playback),
      body: ListView(
        // TV focus chrome paints outside the row, so it must not be clipped.
        // Phone has no focus ring — keep the normal clip so rows don't bleed
        // past the list edge while scrolling.
        clipBehavior: sl<AppMode>().isTv ? Clip.none : Clip.hardEdge,
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          // ── Quality & audio ─────────────────────────────────────────────
          SettingsSectionLabel(context.l10n.qualityAndAudio),
          SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.high_quality_outlined,
                title: context.l10n.defaultQuality,
                subtitle: _labelFor(_qualityOptions, _prefs.defaultQuality, _prefs.defaultQuality),
                onTap: _pickQuality,
              ),
              SettingsTile(
                icon: Icons.translate_rounded,
                title: context.l10n.defaultAudioAnimeSubDub,
                subtitle: _labelFor(_audioOptions, _prefs.defaultCategory, _prefs.defaultCategory),
                onTap: _pickAudio,
              ),
              SettingsTile(
                icon: Icons.speed_outlined,
                title: context.l10n.defaultSpeed,
                subtitle: _labelFor(_speedOptions, _prefs.defaultSpeed, '${_prefs.defaultSpeed}x'),
                onTap: _pickSpeed,
              ),
              // Video decoder + Anime4K are mpv-renderer-only — the native TV
              // player (ExoPlayer) ignores them, so hide them on TV.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.memory_outlined,
                  title: context.l10n.videoDecoder,
                  subtitle: _labelFor(videoDecoderOptions(context.l10n), _prefs.videoDecoder, context.l10n.decoderHardwareRecommended),
                  onTap: _pickDecoder,
                ),
              // Escape hatch for black video with working audio — see
              // _rendererOptions. Takes effect on the next player open (mpv
              // can't swap its video output on a live player).
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.display_settings_outlined,
                  title: context.l10n.videoRenderer,
                  subtitle: _labelFor(videoRendererOptions(context.l10n), _prefs.videoOutput, context.l10n.rendererAutoRecommended),
                  onTap: _pickRenderer,
                ),
              // Anime4K GLSL upscaling — downloaded on demand. One row = Off /
              // Mid / High (GPU tier). Anime-tuned; may over-sharpen live action.
              if (!sl<AppMode>().isTv)
                SettingsTile(
                  icon: Icons.auto_awesome_outlined,
                  title: context.l10n.anime4kEnhancement,
                  subtitle: _shaderDownloading
                      ? context.l10n.downloadingPercent((_shaderProgress * 100).round())
                      : (!_shadersReady
                            ? context.l10n.tapToDownloadShaders
                            : shaderStylePickerLabel(context.l10n, _prefs.videoShaderStyle)),
                  trailing: _shaderDownloading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: _shaderDownloading ? null : (!_shadersReady ? _downloadShaders : _pickShaderStyle),
                ),
              if (!sl<AppMode>().isTv && _shadersReady && _prefs.videoShaderStyle != 'off')
                SettingsTile(
                  icon: Icons.speed_outlined,
                  title: context.l10n.anime4kGPUTier,
                  subtitle: shaderTierPickerLabel(context.l10n, _prefs.videoShaderTier),
                  onTap: _pickShaderTier,
                ),
            ],
          ),

          // ── Player (external app handoff — Android) ─────────────────────
          // External-player handoff is phone-only; the TV plays in its own
          // native player, so hide this whole section on TV.
          if (Platform.isAndroid && !sl<AppMode>().isTv) ...[
            SettingsSectionLabel(context.l10n.sectionPlayer),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.smart_display_outlined,
                  title: context.l10n.defaultPlayer,
                  subtitle: _prefs.externalPlayerPackage.isEmpty
                      ? context.l10n.builtIn
                      : (_prefs.externalPlayerLabel.isNotEmpty ? _prefs.externalPlayerLabel : context.l10n.externalApp),
                  onTap: _pickPlayer,
                ),
                SettingsTile(
                  icon: Icons.tune_rounded,
                  title: context.l10n.playerControls,
                  subtitle: context.l10n.reorderOrHideTheButtonsOnThePlayerBar,
                  onTap: () async {
                    await Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => const PlayerControlsScreen()));
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ],

          // ── Playback behaviour ──────────────────────────────────────────
          SettingsSectionLabel(context.l10n.playback),
          SettingsCard(
            children: [
              _toggleRow(
                icon: Icons.history_outlined,
                title: context.l10n.resumePlayback,
                subtitle: context.l10n.continueFromWhereYouLeftOff,
                value: _prefs.autoResume,
                onChanged: (v) async {
                  await _prefs.setAutoResume(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.visibility_outlined,
                title: context.l10n.askBeforeJumping,
                subtitle: context.l10n.askBeforeJumpingSubtitle,
                value: _prefs.askOnJump,
                onChanged: (v) async {
                  await _prefs.setAskOnJump(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.playlist_add_check_rounded,
                title: context.l10n.autoAddToMyList,
                subtitle: context.l10n.addATitleToMyListWhenYouStartWatchingIt,
                value: _prefs.autoAddToMyList,
                onChanged: (v) async {
                  await _prefs.setAutoAddToMyList(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.sync_rounded,
                title: context.l10n.autoTrack,
                subtitle: context.l10n.autoTrackSubtitle,
                value: _prefs.autoTrack,
                onChanged: (v) async {
                  await _prefs.setAutoTrack(v);
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile(
                icon: Icons.exit_to_app_outlined,
                title: context.l10n.closeConfirmation,
                subtitle: switch (_prefs.closeConfirmation) {
                  'confirm' => context.l10n.closeConfirmationAsk,
                  'direct' => context.l10n.closeConfirmationDirect,
                  _ => context.l10n.closeConfirmationDoubleBack,
                },
                onTap: _pickCloseConfirmation,
              ),
              _toggleRow(
                icon: Icons.skip_next_outlined,
                title: context.l10n.autoplayNextEpisode,
                value: _prefs.autoplayNext,
                onChanged: (v) async {
                  await _prefs.setAutoplayNext(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_outlined,
                title: context.l10n.autoSkipFillerEpisodes,
                subtitle: context.l10n.autoSkipFillerSubtitle,
                value: _prefs.autoSkipFiller,
                onChanged: (v) async {
                  await _prefs.setAutoSkipFiller(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.movie_outlined,
                title: context.l10n.autoplayTrailer,
                subtitle: context.l10n.playATitleSTrailerOnItsDetailPage,
                value: _prefs.autoplayTrailer,
                onChanged: (v) async {
                  await _prefs.setAutoplayTrailer(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: context.l10n.playTrailersInHD,
                subtitle: context.l10n.playTrailersInHDSubtitle,
                value: _prefs.trailerHd,
                onChanged: (v) async {
                  await _prefs.setTrailerHd(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_outlined,
                title: context.l10n.skipIntroButton,
                subtitle: context.l10n.showSkipOpeningEndingOnAnimeWhenDetected,
                value: _prefs.skipIntro,
                onChanged: (v) async {
                  await _prefs.setSkipIntro(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: context.l10n.autoSkipOpening,
                subtitle: context.l10n.jumpPastTheOPOnItsOwnNoTap,
                value: _prefs.autoSkipOp,
                onChanged: (v) async {
                  await _prefs.setAutoSkipOp(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: context.l10n.autoSkipRecap,
                subtitle: context.l10n.jumpPastThePreviouslyOnRecapNoTap,
                value: _prefs.autoSkipRecap,
                onChanged: (v) async {
                  await _prefs.setAutoSkipRecap(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.fast_forward_rounded,
                title: context.l10n.autoSkipEnding,
                subtitle: context.l10n.jumpPastTheEDOnItsOwnNoTap,
                value: _prefs.autoSkipEd,
                onChanged: (v) async {
                  await _prefs.setAutoSkipEd(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.keyboard_double_arrow_right_rounded,
                title: context.l10n.megaskipButton,
                subtitle: context.l10n.aJumpForwardButtonInThePlayerAnyVideo,
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
                        title: context.l10n.megaSkipDuration,
                        subtitle: context.l10n.secondsShort(_prefs.megaSkipSeconds),
                        onTap: _pickMegaSkipDuration,
                      )
                    : _megaSkipDurationRow(),
              if(sl<AppMode>().isTv && !isAppleTv)
                _toggleRow(
                  icon: Icons.forward_10,
                  title: context.l10n.seekButton,
                  subtitle: context.l10n.seekButtonDescription,
                  value: _prefs.seekButtons,
                  onChanged: (v) async {
                    await _prefs.setSeekButtons(v);
                    if (mounted) setState(() {});
                  },
                ),
              if(_prefs.seekButtons)
                SettingsTile(
                  icon: Icons.timer_outlined,
                  title: context.l10n.seekButtonDuration,
                  subtitle: context.l10n.secondsShort(_prefs.tvSeekSeconds),
                  onTap: _pickSeekSecondsForTV,
                ), 
              _toggleRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: context.l10n.keepScreenOn,
                value: _prefs.keepScreenOn,
                onChanged: (v) async {
                  await _prefs.setKeepScreenOn(v);
                  if (mounted) setState(() {});
                },
              ),
              if (sl<AppMode>().isTv && !isAppleTv)
                _toggleRow(
                  icon: Icons.tv_outlined,
                  title: context.l10n.nativeTVPlayer,
                  subtitle: context.l10n.nativeTvPlayerSubtitle,
                  value: _prefs.nativeTvPlayer,
                  onChanged: (v) async {
                    await _prefs.setNativeTvPlayer(v);
                    if (mounted) setState(() {});
                  },
                ),
              if (sl<AppMode>().isTv && !isAppleTv && _prefs.nativeTvPlayer)
                _toggleRow(
                  icon: Icons.surround_sound_outlined,
                  title: context.l10n.softwareAudioDolbyDTS,
                  subtitle: context.l10n.softwareAudioSubtitle,
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
                  title: context.l10n.autoPictureInPicture,
                  subtitle: context.l10n.shrinkToAFloatingWindowWhenYouLeaveTheApp,
                  value: _prefs.autoPip,
                  onChanged: (v) async {
                    await _prefs.setAutoPip(v);
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile(
                icon: Icons.info_outline_rounded,
                title: context.l10n.playerInfoOverlay,
                subtitle: _prefs.playerInfoFields.isEmpty
                    ? context.l10n.playerInfoOff
                    : context.l10n.playerInfoFieldsCount(_prefs.playerInfoFields.length),
                onTap: _pickPlayerInfo,
              ),
              _toggleRow(
                icon: Icons.high_quality_outlined,
                title: context.l10n.showQualityLabel,
                subtitle: context.l10n.plainQualityTextEG1080pOnTheTopBarRight,
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
            SettingsSectionLabel(context.l10n.sectionGestures),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.touch_app_outlined,
                  title: context.l10n.doubleTapSkip,
                  subtitle: _labelFor(_skipOptions, _prefs.doubleTapSeconds, '${_prefs.doubleTapSeconds}s'),
                  onTap: _pickSkip,
                ),
                _toggleRow(
                  icon: Icons.swipe_outlined,
                  title: context.l10n.gestureControls,
                  subtitle: context.l10n.swipeLeftForBrightnessRightForVolume,
                  value: _prefs.gestureControls,
                  onChanged: (v) async {
                    await _prefs.setGestureControls(v);
                    if (mounted) setState(() {});
                  },
                ),
                _toggleRow(
                  icon: Icons.swap_horiz_rounded,
                  title: context.l10n.swipeToSeek,
                  subtitle: context.l10n.dragLeftOrRightAcrossTheVideoToScrub,
                  value: _prefs.swipeSeek,
                  onChanged: (v) async {
                    await _prefs.setSwipeSeek(v);
                    if (mounted) setState(() {});
                  },
                ),
                _toggleRow(
                  icon: Icons.fast_forward_rounded,
                  title: context.l10n.holdFor2Speed,
                  subtitle: context.l10n.longPressTheVideoToPlayAt2WhileHeld,
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
          SettingsSectionLabel(context.l10n.sectionCache),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.memory_rounded,
                title: context.l10n.videoBufferSize,
                subtitle: _labelFor(_bufferSizeOptions(context.l10n), _prefs.videoBufferSize, context.l10n.bufferSizeDefault),
                onTap: _pickBufferSize,
              ),
              SettingsTile(
                icon: Icons.timelapse_rounded,
                title: context.l10n.videoBufferLength,
                subtitle: _labelFor(_bufferLengthOptions(context.l10n), _prefs.videoBufferLength, context.l10n.bufferLengthDefault),
                onTap: _pickBufferLength,
              ),
              SettingsTile(
                icon: Icons.delete_outline_rounded,
                title: context.l10n.clearImageVideoCache,
                subtitle: MediaCache.formatBytes(_cacheBytes),
                onTap: _clearCache,
              ),
            ],
          ),

          // ── Subtitles ───────────────────────────────────────────────────
          SettingsSectionLabel(context.l10n.subtitles),
          SettingsCard(
            children: [
              // libass is the mpv renderer's .ass styling — the native TV
              // player styles subtitles via ExoPlayer instead, so hide on TV.
              if (!sl<AppMode>().isTv)
                _toggleRow(
                  icon: Icons.subtitles_outlined,
                  title: context.l10n.styledSubtitlesLibass,
                  subtitle: context.l10n.styledSubtitlesLibassSubtitlePlayback,
                  value: _prefs.styledSubtitles,
                  onChanged: (v) async {
                    await _prefs.setStyledSubtitles(v);
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile(
                icon: Icons.text_fields_rounded,
                title: context.l10n.subtitleStyle,
                subtitle: context.l10n.subtitleStyleSubtitle,
                onTap: () => openSubtitleStyleSheet(context, null, () {
                  if (mounted) setState(() {});
                }),
              ),
              SettingsTile(
                icon: Icons.vpn_key_outlined,
                title: context.l10n.opensubtitlesAPIKey,
                subtitle: _prefs.subtitleApiKey.trim().isEmpty
                    ? context.l10n.requiredForOnlineSubtitleSearch
                    : context.l10n.keySavedOnlineSearchEnabled,
                onTap: _editSubtitleApiKey,
              ),
              SettingsTile(
                icon: Icons.language_outlined,
                title: context.l10n.subtitleLanguage,
                subtitle: () {
                  final p = _prefs.subtitlePreference;
                  if (p.isEmpty) return context.l10n.auto;
                  if (p == 'off') return context.l10n.off;
                  return languageByPref(p)?.name ?? p.toUpperCase();
                }(),
                onTap: _pickSubtitleLanguage,
              ),
              _toggleRow(
                icon: Icons.download_outlined,
                title: context.l10n.autoDownloadSubtitles,
                subtitle: context.l10n.whenTheSourceHasNoSubtitleInYourLanguage,
                value: _prefs.autoDownloadSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoDownloadSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              _toggleRow(
                icon: Icons.translate_outlined,
                title: context.l10n.autoTranslateSubtitles,
                subtitle: context.l10n.translateToYourLanguageOnPlayWhenTheSourceHasNone,
                value: _prefs.autoTranslateSubtitles,
                onChanged: (v) async {
                  await _prefs.setAutoTranslateSubtitles(v);
                  if (mounted) setState(() {});
                },
              ),
              if (_prefs.autoTranslateSubtitles)
                SettingsTile(
                  icon: Icons.g_translate_outlined,
                  title: context.l10n.translateSubtitlesTo,
                  subtitle: _prefs.translateSubtitleTo.isEmpty
                      ? context.l10n.pickALanguage
                      : (languageByPref(_prefs.translateSubtitleTo)?.name ?? _prefs.translateSubtitleTo.toUpperCase()),
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
      title: context.l10n.translateSubtitlesTo,
      options: [for (final l in kSubtitleLanguages) (l.iso1, l.name)],
      current: _prefs.translateSubtitleTo,
    );
    if (picked == null) return;
    await _prefs.setTranslateSubtitleTo(picked);
    if (mounted) setState(() {});
  }

  Future<void> _pickSubtitleLanguage() async {
    final picked = await showSubtitleLanguagePicker(context, _prefs.subtitlePreference);
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
