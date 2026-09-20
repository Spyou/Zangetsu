import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/app_mode.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../l10n/l10n.dart';
import 'streaming_service_card.dart';

/// Home's streaming-service rail: a horizontal strip of service logos for the
/// user's country. Tapping one opens that service's catalogue.
///
/// Renders NOTHING when the region lists no services — a titled row with an
/// empty strip reads as broken, and this row ships enabled, so it has to
/// disappear on its own rather than leave a gap.
///
/// Logos are TMDB's own `logo_path`, served from its image CDN like any poster.
/// This browses a catalogue; it plays nothing.
class StreamingServicesRow extends StatefulWidget {
  const StreamingServicesRow({
    super.key,
    required this.onOpen,
    required this.onSeeAll,
    this.firstAutofocus = false,
  });

  final void Function(StreamingService) onOpen;
  final VoidCallback onSeeAll;

  /// TV only: give the first card D-pad focus when the pane opens.
  final bool firstAutofocus;

  @override
  State<StreamingServicesRow> createState() => _StreamingServicesRowState();
}

class _StreamingServicesRowState extends State<StreamingServicesRow> {
  /// Enough to fill a phone rail twice over without making the first paint wait
  /// on a long tail nobody scrolls to.
  static const int _max = 12;

  /// Wide cards, each filled with the BRAND's own colour (read off the logo by
  /// [StreamingLogoTint]) with the square logo drawn on top. Because the fill
  /// is the logo's exact background colour, the two blend with no inner edge —
  /// which is what made every earlier attempt look like a box inside a box.
  static const double _tileW = 128;
  static const double _tileH = 70;

  /// TV sits further from the eye and indents further from the bezel, so the
  /// cards and the insets both grow. Matches [TvRail]'s 48px gutter and 20px
  /// title rather than scaling the phone numbers by eye.
  static const double _tvTileW = 168;
  static const double _tvTileH = 92;

  late Future<List<StreamingService>> _future;

  @override
  void initState() {
    super.initState();
    _future = sl.isRegistered<StreamingProvidersService>()
        ? sl<StreamingProvidersService>().list(StreamingPrefs.region)
        : Future.value(const []);
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv;
    final tileW = isTv ? _tvTileW : _tileW;
    final tileH = isTv ? _tvTileH : _tileH;
    return FutureBuilder<List<StreamingService>>(
      future: _future,
      builder: (context, snap) {
        // Loading gets the app's own shimmer rather than a blank gap, so the
        // rail holds its space instead of shoving the rows below it down the
        // moment it arrives.
        if (snap.connectionState != ConnectionState.done) {
          return RowSkeleton(itemWidth: tileW, itemHeight: tileH);
        }
        final all = snap.data ?? const <StreamingService>[];
        // Nothing for this region: collapse. A titled row with an empty strip
        // reads as broken, and this row ships enabled.
        if (all.isEmpty) return const SizedBox.shrink();
        final services = all.take(_max).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Phone copies ContentRow; TV copies TvRail. Either way the
            // numbers are the neighbouring rows' own, not an approximation —
            // this row sits between real ones and any drift shows.
            Padding(
              padding: isTv
                  ? const EdgeInsets.fromLTRB(48, 26, 48, 14)
                  : const EdgeInsets.fromLTRB(16, 26, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.streamingServices,
                      style: isTv
                          ? const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            )
                          : AppText.headline,
                    ),
                  ),
                  // Phone only. TV gets its See All as the last CARD in the
                  // rail instead — a text button beside a row title is not a
                  // shape TV rows have, and putting a focus stop up here would
                  // sit awkwardly between the rail and the rows around it.
                  // At the end of the rail the D-pad simply walks onto it.
                  if (!isTv)
                    GestureDetector(
                      onTap: widget.onSeeAll,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          context.l10n.seeAll,
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              // Headroom on TV so a focused card's scale-up and its glow spill
              // past the box instead of being cropped, exactly as TvRail does.
              height: isTv ? tileH + 26 : tileH,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: isTv ? Clip.none : Clip.hardEdge,
                padding: EdgeInsets.symmetric(horizontal: isTv ? 48 : 16),
                // One extra on TV: the trailing See All card. The rail shows
                // at most [_max] of what can be 90+ services in a region, so
                // without it TV had no way to reach the rest — the screen
                // existed and nothing could open it.
                itemCount: services.length + (isTv ? 1 : 0),
                separatorBuilder: (_, _) => SizedBox(width: isTv ? 16 : 12),
                itemBuilder: (context, i) => Align(
                  alignment: Alignment.topCenter,
                  child: isTv && i == services.length
                      ? _SeeAllCard(
                          width: tileW,
                          height: tileH,
                          onTap: widget.onSeeAll,
                        )
                      : StreamingServiceCard(
                          service: services[i],
                          width: tileW,
                          height: tileH,
                          autofocus: widget.firstAutofocus && i == 0,
                          onTap: () => widget.onOpen(services[i]),
                        ),
                ),
              ),
            ),
            if (isTv) const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

/// The trailing card that opens the full service list on TV.
///
/// A card rather than a button beside the title so the D-pad reaches it by
/// simply continuing right off the end of the rail — the same gesture the user
/// is already making to browse it.
///
/// Deliberately plain: it is not a brand, so it does not wear a brand's colour.
class _SeeAllCard extends StatelessWidget {
  const _SeeAllCard({
    required this.width,
    required this.height,
    required this.onTap,
  });

  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TvFocusable(
    key: const ValueKey('tv-service-rail-see-all'),
    variant: TvFocusVariant.float,
    scale: 1.06,
    borderRadius: 18,
    semanticLabel: context.l10n.seeAll,
    onTap: onTap,
    builder: (focused) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: AppColors.surface2,
        shape: RoundedSuperellipseBorder(
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          side: focused
              ? BorderSide(color: AppColors.accent, width: 2)
              : BorderSide.none,
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.grid_view_rounded,
            size: 26,
            color: focused ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.seeAll,
            style: AppText.caption.copyWith(
              color: focused ? AppColors.accent : AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}
