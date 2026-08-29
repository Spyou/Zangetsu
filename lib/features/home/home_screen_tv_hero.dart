// The TV hero banner with its rotating backdrop.
part of 'home_screen_tv.dart';


// ── TV Hero ─────────────────────────────────────────────────────────────────

/// Full-bleed cinematic hero for TV: the artwork fills the banner, a left-side
/// scrim keeps the copy readable, and the title logo (or text), a meta line and
/// the Play / My List / Info buttons sit bottom-left — Apple-TV style. The
/// buttons pass through [wrapButton] so they become D-pad focusable.
class _TvHero extends StatefulWidget {
  const _TvHero({
    required this.items,
    required this.inListOf,
    required this.metaOf,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    required this.wrapButton,
  });

  /// Featured titles the hero rotates through (Apple-TV style).
  final List<MediaItem> items;
  final bool Function(MediaItem) inListOf;
  final Future<HeroMeta?>? Function(MediaItem) metaOf;
  final void Function(MediaItem) onPlay;
  final void Function(MediaItem) onInfo;
  final void Function(MediaItem) onToggleList;
  final Widget Function(
    Widget child,
    VoidCallback onTap, {
    bool autofocus,
    String? semanticLabel,
  })
  wrapButton;

  @override
  State<_TvHero> createState() => _TvHeroState();
}

class _TvHeroState extends State<_TvHero> {
  int _i = 0;
  String? _logoUrl; // TMDB title logo (null → show the text title)
  Timer? _timer;

  MediaItem get _item => widget.items[_i % widget.items.length];

  @override
  void initState() {
    super.initState();
    _loadLogo();
    _startRotation();
  }

  @override
  void didUpdateWidget(_TvHero old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length) {
      _i = widget.items.isEmpty ? 0 : _i % widget.items.length;
      _startRotation();
      _loadLogo();
    }
  }

  /// Cycle the featured title every few seconds. The Focus nodes persist across
  /// these rebuilds, so rotating never steals focus from the rows below.
  void _startRotation() {
    _timer?.cancel();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 9), (_) {
        if (!mounted) return;
        setState(() {
          _i = (_i + 1) % widget.items.length;
          _logoUrl = null;
        });
        _loadLogo();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadLogo() async {
    if (!sl.isRegistered<TitleLogoService>()) return;
    final idx = _i;
    try {
      final url = await sl<TitleLogoService>().logoFor(_item);
      if (mounted && idx == _i && url != null && url.isNotEmpty) {
        setState(() => _logoUrl = url);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final inList = widget.inListOf(item);
    final cover = item.cover;
    final hasCover = cover != null && cover.isNotEmpty;
    final mq = MediaQuery.of(context);
    final memW = (mq.size.width * mq.devicePixelRatio).round();
    final provider =
        hasCover ? nativeCoverProvider(cover, item.coverHeaders) : null;

    return SizedBox(
      height: mq.size.height * 0.72,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: AppColors.bg),
          if (provider != null)
            Image(
              image: ResizeImage(provider, width: memW),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
            )
          else
            ColoredBox(color: AppColors.surface2),
          // Left scrim for copy legibility.
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xE60B0B0F), Color(0x4D0B0B0F), Color(0x000B0B0F)],
                    stops: [0.0, 0.44, 0.72],
                  ),
                ),
              ),
            ),
          ),
          // Bottom fade into the page so the rails below sit seamlessly.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [AppColors.bg, const Color(0x000B0B0F)],
                    stops: const [0.015, 0.5],
                  ),
                ),
              ),
            ),
          ),
          // Copy + actions, bottom-left (aligned with the row titles below).
          Positioned(
            left: 48,
            right: 48,
            bottom: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: mq.size.width * 0.5,
                    maxHeight: 112,
                  ),
                  child: _logoUrl != null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: CachedNetworkImage(
                            imageUrl: _logoUrl!,
                            cacheManager: AppImageCache.manager,
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            memCacheWidth: memW,
                            fadeInDuration: const Duration(milliseconds: 250),
                            errorWidget: (_, _, _) => _titleText(),
                          ),
                        )
                      : _titleText(),
                ),
                const SizedBox(height: 16),
                _metaLine(item),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    widget.wrapButton(
                      _playBtn(),
                      () => widget.onPlay(item),
                      autofocus: true,
                      semanticLabel: 'Play',
                    ),
                    const SizedBox(width: 14),
                    widget.wrapButton(
                      _glassBtn(
                        inList ? Icons.check_rounded : Icons.add_rounded,
                        'My List',
                        active: inList,
                      ),
                      () => widget.onToggleList(item),
                      semanticLabel: 'My List',
                    ),
                    const SizedBox(width: 14),
                    widget.wrapButton(
                      _glassBtn(Icons.info_outline_rounded, 'Info'),
                      () => widget.onInfo(item),
                      semanticLabel: 'Info',
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Page dots (Apple-TV) — one per featured title, current one widened.
          if (widget.items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var d = 0; d < widget.items.length; d++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: d == _i ? 20 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: d == _i
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _titleText() => Text(
        _item.title,
        style: AppText.largeTitle.copyWith(
          fontSize: 52,
          height: 1.0,
          letterSpacing: -0.8,
          fontWeight: FontWeight.w800,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

  Widget _metaLine(MediaItem item) {
    return FutureBuilder<HeroMeta?>(
      future: widget.metaOf(item),
      builder: (context, snap) {
        final m = snap.data;
        if (m == null) return const SizedBox(height: 16);
        final parts = <String>[...m.genres.take(3)];
        if (m.episodeCount > 1) {
          parts.add('${m.episodeCount} Episodes');
        } else if ((m.year ?? '').isNotEmpty) {
          parts.add(m.year!);
        }
        if (parts.isEmpty) return const SizedBox(height: 16);
        return Text(
          parts.join('   ·   ').toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: Colors.white.withValues(alpha: 0.9),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
          ),
        );
      },
    );
  }

  Widget _playBtn() => Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow_rounded, color: AppColors.bg, size: 24),
            const SizedBox(width: 8),
            Text(
              'Play',
              style: TextStyle(
                fontFamily: 'Inter',
                color: AppColors.bg,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );

  Widget _glassBtn(IconData icon, String label, {bool active = false}) =>
      Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? AppColors.accent : Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
}
