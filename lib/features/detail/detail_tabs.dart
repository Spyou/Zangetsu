// Cast, Relations and Details tabs.
part of 'detail_screen.dart';


// ─────────────────────────────────────────────────────────────────────────────
// Cast tab — chips of cast members; graceful empty state.
// ─────────────────────────────────────────────────────────────────────────────

/// [EmptyState] wrapped so it can sit in a [TabBarView] body inside a
/// [NestedScrollView]: scrollable (so the header can still collapse) and
/// centered via a min-height box, which avoids the bottom overflow when the
/// collapsed viewport is shorter than the icon + text.
Widget _emptyTab(IconData icon, String message) => LayoutBuilder(
  builder: (context, constraints) => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: constraints.maxHeight),
      child: EmptyState(icon: icon, message: message),
    ),
  ),
);

class _CastTab extends StatelessWidget {
  const _CastTab({required this.cast, this.onOpenPerson});
  final List<CastMember> cast;

  /// Tapping a card with a resolved [CastMember.person] opens their page
  /// (character/actor). Cards without a person id (source-supplied cast) stay
  /// non-tappable.
  final void Function(PersonRef)? onOpenPerson;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      return _emptyTab(Icons.people_outline_rounded, 'No cast information');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.66,
      ),
      itemCount: cast.length,
      itemBuilder: (_, i) {
        final m = cast[i];
        final card = Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: (m.photo != null && m.photo!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: m.photo!,
                        fit: BoxFit.cover,
                        // Small avatar cell — decode it small, not full-res.
                        memCacheWidth: 200,
                        placeholder: (_, _) =>
                            Container(color: AppColors.surface2),
                        errorWidget: (_, _, _) => const _AvatarFallback(),
                      )
                    : const _AvatarFallback(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              m.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (m.role != null && m.role!.isNotEmpty)
              Text(
                m.role!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
          ],
        );
        final ref = m.person;
        if (ref == null || onOpenPerson == null) return card;
        return GestureDetector(
          onTap: () => onOpenPerson!(ref),
          behavior: HitTestBehavior.opaque,
          child: card,
        );
      },
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();
  @override
  Widget build(BuildContext context) => Container(
    color: AppColors.surface2,
    alignment: Alignment.center,
    child: const Icon(
      Icons.person_rounded,
      color: AppColors.textTertiary,
      size: 30,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Relations tab — related/recommended titles; tap searches the active source.
// ─────────────────────────────────────────────────────────────────────────────

class _RelationsTab extends StatelessWidget {
  const _RelationsTab({
    required this.relations,
    required this.onOpen,
    this.tvFocus = false,
  });
  final List<MediaRelation> relations;
  final void Function(MediaRelation) onOpen;

  /// When true, each card is wrapped in [TvFocusable] so D-pad can navigate
  /// and select relation cards on TV.  Defaults to false — no phone caller
  /// passes this flag, so the phone render is byte-identical to the original.
  final bool tvFocus;

  @override
  Widget build(BuildContext context) {
    if (relations.isEmpty) {
      return _emptyTab(Icons.account_tree_outlined, 'No related titles');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.47,
      ),
      itemCount: relations.length,
      itemBuilder: (_, i) {
        final r = relations[i];
        final visual = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: (r.cover != null && r.cover!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: r.cover!,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: AppColors.surface2),
                        errorWidget: (_, _, _) =>
                            Container(color: AppColors.surface2),
                      )
                    : Container(color: AppColors.surface2),
              ),
            ),
            const SizedBox(height: 6),
            if (r.relation != null && r.relation!.isNotEmpty)
              Text(
                r.relation!.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: AppColors.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            Text(
              r.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.textPrimary),
            ),
          ],
        );
        // TV path: D-pad-navigable TvFocusable wrapper.
        if (tvFocus) {
          final hasRelationTag = r.relation != null && r.relation!.isNotEmpty;
          return TvFocusable(
            key: ValueKey('tv-rel-$i'),
            onTap: () => onOpen(r),
            semanticLabel: hasRelationTag ? '${r.relation}, ${r.title}' : r.title,
            // visual is shared with the phone branch below — exclude it here
            // instead of touching it.
            child: ExcludeSemantics(child: visual),
          );
        }
        // Phone path: original GestureDetector — byte-identical to the old code.
        return GestureDetector(
          onTap: () => onOpen(r),
          behavior: HitTestBehavior.opaque,
          child: visual,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Details tab — source / status / genres / studios / episode count / synopsis.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.sourceName,
    required this.statusStr,
    required this.genres,
    required this.studios,
    required this.episodeCount,
    required this.year,
    required this.description,
    this.reading = false,
  });

  final String sourceName;
  final String statusStr;
  final List<String> genres;
  final List<String> studios;
  final int episodeCount;
  final String? year;
  final String? description;

  /// Manga/novel: the count row reads "Chapters". Display wording only.
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final desc = description ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        if (sourceName.isNotEmpty)
          _DetailRow(label: 'Source', value: sourceName),
        if (statusStr.isNotEmpty) _DetailRow(label: 'Status', value: statusStr),
        if ((year ?? '').isNotEmpty) _DetailRow(label: 'Year', value: year!),
        _DetailRow(
            label: reading ? 'Chapters' : 'Episodes',
            value: '$episodeCount'),
        if (studios.isNotEmpty)
          _DetailRow(label: 'Studio', value: studios.join(', ')),
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'Genres',
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: genres
                .map((g) => TagBadge(text: g, color: AppColors.textSecondary))
                .toList(),
          ),
        ],
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Synopsis',
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 8),
          Text(desc, style: AppText.body),
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppText.caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
