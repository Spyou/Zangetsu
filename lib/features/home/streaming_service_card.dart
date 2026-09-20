import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'streaming_logo_tint.dart';

/// One service card.
///
/// The tile IS the brand icon — one surface, nothing layered behind it.
///
/// Because the logo fills the tile, scaling the TILE scales the logo: phone
/// press and TV focus both make the brand art swell and an accent ring light
/// up, with no inner edge anywhere to give away a second box.
class StreamingServiceCard extends StatefulWidget {
  const StreamingServiceCard({
    super.key,
    required this.service,
    required this.width,
    required this.height,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
  });

  final StreamingService service;
  final double width;
  final double height;
  final VoidCallback onTap;

  /// Optional secondary action — a long-press on phone, a held OK on TV.
  final VoidCallback? onLongPress;

  /// TV only: take D-pad focus on first build. Ignored on phone.
  final bool autofocus;

  @override
  State<StreamingServiceCard> createState() => _StreamingServiceCardState();
}

class _StreamingServiceCardState extends State<StreamingServiceCard> {
  /// The brand background behind the logo, once read. Starts from the cache so
  /// a service already seen paints correctly on its first frame rather than
  /// flashing the neutral plate every time the rail scrolls it back.
  StreamingTint? _tint;

  /// The card is held invisible until its colour is known, then faded in as
  /// one piece. Painting the neutral plate first and recolouring it a moment
  /// later is the flash that made loading look cheap.
  bool _ready = false;

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  void initState() {
    super.initState();
    final url = widget.service.logoUrl;
    if (url == null) {
      _ready = true;
      return;
    }
    _tint = StreamingLogoTint.cached(url);
    if (StreamingLogoTint.isKnown(url)) {
      _ready = true;
      return;
    }
    StreamingLogoTint.of(url).then((t) {
      if (!mounted) return;
      // Ready even when the tint came back null — an unreadable logo still
      // gets its card, on the neutral plate.
      setState(() {
        _tint = t;
        _ready = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // 220ms, matching the app's other content fade-ins. No press animation:
    // the card carries the brand's own art and a scale on top of that reads
    // as the logo wobbling rather than as feedback.
    final card = AnimatedOpacity(
      opacity: _ready ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: _card(highlighted: false),
    );
    if (_isTv) {
      // TV still needs a highlight — it is the only thing saying where the
      // D-pad is. TvFocusable owns it.
      return TvFocusable(
        key: ValueKey('tv-service-rail-${widget.service.id}'),
        autofocus: widget.autofocus,
        variant: TvFocusVariant.float,
        scale: 1.06,
        borderRadius: 18,
        semanticLabel: widget.service.name,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        builder: (focused) => AnimatedOpacity(
          opacity: _ready ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: _card(highlighted: focused),
        ),
      );
    }
    return Semantics(
      label: widget.service.name,
      button: true,
      // A plain ripple for touch feedback — the platform's own, not an
      // animation of ours.
      child: Stack(
        children: [
          card,
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              shape: const RoundedSuperellipseBorder(
                borderRadius: BorderRadius.all(Radius.circular(18)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required bool highlighted}) {
    final logo = widget.service.logoUrl;
    final tint = _tint;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          // The brand's own background, read off its logo. Two stops rather
          // than one because a third of these logos are gradients, and a flat
          // fill seams against them.
          color: tint == null ? AppColors.surface2 : null,
          gradient: tint == null
              ? null
              : LinearGradient(
                  begin: tint.vertical
                      ? Alignment.topCenter
                      : Alignment.centerLeft,
                  end: tint.vertical
                      ? Alignment.bottomCenter
                      : Alignment.centerRight,
                  colors: [tint.start, tint.end],
                ),
          // A squircle, not a rounded rect — the corner curvature is
          // continuous, which is why an iOS tile reads soft where a plain
          // circular radius reads cut off at the tangent.
          shape: RoundedSuperellipseBorder(
            borderRadius: const BorderRadius.all(Radius.circular(18)),
            // No resting stroke. An outline around brand art reads as a box
            // drawn over someone else's logo, and the reason it was here —
            // dark cards looking smaller — is properly handled by
            // [StreamingTint.contentScale] normalising the marks instead.
            // The ring appears only on TV focus, where it is the only thing
            // saying where the D-pad is.
            side: highlighted
                ? BorderSide(color: AppColors.accent, width: 2)
                : BorderSide.none,
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          child: logo == null
              ? _fallback()
              : Center(
                  // The square logo sits in the middle of the wide card. Its
                  // own background IS the card colour, so the square's edges
                  // are invisible and it reads as one card with a mark on it.
                  child: Image.network(
                    logo,
                    // Normalised so Apple TV's small wordmark reads the same
                    // size as Netflix's N — see [StreamingTint.contentScale].
                    height: widget.height * (tint?.contentScale ?? 1.0),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => _fallback(),
                  ),
                ),
        ),
      ),
    );
  }

  /// Only when there is no logo at all — then, and only then, a neutral plate
  /// carrying the name is the honest tile.
  Widget _fallback() => ColoredBox(
    color: AppColors.surface2,
    child: Center(
      child: Padding(padding: const EdgeInsets.all(8), child: _name()),
    ),
  );

  Widget _name() => Text(
    widget.service.name,
    textAlign: TextAlign.center,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700),
  );
}
