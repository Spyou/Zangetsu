import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/tmdb_catalogue.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen_tv.dart';

/// TV twin of the phone streaming-services grid.
///
/// Same rules: TMDB's own logos, browsing only, pins capped. Only the
/// interaction model differs — every tile is a [TvFocusable] so the D-pad walks
/// the grid, OK opens the service, and a held OK pins it, which is the same
/// held-OK-for-the-secondary-action pattern the library grid uses.
class StreamingServicesScreenTv extends StatefulWidget {
  const StreamingServicesScreenTv({super.key});

  @override
  State<StreamingServicesScreenTv> createState() =>
      _StreamingServicesScreenTvState();
}

class _StreamingServicesScreenTvState extends State<StreamingServicesScreenTv> {
  /// Six across matches the see-all grid on a 1080p panel.
  static const int _columns = 6;

  late Future<List<StreamingService>> _future;

  @override
  void initState() {
    super.initState();
    _future = sl<StreamingProvidersService>().list(StreamingPrefs.region);
  }

  bool _isPinned(int id) => StreamingPrefs.pinned.any((p) => p.id == id);

  Future<void> _togglePin(StreamingService s) async {
    final pins = [...StreamingPrefs.pinned];
    final at = pins.indexWhere((p) => p.id == s.id);
    if (at >= 0) {
      pins.removeAt(at);
    } else {
      if (pins.length >= StreamingPrefs.maxPinned) {
        showAppToast(
          context,
          context.l10n.pinLimitReached(StreamingPrefs.maxPinned),
        );
        return;
      }
      pins.add(StreamingPin(id: s.id, name: s.name));
    }
    await StreamingPrefs.setPinned(pins);
    if (mounted) setState(() {});
  }

  Future<void> _open(StreamingService s) async {
    final repo = sl<MetadataRepository>();
    final more = BrowseMore(
      sourceId: ZmodeIds.sourceId,
      kind: 'zm_video',
      categoryId: TmdbCatalogue.wpRowId(s.id),
    );
    List<MediaItem> first;
    try {
      first = await repo.browseMore(more, 1);
    } catch (_) {
      first = const [];
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SeeAllScreenTv(
          title: s.name,
          items: first,
          onTap: (m) => Navigator.push(context, DetailScreen.route(m)),
          onLoadMore: (page) => repo.browseMore(more, page),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: FutureBuilder<List<StreamingService>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final services = snap.data ?? const <StreamingService>[];
            if (services.isEmpty) {
              return Center(
                child: Text(
                  l10n.streamingServicesEmpty,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 24, 48, 4),
                  child: Text(l10n.streamingServices, style: AppText.headline),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 0, 48, 16),
                  child: Text(
                    l10n.streamingServicesMetadataNote,
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(48, 0, 48, 32),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _columns,
                          childAspectRatio: 16 / 9,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                        ),
                    itemCount: services.length,
                    itemBuilder: (context, i) => _tile(services[i], i == 0),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tile(StreamingService s, bool autofocus) {
    final pinned = _isPinned(s.id);
    final logo = s.logoUrl;
    return TvFocusable(
      key: ValueKey('tv-service-${s.id}'),
      autofocus: autofocus,
      variant: TvFocusVariant.float,
      scale: 1.04,
      borderRadius: 12,
      semanticLabel: s.name,
      onTap: () => _open(s),
      onLongPress: () => _togglePin(s),
      builder: (focused) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: pinned ? Border.all(color: AppColors.accent, width: 2) : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The logo is decoration; the name below is the label. Keeping the
            // name in exactly ONE place matters — a fallback that also draws
            // the name renders it twice whenever the logo fails to load.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              child: logo == null
                  ? const Center(
                      child: Icon(
                        Icons.live_tv_rounded,
                        color: AppColors.textTertiary,
                      ),
                    )
                  : Image.network(
                      logo,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(
                          Icons.live_tv_rounded,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
            ),
            Positioned(
              left: 6,
              right: 6,
              bottom: 5,
              child: Text(
                s.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
            if (pinned)
              Positioned(
                top: 6,
                right: 6,
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 16,
                  color: AppColors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
