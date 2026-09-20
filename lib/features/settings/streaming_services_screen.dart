import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/streaming_providers.dart';
import '../../core/metadata/streaming_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/streaming_prefs.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/tmdb_catalogue.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen.dart';
import '../home/streaming_service_card.dart';

/// Browse films and series by the service that carries them where you are.
///
/// Logos come from TMDB's own `logo_path`, served from its image CDN like any
/// poster — no brand artwork lives in this repo.
///
/// This screen browses a CATALOGUE. It does not play anything: a title opens
/// Detail and resolves through the user's own sources exactly like every other
/// title in the app. The note under the header says so, because a grid of
/// service logos invites the opposite assumption.
class StreamingServicesScreen extends StatefulWidget {
  const StreamingServicesScreen({super.key});

  @override
  State<StreamingServicesScreen> createState() =>
      _StreamingServicesScreenState();
}

class _StreamingServicesScreenState extends State<StreamingServicesScreen> {
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
        builder: (_) => SeeAllScreen(
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
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(l10n.streamingServices, style: AppText.headline),
      ),
      body: FutureBuilder<List<StreamingService>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final services = snap.data ?? const <StreamingService>[];
          if (services.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.streamingServicesEmpty,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
            );
          }
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    l10n.streamingServicesMetadataNote,
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverGrid(
                  // Same proportions as the Home rail's cards, and the same
                  // widget — the two must not drift into different designs for
                  // the same thing.
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 150,
                        // The card's own ratio plus room for the caption.
                        childAspectRatio: 128 / 92,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 12,
                      ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _tile(services[i]),
                    childCount: services.length,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(StreamingService s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: StreamingServiceCard(
            key: ValueKey('service-${s.id}'),
            service: s,
            width: double.infinity,
            height: double.infinity,
            onTap: () => _open(s),
          ),
        ),
        const SizedBox(height: 6),
        // Named here but not in the Home rail: the rail shows the majors,
        // which are recognisable from the mark alone, while this is the whole
        // list and most of it is not.
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
