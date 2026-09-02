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
  const _CastTab({required this.cast, this.onOpenPerson, this.loading = false});
  final List<CastMember> cast;

  /// Still fetching. Cast arrives on its own request after the detail does, so
  /// without this the tab claimed "No cast information" for a second and then
  /// filled — a wrong answer, not a slow one.
  final bool loading;

  /// Tapping a card with a resolved [CastMember.person] opens their page
  /// (character/actor). Cards without a person id (source-supplied cast) stay
  /// non-tappable.
  final void Function(PersonRef)? onOpenPerson;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      if (loading) return const _CardGridSkeleton();
      return _emptyTab(
        Icons.people_outline_rounded,
        context.l10n.noCastInformation,
      );
    }
    // Split characters from the people who MADE the thing. On a manga the tab
    // holds both, and side by side in one unlabelled grid there's nothing to
    // say which is which — an author reads as just another character with an
    // odd subtitle. Everything else (anime, TMDB, source-supplied cast) has no
    // staff entries, so it falls through as a single unlabelled grid exactly
    // as before.
    final staff = [
      for (final m in cast)
        if (m.person?.source == PersonSource.anilistStaff) m,
    ];
    if (staff.isNotEmpty && staff.length != cast.length) {
      final people = [
        for (final m in cast)
          if (!staff.contains(m)) m,
      ];
      return ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          _castSection(context.l10n.characters, people),
          _castSection(context.l10n.creators, staff),
        ],
      );
    }
    return _grid(
      cast,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      nested: false,
    );
  }

  Widget _castSection(String label, List<CastMember> members) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 2),
          child: Text(
            label.toUpperCase(),
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
          ),
        ),
        _grid(members, padding: const EdgeInsets.fromLTRB(16, 8, 16, 4)),
      ],
    );
  }

  /// [nested] grids sit inside the sectioned ListView and must not scroll
  /// themselves; the single-grid path is the scroll view.
  Widget _grid(
    List<CastMember> members, {
    required EdgeInsets padding,
    bool nested = true,
  }) {
    return GridView.builder(
      shrinkWrap: nested,
      physics: nested ? const NeverScrollableScrollPhysics() : null,
      padding: padding,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.66,
      ),
      itemCount: members.length,
      itemBuilder: (_, i) {
        final m = members[i];
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
    this.loading = false,
    required this.relations,
    required this.onOpen,
    this.tvFocus = false,
  });
  final List<MediaRelation> relations;
  final void Function(MediaRelation) onOpen;

  /// See [_CastTab.loading] — same request, same reason.
  final bool loading;

  /// When true, each card is wrapped in [TvFocusable] so D-pad can navigate
  /// and select relation cards on TV.  Defaults to false — no phone caller
  /// passes this flag, so the phone render is byte-identical to the original.
  final bool tvFocus;

  @override
  Widget build(BuildContext context) {
    if (relations.isEmpty) {
      if (loading) return const _CardGridSkeleton();
      return _emptyTab(
        Icons.account_tree_outlined,
        context.l10n.noRelatedTitles,
      );
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
            semanticLabel: hasRelationTag
                ? '${r.relation}, ${r.title}'
                : r.title,
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
    this.detail,
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

  /// The whole record, for the provider extras below. Optional: a
  /// source-only title has none of them, and the rows simply do not appear.
  final MediaDetail? detail;

  /// Manga/novel: the count row reads "Chapters". Display wording only.
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final desc = description ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        if (sourceName.isNotEmpty)
          _DetailRow(label: context.l10n.playerInfoSource, value: sourceName),
        if (statusStr.isNotEmpty)
          _DetailRow(label: context.l10n.status, value: statusStr),
        if ((year ?? '').isNotEmpty)
          _DetailRow(label: context.l10n.year, value: year!),
        _DetailRow(
          label: reading ? context.l10n.chapters : context.l10n.episodes,
          value: '$episodeCount',
        ),
        if (studios.isNotEmpty)
          _DetailRow(label: context.l10n.studio, value: studios.join(', ')),
        ..._providerRows(context),
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            context.l10n.genres,
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: genres
                .map(
                  (g) => _FilterChip(
                    text: g,
                    // Tappable only on a metadata title, which is what the
                    // catalogue behind the tap can actually answer for. A
                    // source reports its genres as plain strings and filters
                    // by its own arbitrary list — many sources have no genre
                    // filter at all, and the ones that do use their own names
                    // and ids that these strings do not map onto. Sending the
                    // tap to the metadata catalogue would answer a question
                    // about a different library than the one on screen.
                    //
                    // Gated on the source id, NOT on `detail` being null: the
                    // record is always passed, so a null check here was never
                    // once true.
                    onTap: detail?.sourceId == ZmodeIds.sourceId
                        ? () => _browseBy(context, MetaFilters(genres: [g]))
                        : null,
                  ),
                )
                .toList(),
          ),
        ],
        ..._tagChips(context),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            context.l10n.synopsis,
            style: AppText.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 8),
          Text(desc, style: AppText.body),
        ],
      ],
    );
  }

  /// Everything a metadata provider knows that the header has no room for.
  List<Widget> _providerRows(BuildContext context) {
    final d = detail;
    if (d == null) return const [];
    final l10n = context.l10n;
    String? dates() {
      final from = d.startDate, to = d.endDate;
      if (from == null) return null;
      final f = _ymd(from);
      // An open-ended run reads better as "2009 —" than as a false end date.
      if (to == null) return d.status == MediaStatus.ongoing ? '$f  —' : f;
      return '$f  —  ${_ymd(to)}';
    }

    final aired = dates();
    return [
      if (d.format != null) _DetailRow(label: l10n.format, value: d.format!),
      if (d.durationMins != null)
        _DetailRow(label: l10n.duration, value: '${d.durationMins} min'),
      if (d.score != null)
        _DetailRow(label: l10n.score, value: '${d.score! / 10} / 10'),
      if (d.popularity != null)
        _DetailRow(label: l10n.popularity, value: _thousands(d.popularity!)),
      if (d.sourceMaterial != null)
        _DetailRow(label: l10n.sourceMaterial, value: d.sourceMaterial!),
      if (d.country != null)
        _DetailRow(label: l10n.country, value: _countryName(d.country!)),
      if (aired != null) _DetailRow(label: l10n.aired, value: aired),
      if ((d.nativeTitle ?? '').isNotEmpty)
        _DetailRow(label: l10n.nativeTitle, value: d.nativeTitle!),
      if (d.synonyms.isNotEmpty)
        _DetailRow(
          label: l10n.alsoKnownAs,
          // Five is enough to recognise it by; some titles carry thirty.
          value: d.synonyms.take(5).join(' · '),
        ),
    ];
  }

  /// AniList's tags, which say more than the genres do — "Time Travel 92%"
  /// against "Sci-Fi". Spoiler tags are hidden behind a tap rather than
  /// dropped, so the choice stays the reader's.
  List<Widget> _tagChips(BuildContext context) {
    final tags = detail?.tags ?? const <MediaTag>[];
    if (tags.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      Text(
        context.l10n.tags,
        style: AppText.caption.copyWith(color: AppColors.textTertiary),
      ),
      const SizedBox(height: 10),
      _SpoilerTags(tags: tags),
    ];
  }

  static String _ymd(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _thousands(int n) {
    final s = '$n';
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  /// The handful that actually appear on animation and comics. Anything else
  /// keeps its code rather than being guessed at.
  static String _countryName(String code) => switch (code.toUpperCase()) {
    'JP' => 'Japan',
    'KR' => 'South Korea',
    'CN' => 'China',
    'TW' => 'Taiwan',
    'US' => 'United States',
    _ => code.toUpperCase(),
  };
}

/// Tag chips where the spoilers stay covered until asked for.
class _SpoilerTags extends StatefulWidget {
  const _SpoilerTags({required this.tags});
  final List<MediaTag> tags;

  @override
  State<_SpoilerTags> createState() => _SpoilerTagsState();
}

class _SpoilerTagsState extends State<_SpoilerTags> {
  bool _showSpoilers = false;

  @override
  Widget build(BuildContext context) {
    final safe = widget.tags.where((t) => !t.isSpoiler).toList();
    final spoilers = widget.tags.where((t) => t.isSpoiler).toList();
    final shown = _showSpoilers ? widget.tags : safe;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in shown)
              _FilterChip(
                text: t.rank == null ? t.name : '${t.name}  ${t.rank}%',
                accent: t.isSpoiler,
                onTap: () => _browseBy(context, MetaFilters(tags: [t.name])),
              ),
          ],
        ),
        if (spoilers.isNotEmpty && !_showSpoilers)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: GestureDetector(
              onTap: () => setState(() => _showSpoilers = true),
              child: Text(
                context.l10n.showSpoilerTags(spoilers.length),
                style: AppText.caption.copyWith(color: AppColors.accent),
              ),
            ),
          ),
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

/// A small outlined chip beside the meta line — "4K", "HD", "18+".
///
/// No countdown chip here: the episode list already carries one, fed by the
/// tracker, and two of them on one page is one too many.
class _MetaBadge extends StatelessWidget {
  const _MetaBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.textTertiary),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: AppText.caption.copyWith(
          color: AppColors.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A genre or tag chip that opens a filtered browse.
///
/// Looks like [TagBadge] because it IS one — only the tap is new.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.text,
    required this.onTap,
    this.accent = false,
  });

  final String text;

  /// Null leaves the chip as plain information — see the genre chips, which
  /// are only tappable when a metadata provider is behind them.
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: TagBadge(
      text: text,
      color: accent ? AppColors.accent : AppColors.textSecondary,
    ),
  );
}

/// Open Search on everything matching [filters].
///
/// Only AniList and TMDB actually narrow a catalogue. MAL accepts a `genres`
/// parameter and answers with the same unfiltered list, and Simkl ignores its
/// own `genre` the same way — so on those the tap would look like it worked
/// and quietly show the wrong titles. It says so instead.
void _browseBy(BuildContext context, MetaFilters filters) {
  if (!sl<MetadataRepository>().supportsFilters) {
    final kind = browseKindFor(
      sl<ContentModeCubit>().state,
      ZModePrefs.streamKind,
    );
    final needed = (kind == ZKind.movie || kind == ZKind.tv)
        ? 'TMDB'
        : 'AniList';
    showAppToast(context, context.l10n.filtersNeedProvider(needed));
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SearchScreen(initialFilters: filters),
    ),
  );
}

/// Poster-shaped placeholders for a grid that has not arrived yet.
///
/// Shares the shimmer with the page skeleton, so a tab that fills late looks
/// like the same app rather than a different loading state.
class _CardGridSkeleton extends StatelessWidget {
  const _CardGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final cell = (MediaQuery.sizeOf(context).width - 32 - 24) / 3;
    return _Shimmer(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: posterGridAspect(context),
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        // Enough to fill the fold and no more — rows nobody can see still
        // cost a frame to lay out.
        itemCount: 9,
        itemBuilder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bone(cell, cell * 1.5, 12),
            const SizedBox(height: 8),
            _bone(cell * 0.75, 11),
          ],
        ),
      ),
    );
  }
}
