import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/tmdb_catalogue.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen_tv.dart';
import '../home/streaming_service_card.dart';

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
                          // The card's own ratio plus room for the caption.
                          childAspectRatio: 128 / 92,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: StreamingServiceCard(
            key: ValueKey('tv-service-${s.id}'),
            service: s,
            width: double.infinity,
            height: double.infinity,
            autofocus: autofocus,
            onTap: () => _open(s),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
