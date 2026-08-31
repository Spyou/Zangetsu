// Audio & subtitles, online subtitle search, subtitle styling and colour sheets.
part of 'player_screen.dart';

String _subtitleOutlineLabel(AppLocalizations l10n, String id) => switch (id) {
  'none' => l10n.subtitleOutlineNone,
  'soft' => l10n.subtitleOutlineSoft,
  'outline' => l10n.subtitleOutlineOutline,
  'bold' => l10n.subtitleOutlineBold,
  'shadow' => l10n.subtitleOutlineShadow,
  'glow' => l10n.subtitleOutlineGlow,
  _ => id,
};

String _subtitleColourLabel(AppLocalizations l10n, String hex) => switch (hex) {
  '#FFFFFFFF' => l10n.colourWhite,
  '#FFFF00FF' => l10n.colourYellow,
  '#00E5FFFF' => l10n.accentCyan,
  '#7CFC00FF' => l10n.colourGreen,
  '#FF6B6BFF' => l10n.colourRed,
  '#000000FF' => l10n.colourBlack,
  _ => hex,
};

class _AudioSubsSheet extends StatefulWidget {
  const _AudioSubsSheet({
    required this.controller,
    required this.onInteract,
    required this.onLoadFile,
    required this.onSearchOnline,
    required this.onTranslate,
  });
  final PlayerCubit controller;
  final VoidCallback onInteract;
  final VoidCallback onLoadFile;
  final VoidCallback onSearchOnline;
  final VoidCallback onTranslate;

  @override
  State<_AudioSubsSheet> createState() => _AudioSubsSheetState();
}

class _AudioSubsSheetState extends State<_AudioSubsSheet> {
  late String _category = widget.controller.activeCategory;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final h = MediaQuery.of(context).size.height;
    return StreamBuilder<Track>(
      stream: c.player.stream.track,
      builder: (context, snap) {
        final track = snap.data ?? c.player.state.track;
        final audioId = track.audio.id;
        final subId = track.subtitle.id;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: h * 0.5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _audioColumn(c, audioId)),
                      Container(
                        width: 0.5,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        color: AppColors.hairline,
                      ),
                      Expanded(child: _subColumn(c, subId)),
                    ],
                  ),
                ),
                const Divider(color: AppColors.hairline, height: 18),
                _DelayAdjuster(
                  label: context.l10n.subtitleDelay,
                  initial: c.subtitleDelay,
                  onChanged: (d) => c.setSubtitleDelay(d),
                  // Aniyomi-style two-tap auto-sync (subtitle only). Captures
                  // live on the controller so they survive closing the sheet.
                  sync: (
                    capture: c.captureSubSync,
                    clear: c.clearSubSync,
                    currentMs: () => c.subtitleDelay.inMilliseconds,
                    voiceOn: () => c.subSyncVoiceMs != null,
                    textOn: () => c.subSyncTextMs != null,
                  ),
                ),
                _DelayAdjuster(
                  label: context.l10n.audioDelay,
                  initial: c.audioDelay,
                  onChanged: (d) => c.setAudioDelay(d),
                ),
                _SheetRow(
                  label: context.l10n.audioNormalization,
                  subtitle: context.l10n.audioNormalizationSubtitle,
                  active: sl<PlaybackPrefs>().audioNormalize,
                  onTap: () async {
                    await c.toggleAudioNormalize();
                    if (mounted) setState(() {});
                    widget.onInteract();
                  },
                ),
                _SheetRow(
                  label: context.l10n.subtitleStyle,
                  icon: Icons.text_fields_rounded,
                  active: false,
                  onTap: () {
                    widget.onInteract();
                    openSubtitleStyleSheet(context, c, widget.onInteract);
                  },
                ),
                _SheetRow(
                  label: context.l10n.styledSubtitlesLibass,
                  subtitle: context.l10n.styledSubtitlesLibassSubtitle,
                  toggleValue: c.styledSubtitlesOn,
                  active: false,
                  onTap: () {
                    c.toggleStyledSubtitles();
                    if (mounted) setState(() {});
                    widget.onInteract();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _audioColumn(PlayerCubit c, String audioId) {
    final cats = c.categories;
    final tracks = c.mediaAudioTracks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetSectionHeader(context.l10n.audio),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (cats.length > 1)
                for (final cat in cats)
                  _SheetRow(
                    label: cat.toUpperCase(),
                    active: _category == cat,
                    onTap: () {
                      c.switchCategory(cat);
                      setState(() => _category = cat);
                      widget.onInteract();
                    },
                  ),
              for (final t in tracks)
                _SheetRow(
                  label: t.language ?? t.title ?? t.id,
                  active: audioId == t.id,
                  onTap: () {
                    c.setAudioTrack(t);
                    widget.onInteract();
                  },
                ),
              if (cats.length <= 1 && tracks.length <= 1)
                _SheetRow(label: context.l10n.defaultLabel, active: true, onTap: () {}),
            ],
          ),
        ),
      ],
    );
  }

  Widget _subColumn(PlayerCubit c, String subId) {
    final embedded = c.mediaSubtitleTracks;
    final soft = c.softSubs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetSectionHeader(context.l10n.subtitles),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              _SheetRow(
                label: () {
                  final p = sl<PlaybackPrefs>().subtitlePreference;
                  final name = p.isEmpty
                      ? context.l10n.auto
                      : (p == 'off'
                            ? context.l10n.off
                            : (languageByPref(p)?.name ?? p.toUpperCase()));
                  return context.l10n.preferredLanguageColon(name);
                }(),
                icon: Icons.language_rounded,
                active: false,
                onTap: () async {
                  final picked = await showSubtitleLanguagePicker(
                    context, sl<PlaybackPrefs>().subtitlePreference);
                  if (picked == null) return;
                  await sl<PlaybackPrefs>().setSubtitlePreference(picked);
                  c.reapplyPreferredSubtitle();
                  widget.onInteract();
                },
              ),
              _SheetRow(
                label: context.l10n.off,
                active: subId == 'no',
                onTap: () {
                  c.subtitlesOff();
                  widget.onInteract();
                },
              ),
              for (final t in embedded)
                _SheetRow(
                  label: t.title ?? t.language ?? t.id,
                  active: subId == t.id,
                  onTap: () {
                    c.setSubtitle(t);
                    widget.onInteract();
                  },
                ),
              for (final s in soft)
                _SheetRow(
                  label: s.label ?? s.lang,
                  // A URI soft-sub is applied via SubtitleTrack.uri(s.url), whose
                  // media_kit track id IS the url — so the active one highlights.
                  active: subId == s.url,
                  onTap: () {
                    c.setSoftSub(s);
                    widget.onInteract();
                  },
                ),
              _SheetRow(
                label: context.l10n.searchSubtitlesOnline,
                icon: Icons.search_rounded,
                active: false,
                onTap: widget.onSearchOnline,
              ),
              _SheetRow(
                label: context.l10n.loadFromFile,
                icon: Icons.upload_file,
                active: false,
                onTap: widget.onLoadFile,
              ),
              if (c.softSubs.isNotEmpty || c.canTranslateSub)
                _SheetRow(
                  label: context.l10n.translateSubtitles,
                  icon: Icons.translate_rounded,
                  active: false,
                  onTap: widget.onTranslate,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Online subtitle search (OpenSubtitles). A query field (prefilled with the
/// show title) + a results list; tapping a result downloads it and calls
/// [onApply] with the local file path. Surfaces a loading state and readable
/// errors (including the "add an API key" hint when no key is set).
class _OnlineSubtitleSheet extends StatefulWidget {
  const _OnlineSubtitleSheet({
    required this.initialQuery,
    required this.onApply,
    this.initialLanguage = '',
    this.imdbId,
    this.tmdbId,
  });
  final String initialQuery;
  final Future<void> Function(String localPath) onApply;

  /// ISO-639-1 code pre-selected in the language picker ('' = any language).
  final String initialLanguage;

  /// When non-null, passed to [SubtitleSearchService.search] for higher
  /// accuracy (OpenSubtitles can search by IMDb/TMDB id in addition to title).
  final String? imdbId;
  final int? tmdbId;

  @override
  State<_OnlineSubtitleSheet> createState() => _OnlineSubtitleSheetState();
}

class _OnlineSubtitleSheetState extends State<_OnlineSubtitleSheet> {
  final _service = SubtitleSearchService();
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );

  /// ISO-639-1 code for the selected search language, or '' = any language.
  late String _selectedLang = widget.initialLanguage;

  bool _searching = false;
  bool _downloading = false;
  String? _error;
  List<SubtitleSearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await _service.search(
        q,
        language: _selectedLang.isEmpty ? '' : _selectedLang,
        imdbId: widget.imdbId,
        tmdbId: widget.tmdbId,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        if (results.isEmpty) {
          _error = context.l10n.noSubtitlesFoundFor(q);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e is SubtitleSearchException
            ? e.message
            : context.l10n.searchFailedWithError('$e');
      });
    }
  }

  Future<void> _pick(SubtitleSearchResult r) async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final path = await _service.download(r);
      if (!mounted) return;
      await widget.onApply(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e is SubtitleSearchException
            ? e.message
            : context.l10n.downloadFailedWithError('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 10 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(context.l10n.searchSubtitlesOnline, style: AppText.headline),
          ),
          // Language picker — defaults to the user's preferred subtitle
          // language (when set in Settings) and lets the user change it
          // per-search without leaving the sheet.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(
              children: [
                Text(
                  context.l10n.language,
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _selectedLang.isEmpty ? '' : _selectedLang,
                  dropdownColor: AppColors.surface2,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        context.l10n.any,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    for (final lang in kSubtitleLanguages)
                      DropdownMenuItem(
                        value: lang.iso1,
                        child: Text(
                          lang.name,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedLang = v);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _query,
              autofocus: widget.initialQuery.trim().isEmpty,
              textInputAction: TextInputAction.search,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: context.l10n.movieOrShowTitle,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  tooltip: context.l10n.search,
                  onPressed: _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: h * 0.42),
            child: _body(),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_searching) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    if (_error != null && _results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
        child: Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return Stack(
      children: [
        ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ),
            for (final r in _results)
              _SheetRow(
                label: r.language.isNotEmpty
                    ? '[${r.language.toUpperCase()}] ${r.name}'
                    : r.name,
                active: false,
                onTap: () => _pick(r),
              ),
          ],
        ),
        if (_downloading)
          Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Opens the Subtitle-style sheet (font / colour / background / position /
/// size). Lives over whatever opened it; changes apply live via the controller.
/// Opens the shared Subtitle-style sheet (live preview + all controls). Pass a
/// [controller] from the player so changes apply to the video live; pass null
/// from Settings, where there's no active player and it just persists prefs.
void openSubtitleStyleSheet(
  BuildContext context,
  PlayerCubit? controller,
  VoidCallback onInteract,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _SheetSurface(
      blur: true,
      opacity: 0.82,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: _SubtitleStyleSheet(
          controller: controller,
          onInteract: onInteract,
        ),
      ),
    ),
  );
}

/// Live subtitle styling: bundled-font picker, text colour swatches, a
/// background-opacity slider, a vertical-position slider, and size. Each change
/// persists to [PlaybackPrefs] and re-applies via [PlayerCubit.applySubtitleStyle].
class _SubtitleStyleSheet extends StatefulWidget {
  const _SubtitleStyleSheet({
    required this.controller,
    required this.onInteract,
  });
  final PlayerCubit? controller;
  final VoidCallback onInteract;

  @override
  State<_SubtitleStyleSheet> createState() => _SubtitleStyleSheetState();
}

class _SubtitleStyleSheetState extends State<_SubtitleStyleSheet> {
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  /// Which fonts are usable now (Default/bundled/downloaded). A font that isn't
  /// downloaded yet is fetched on tap. Populated in [initState].
  final Map<String, bool> _fontAvailable = {};

  /// Fonts currently downloading — their row shows a spinner.
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    () async {
      for (final f in kBundledSubtitleFonts) {
        if (f.isEmpty) continue;
        _fontAvailable[f] = await SubtitleFontService.instance.isAvailable(f);
      }
      if (mounted) setState(() {});
    }();
  }

  /// Apply a font — downloading it first (with a spinner on its row) if it
  /// isn't cached yet.
  Future<void> _pickFont(String f) async {
    if (f.isNotEmpty && !(_fontAvailable[f] ?? true)) {
      if (_downloading.contains(f)) return; // already fetching
      setState(() => _downloading.add(f));
      final ok = await SubtitleFontService.instance.ensure(f);
      if (!mounted) return;
      setState(() {
        _downloading.remove(f);
        _fontAvailable[f] = ok;
      });
      if (!ok) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.couldntDownloadFile(f))),
        );
        return;
      }
    }
    await _apply(() => _prefs.setSubtitleFont(f));
  }

  // Text-colour swatches, stored as #RRGGBBAA (opaque).
  static const List<String> _colorHexes = [
    '#FFFFFFFF',
    '#FFFF00FF',
    '#00E5FFFF',
    '#7CFC00FF',
    '#FF6B6BFF',
    '#000000FF',
  ];
  Future<void> _apply(Future<void> Function() mutate) async {
    await mutate();
    await widget.controller?.applySubtitleStyle();
    if (mounted) setState(() {});
    widget.onInteract();
  }

  /// Reset every subtitle-style pref to its default value.
  Future<void> _resetToDefault() => _apply(() async {
        await _prefs.setSubtitleFont('');
        await _prefs.setSubtitleColorHex('#FFFFFFFF');
        await _prefs.setSubtitleTextOpacity(1.0);
        await _prefs.setSubtitleOutlineType('soft');
        await _prefs.setSubtitleOutlineColorHex('#000000FF');
        await _prefs.setSubtitleOutlineWidth(2.0);
        await _prefs.setSubtitleBgOpacity(0.0);
        await _prefs.setSubtitlePosition(95);
        await _prefs.setSubtitleScale(1.0);
      });

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final font = _prefs.subtitleFont;
    final colorHex = _prefs.subtitleColorHex.toUpperCase();
    final size = _prefs.subtitleScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(context.l10n.subtitleStyle, style: AppText.headline),
          ),
          // Live WYSIWYG preview — built with the SAME buildSubtitleTextStyle as
          // the real overlay, so what you see here is what renders on the video.
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            height: 92,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF33405E), Color(0xFF0E121B)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                context.l10n.theQuickBrownFox,
                textAlign: TextAlign.center,
                style: buildSubtitleTextStyle(_prefs, fontSize: 22.0 * size),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _SheetSectionHeader(context.l10n.font),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: h * 0.28),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final f in kBundledSubtitleFonts)
                        _SheetRow(
                          label: f.isEmpty ? context.l10n.defaultLabel : f,
                          subtitle: _downloading.contains(f)
                              ? context.l10n.downloading
                              : ((_fontAvailable[f] ?? true)
                                    ? null
                                    : context.l10n.tapToDownloadFont),
                          loading: _downloading.contains(f),
                          active: font == f,
                          onTap: () => _pickFont(f),
                        ),
                    ],
                  ),
                ),
                _SheetSectionHeader(context.l10n.textColour),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final hex in _colorHexes)
                        _ColorSwatch(
                          color: _colorFromHex(hex),
                          label: _subtitleColourLabel(context.l10n, hex),
                          active: colorHex == hex,
                          onTap: () =>
                              _apply(() => _prefs.setSubtitleColorHex(hex)),
                        ),
                    ],
                  ),
                ),
                _SheetSectionHeader(context.l10n.textOpacity),
                _SliderRow(
                  value: _prefs.subtitleTextOpacity,
                  min: 0.1,
                  max: 1,
                  divisions: 9,
                  label: '${(_prefs.subtitleTextOpacity * 100).round()}%',
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleTextOpacity(v)),
                ),
                _SheetSectionHeader(context.l10n.outlineStyle),
                for (final (id, _) in kSubtitleOutlineTypes)
                  _SheetRow(
                    label: _subtitleOutlineLabel(context.l10n, id),
                    active: _prefs.subtitleOutlineType == id,
                    onTap: () =>
                        _apply(() => _prefs.setSubtitleOutlineType(id)),
                  ),
                _SheetSectionHeader(context.l10n.outlineColour),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final hex in _colorHexes)
                        _ColorSwatch(
                          color: _colorFromHex(hex),
                          label: _subtitleColourLabel(context.l10n, hex),
                          active:
                              _prefs.subtitleOutlineColorHex.toUpperCase() == hex,
                          onTap: () => _apply(
                            () => _prefs.setSubtitleOutlineColorHex(hex),
                          ),
                        ),
                    ],
                  ),
                ),
                _SheetSectionHeader(context.l10n.outlineWidth),
                _SliderRow(
                  value: _prefs.subtitleOutlineWidth,
                  min: 0,
                  max: 8,
                  divisions: 16,
                  label: _prefs.subtitleOutlineWidth.toStringAsFixed(1),
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleOutlineWidth(v)),
                ),
                _SheetSectionHeader(context.l10n.background),
                _SliderRow(
                  value: _prefs.subtitleBgOpacity,
                  min: 0,
                  max: 1,
                  divisions: 10,
                  label: '${(_prefs.subtitleBgOpacity * 100).round()}%',
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleBgOpacity(v)),
                ),
                _SheetSectionHeader(context.l10n.positionLabel),
                _SliderRow(
                  value: _prefs.subtitlePosition.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: _prefs.subtitlePosition >= 50
                      ? context.l10n.positionBottom
                      : context.l10n.positionTop,
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitlePosition(v.round())),
                ),
                _SheetSectionHeader(context.l10n.subtitleSize),
                _SliderRow(
                  value: size.clamp(0.6, 2.0),
                  min: 0.6,
                  max: 2.0,
                  divisions: 14,
                  label: '${(size * 100).round()}%',
                  onChanged: (v) => _apply(() => _prefs.setSubtitleScale(v)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: OutlinedButton.icon(
                    onPressed: _resetToDefault,
                    icon: const Icon(Icons.restart_alt_rounded, size: 19),
                    label: Text(context.l10n.resetToDefault),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: BorderSide(color: AppColors.hairline),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _colorFromHex(String hex) {
    // Stored as #RRGGBBAA → Flutter wants 0xAARRGGBB.
    final h = hex.replaceFirst('#', '');
    if (h.length != 8) return Colors.white;
    final rgb = h.substring(0, 6);
    final a = h.substring(6, 8);
    return Color(int.parse('$a$rgb', radix: 16));
  }
}

/// A circular colour swatch with a label, accent-ringed when active.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final Color color;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? AppColors.accent : AppColors.hairline,
              width: active ? 3 : 1,
            ),
          ),
          child: active
              ? Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: color.computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
                )
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: AppText.caption.copyWith(
            color: active ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ],
    );
    // TV: GestureDetector isn't D-pad focusable, so colours can't be selected.
    // Wrap in TvFocusable (OK selects, shows a focus ring). Mobile keeps the tap.
    if (sl<AppMode>().isTv) {
      return TvFocusable(onTap: onTap, child: content);
    }
    return GestureDetector(onTap: onTap, child: content);
  }
}

/// A labelled slider row used inside the Subtitle-style sheet.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    // On TV a focused Slider swallows D-pad ↑/↓ (you can't move off it). Swap in
    // a focusable ◄ value ► stepper: ◄/► adjust, ↑/↓ move to the next control.
    if (sl<AppMode>().isTv) {
      final step = (max - min) / divisions;
      return _TvStepperRow(
        label: label,
        onDec: value <= min ? null : () => onChanged((value - step).clamp(min, max)),
        onInc: value >= max ? null : () => onChanged((value + step).clamp(min, max)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                thumbColor: AppColors.accent,
                inactiveTrackColor: AppColors.surface2,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TV replacement for [_SliderRow]'s slider: one full-width focusable row so
/// D-pad ▲/▼ reliably land on it (edge buttons get skipped by directional
/// focus, and a Slider would trap ▲/▼). When focused (accent ring), ◀ decreases
/// and ▶ increases; ▲/▼/OK pass through to move to the next control.
class _TvStepperRow extends StatefulWidget {
  const _TvStepperRow({required this.label, this.onDec, this.onInc});
  final String label;
  final VoidCallback? onDec;
  final VoidCallback? onInc;
  @override
  State<_TvStepperRow> createState() => _TvStepperRowState();
}

class _TvStepperRowState extends State<_TvStepperRow> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onDec?.call();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onInc?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // ▲/▼/OK propagate → focus traversal
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _focused
              ? AppColors.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          border: Border.all(
            color: _focused ? AppColors.accent : AppColors.surface2,
            width: _focused ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.chevron_left,
                color: widget.onDec == null
                    ? AppColors.textTertiary
                    : AppColors.accent),
            Expanded(
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(Icons.chevron_right,
                color: widget.onInc == null
                    ? AppColors.textTertiary
                    : AppColors.accent),
          ],
        ),
      ),
    );
  }
}

/// Play/pause button whose icon MORPHS between play and pause (Dantotsu/YouTube
/// style) instead of a hard swap. Driven by [playing]; sits in a soft ringed
/// circle. Pure UI — [onTap] is the same togglePlay call as before.
/// Soft, rounded play/pause (reDantotsu-style) — the stock [AnimatedIcons]
/// morph uses sharp, blocky shapes; the `_rounded` variants have the pill
/// corners we want. Cross-fades + gently scales between the two on toggle.
class _SheetSurface extends StatelessWidget {
  const _SheetSurface({
    bool blur = true,
    double opacity = 0.75,
    BorderRadius? borderRadius,
    required this.child,
  });
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(24);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        0,
        10,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: r,
                  border: Border.all(color: AppColors.hairline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 40,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: ClipRRect(borderRadius: r, child: child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour-adjustment sheet: quick-preset chips + individual sliders for mpv's
/// video equalizer (brightness/contrast/saturation/gamma/hue, -100..100). Live
/// preview on drag; persists on release.
class _ColorSheet extends StatefulWidget {
  const _ColorSheet({required this.controller, required this.onInteract});
  final PlayerCubit controller;
  final VoidCallback onInteract;
  @override
  State<_ColorSheet> createState() => _ColorSheetState();
}

class _ColorSheetState extends State<_ColorSheet> {
  late int _b, _c, _s, _g, _h;

  static const _quick = [
    'natural',
    'anime',
    'anime_vibrant',
    'vivid',
    'cinema',
    'grayscale',
  ];

  @override
  void initState() {
    super.initState();
    final p = sl<PlaybackPrefs>();
    _b = p.colorBrightness;
    _c = p.colorContrast;
    _s = p.colorSaturation;
    _g = p.colorGamma;
    _h = p.colorHue;
  }

  void _applyPreset(ColorProfile prof) {
    widget.controller.applyColorPreset(prof);
    setState(() {
      _b = prof.brightness;
      _c = prof.contrast;
      _s = prof.saturation;
      _g = prof.gamma;
      _h = prof.hue;
    });
    widget.onInteract();
  }

  Widget _slider(String label, String prop, int value, ValueChanged<int> set) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: AppText.body),
              Text(
                value > 0 ? '+$value' : '$value',
                style: AppText.body.copyWith(
                  color: value == 0 ? AppColors.textTertiary : AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              thumbColor: AppColors.accent,
              inactiveTrackColor: AppColors.textSecondary.withValues(alpha: 0.3),
              overlayColor: AppColors.accent.withValues(alpha: 0.2),
            ),
            child: Slider(
              min: -100,
              max: 100,
              divisions: 200,
              value: value.toDouble(),
              label: '$value',
              onChanged: (v) {
                set(v.round());
                widget.controller.previewColor(prop, v.round());
              },
              onChangeEnd: (v) => widget.controller.setColor(prop, v.round()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(context.l10n.colour, style: AppText.headline),
              TextButton(
                onPressed: () {
                  widget.controller.resetColor();
                  setState(() => _b = _c = _s = _g = _h = 0);
                  widget.onInteract();
                },
                child: Text(context.l10n.reset),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final id in _quick)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _applyPreset(ColorProfiles.byId(id)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        ColorProfiles.byId(id).label,
                        style: AppText.body,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            children: [
              _slider(context.l10n.brightness, 'brightness', _b, (v) => setState(() => _b = v)),
              _slider(context.l10n.contrast, 'contrast', _c, (v) => setState(() => _c = v)),
              _slider(context.l10n.saturation, 'saturation', _s, (v) => setState(() => _s = v)),
              _slider(context.l10n.gamma, 'gamma', _g, (v) => setState(() => _g = v)),
              _slider(context.l10n.hue, 'hue', _h, (v) => setState(() => _h = v)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A sheet whose options are one wrapping row of chips rather than a vertical
/// list. For short lists of short values — the kind where a full-height list
/// costs the whole screen for six words. Same grab handle and header as
/// [_SheetColumn] so the two read as the same family.
class _SheetChips extends StatelessWidget {
  const _SheetChips({
    required this.header,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final String header;
  final List<String> labels;
  final int selected; // -1 = nothing matches
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(header, style: AppText.headline),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < labels.length; i++)
                Material(
                  color: i == selected
                      ? AppColors.accent
                      : Colors.transparent,
                  shape: StadiumBorder(
                    side: i == selected
                        ? BorderSide.none
                        : BorderSide(
                            color: Colors.white.withValues(alpha: 0.16),
                          ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelect(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(
                        labels[i],
                        style: AppText.body.copyWith(
                          color: i == selected
                              ? Colors.white
                              : AppColors.textSecondary,
                          fontWeight: i == selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
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

class _SheetColumn extends StatelessWidget {
  const _SheetColumn({required this.header, required this.children});
  final String header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(header, style: AppText.headline),
        ),
        // Cap the list height so a long sheet (e.g. the ~25-language translate
        // list) scrolls instead of overflowing and clipping at whatever fits.
        // Short sheets are shorter than the cap, so shrinkWrap still sizes them
        // to their content and they look/behave exactly as before.
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: ListView(shrinkWrap: true, children: children),
          ),
        ),
      ],
    );
  }
}

/// Source-picker row label: the provider's per-source name with its resolution
/// appended (e.g. "MovieBox (Hindi Audio) · 1080p"), so the quality shows even
/// when the source carries its own name. Skips a non-resolution quality
/// ("auto"/empty) and never doubles up a resolution the name already contains.
String _sourceLabelWithQuality(String label, String? quality) {
  final q = (quality ?? '').trim();
  if (q.isEmpty || q.toLowerCase() == 'auto') return label;
  if (label.toLowerCase().contains(q.toLowerCase())) return label;
  return '$label · $q';
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.toggleValue,
    this.loading = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Optional trailing icon (e.g. upload for "Load from file…").
  final IconData? icon;

  /// Optional secondary line under the label — explains what a setting does
  /// (e.g. for jargon like "Audio normalization") so it's self-describing.
  final String? subtitle;

  /// When non-null, the row is a toggle: renders a trailing Switch reflecting
  /// this value (instead of the icon/check), and stays plain (no accent tint).
  final bool? toggleValue;

  /// Show a trailing spinner (e.g. while a font downloads).
  final bool loading;

  @override
  Widget build(BuildContext context) {
    // Netflix-style: the selected row is tinted + accent-bold with a trailing
    // check; others are plain.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: toggleValue == null && active
            ? AppColors.accentSoft
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: AppText.body.copyWith(
                          color: toggleValue == null && active
                              ? AppColors.accent
                              : AppColors.textPrimary,
                          fontWeight: toggleValue == null && active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                else if (toggleValue != null)
                  Switch.adaptive(
                    value: toggleValue!,
                    onChanged: (_) => onTap(),
                    activeThumbColor: AppColors.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )
                else if (icon != null)
                  Icon(icon, color: AppColors.textSecondary, size: 20)
                else if (active)
                  Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.accent,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A −/value/+ stepper for a sync delay (subtitle or audio), in 0.25s steps.
/// Holds its own value so the sheet updates live.
class _DelayAdjuster extends StatefulWidget {
  const _DelayAdjuster({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.sync,
  });
  final String label;
  final Duration initial;
  final ValueChanged<Duration> onChanged;

  /// When set, shows the Aniyomi-style two-tap auto-sync below the stepper.
  /// [capture] records a tap (voice/text) and returns the applied delta (ms)
  /// once both are set; [currentMs] reads the resulting delay; [voiceOn]/
  /// [textOn] report which point is currently captured (for the highlight).
  final ({
    int? Function(bool voice) capture,
    void Function() clear,
    int Function() currentMs,
    bool Function() voiceOn,
    bool Function() textOn,
  })?
  sync;

  @override
  State<_DelayAdjuster> createState() => _DelayAdjusterState();
}

class _DelayAdjusterState extends State<_DelayAdjuster> {
  late int _ms = widget.initial.inMilliseconds;
  static const int _step = 250;

  // The two-tap captures themselves live on the controller (via [widget.sync])
  // so they survive closing the sheet; here we only hold the transient note.
  String? _note;
  Timer? _noteTimer;

  @override
  void dispose() {
    _noteTimer?.cancel();
    super.dispose();
  }

  void _bump(int delta) {
    setState(() => _ms = (_ms + delta).clamp(-30000, 30000));
    widget.onChanged(Duration(milliseconds: _ms));
  }

  void _capture(bool voice) {
    final delta = widget.sync!.capture(voice);
    if (delta != null) {
      // Both points captured → the controller applied the offset; mirror it.
      setState(() => _ms = widget.sync!.currentMs().clamp(-30000, 30000));
      final s = (delta / 1000).toStringAsFixed(2);
      _flashNote(context.l10n.alignedDelay('${delta >= 0 ? '+' : ''}$s'));
    } else {
      setState(() {}); // reflect the single-capture highlight
    }
  }

  void _flashNote(String msg) {
    _noteTimer?.cancel();
    setState(() => _note = msg);
    _noteTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _note = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final secs = (_ms / 1000).toStringAsFixed(2);
    final shown = _ms > 0 ? '+${secs}s' : '${secs}s';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
              ),
              _stepBtn(
                Icons.remove_rounded,
                () => _bump(-_step),
                semanticLabel: context.l10n.decreaseDelay(
                  widget.label.toLowerCase(),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  shown,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(
                    color: _ms == 0 ? AppColors.textSecondary : AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _stepBtn(
                Icons.add_rounded,
                () => _bump(_step),
                semanticLabel: context.l10n.increaseDelay(
                  widget.label.toLowerCase(),
                ),
              ),
              IconButton(
                tooltip: context.l10n.reset,
                icon: const Icon(
                  Icons.restart_alt_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                onPressed: _ms == 0 ? null : () => _bump(-_ms),
              ),
            ],
          ),
        ),
        if (widget.sync != null) _syncSection(),
      ],
    );
  }

  Widget _syncSection() {
    final s = widget.sync!;
    final voiceOn = s.voiceOn();
    final textOn = s.textOn();
    // Progress-aware hint so it's obvious what to do next (and that a capture
    // is still pending after you reopen the sheet).
    final hint = _note ??
        (voiceOn
            ? context.l10n.subtitleSyncVoiceCaptured
            : textOn
            ? context.l10n.subtitleSyncTextCaptured
            : context.l10n.subtitleSyncHint);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hint,
                  style: AppText.caption.copyWith(
                    color: (_note != null || voiceOn || textOn)
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              ),
              // Cancel a pending capture without applying anything.
              if (voiceOn || textOn)
                InkWell(
                  onTap: () {
                    s.clear();
                    _noteTimer?.cancel();
                    setState(() => _note = null);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      context.l10n.clear,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _syncBtn(
                  context.l10n.voiceHeard,
                  Icons.hearing_rounded,
                  voiceOn,
                  () => _capture(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _syncBtn(
                  context.l10n.subtitleSeen,
                  Icons.subtitles_rounded,
                  textOn,
                  () => _capture(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _syncBtn(String label, IconData icon, bool done, VoidCallback onTap) {
    return Material(
      color: done
          ? AppColors.accent.withValues(alpha: 0.18)
          : AppColors.surface2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: done ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: done ? AppColors.accent : AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepBtn(
    IconData icon,
    VoidCallback onTap, {
    String? semanticLabel,
  }) => Semantics(
    button: true,
    label: semanticLabel,
    child: Material(
      color: AppColors.surface2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: AppColors.textPrimary, size: 20),
        ),
      ),
    ),
  );
}

/// "Stats for nerds" info panel — shows the user-selected [fields] (keys from
/// [kPlayerInfoFields]) in a translucent top-left card, refreshed ~1×/sec.
/// Read-only; auto-shown with the controls.
class _SheetSectionHeader extends StatelessWidget {
  const _SheetSectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
      child: Text(
        label.toUpperCase(),
        style: AppText.caption.copyWith(
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
