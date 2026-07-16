import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/metadata/people_service.dart';
import '../../core/models/media_item.dart';
import '../../core/models/person.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

/// A person page — an anime character or voice actor/staff (AniList), or a
/// movie/TV person (TMDB). Opened from the Detail screen's Cast tab. Metadata
/// only: it never touches a provider except to open a tapped title in the
/// active source (searched by title, like the Relations tab).
class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.person, this.sourceId});

  final PersonRef person;

  /// The source to search when a title on this page is tapped. Null → active.
  final String? sourceId;

  static Route<void> route(PersonRef person, {String? sourceId}) =>
      MaterialPageRoute<void>(
        builder: (_) => PersonPage(person: person, sourceId: sourceId),
      );

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  late Future<PersonProfile?> _future;
  bool _bioExpanded = false;

  @override
  void initState() {
    super.initState();
    _future = sl<PeopleService>().load(widget.person);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Open a title from this person's works — search the active source by title
  /// and open the first match (same approach as the Relations tab).
  Future<void> _openWork(PersonWork w) async {
    _snack('Finding “${w.title}”…');
    try {
      final results =
          await sl<SourceRepository>().search(w.title, sourceId: widget.sourceId);
      if (!mounted) return;
      final match = bestTitleMatch(
        results,
        w.title,
        altTitle: w.romaji,
        wantedMalId: w.malId,
      );
      if (match == null) {
        _snack('“${w.title}” isn’t on this source');
        return;
      }
      Navigator.of(context).push(DetailScreen.route(match));
    } catch (_) {
      if (mounted) _snack('Couldn’t open “${w.title}”');
    }
  }

  void _openRelated(PersonRef ref) {
    Navigator.of(context).push(PersonPage.route(ref, sourceId: widget.sourceId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          widget.person.name,
          style: AppText.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<PersonProfile?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          final p = snap.data;
          if (p == null) {
            return const EmptyState(
              icon: Icons.person_off_outlined,
              message: 'Couldn’t load this profile',
            );
          }
          return _content(p);
        },
      ),
    );
  }

  Widget _content(PersonProfile p) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header(p)),
        if (p.description != null && p.description!.isNotEmpty)
          SliverToBoxAdapter(child: _bio(p.description!)),
        if (p.related.isNotEmpty)
          SliverToBoxAdapter(child: _relatedRow(p.related)),
        if (p.works.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _sectionLabel(
              widget.person.source == PersonSource.anilistStaff
                  ? 'Roles'
                  : 'Appears in',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.5,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _workCard(p.works[i]),
                childCount: p.works.length,
              ),
            ),
          ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _header(PersonProfile p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 118,
              height: 158,
              child: (p.photo != null && p.photo!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: p.photo!,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(color: AppColors.surface2),
                      errorWidget: (_, _, _) => const _PortraitFallback(),
                    )
                  : const _PortraitFallback(),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(p.name, style: AppText.title),
                if (p.nativeName != null && p.nativeName!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(p.nativeName!, style: AppText.body),
                ],
                if (p.subtitle != null && p.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.accentSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      p.subtitle!,
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bio(String text) {
    return GestureDetector(
      onTap: () => setState(() => _bioExpanded = !_bioExpanded),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              maxLines: _bioExpanded ? null : 4,
              overflow: _bioExpanded ? null : TextOverflow.ellipsis,
              style: AppText.body,
            ),
            const SizedBox(height: 4),
            Text(
              _bioExpanded ? 'Show less' : 'Read more',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _relatedRow(List<PersonRef> people) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('Voiced by'),
        SizedBox(
          height: 108,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            itemCount: people.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, i) {
              final r = people[i];
              return GestureDetector(
                onTap: () => _openRelated(r),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 64,
                  child: Column(
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 60,
                          height: 60,
                          child: (r.photo != null && r.photo!.isNotEmpty)
                              ? CachedNetworkImage(
                                  imageUrl: r.photo!,
                                  fit: BoxFit.cover,
                                  placeholder: (_, _) =>
                                      Container(color: AppColors.surface2),
                                  errorWidget: (_, _, _) =>
                                      const _PortraitFallback(),
                                )
                              : const _PortraitFallback(),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        r.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppText.caption.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(text, style: AppText.overline),
      );

  Widget _workCard(PersonWork w) {
    return GestureDetector(
      onTap: () => _openWork(w),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: (w.cover != null && w.cover!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: w.cover!,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(color: AppColors.surface2),
                      errorWidget: (_, _, _) =>
                          Container(color: AppColors.surface2),
                    )
                  : Container(color: AppColors.surface2),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            w.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppColors.textPrimary),
          ),
          if (w.subtitle != null && w.subtitle!.isNotEmpty)
            Text(
              w.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _PortraitFallback extends StatelessWidget {
  const _PortraitFallback();
  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surface2,
        alignment: Alignment.center,
        child: const Icon(
          Icons.person_rounded,
          color: AppColors.textTertiary,
          size: 34,
        ),
      );
}
