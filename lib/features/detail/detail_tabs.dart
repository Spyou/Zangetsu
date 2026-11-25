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

/// A tap target that visibly reacts, the same 0.97 squeeze [PosterCard] uses.
///
/// These grids were bare [GestureDetector]s over static art, so a tap looked
/// like nothing had happened — and opening a relation runs a source search
/// first, so "nothing" lasted about a second before the page changed.
class _PressableCard extends StatefulWidget {
  const _PressableCard({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<_PressableCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onTapDown: (_) => setState(() => _down = true),
    onTapUp: (_) => setState(() => _down = false),
    onTapCancel: () => setState(() => _down = false),
    behavior: HitTestBehavior.opaque,
    child: AnimatedScale(
      scale: _down ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: widget.child,
    ),
  );
}

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
        return _PressableCard(onTap: () => onOpenPerson!(ref), child: card);
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
    this.seasons = const [],
    this.tvFocus = false,
  });
  final List<MediaRelation> relations;

  /// The franchise's seasons in order. Empty for most titles — and then this
  /// tab renders exactly as it always did, one grid of relations.
  final List<SeasonEntry> seasons;
  final void Function(MediaRelation) onOpen;

  /// See [_CastTab.loading] — same request, same reason.
  final bool loading;

  /// When true, each card is wrapped in [TvFocusable] so D-pad can navigate
  /// and select relation cards on TV.  Defaults to false — no phone caller
  /// passes this flag, so the phone render is byte-identical to the original.
  final bool tvFocus;

  /// A season drawn as a relation card. Reusing [MediaRelation] is the whole
  /// trick: the card, the accent label and the tap handler are then the ones
  /// the tab already has, so a season behaves exactly like every other poster
  /// here — including opening its OWN title, with its own tracking.
  static MediaRelation _asRelation(
    BuildContext context,
    SeasonEntry s,
  ) => MediaRelation(
    title: s.title,
    cover: s.cover,
    relation: s.isCurrent
        ? '${context.l10n.seasonNumber(s.number)} · ${context.l10n.statusWatching}'
        : context.l10n.seasonNumber(s.number),
    malId: s.malId,
    anilistId: s.anilistId,
  );

  /// The relations left once the seasons have been lifted out.
  ///
  /// A prequel is also season 2; showing it in both places is the same title
  /// twice on one screen. Everything that is NOT a season — films, the source
  /// manga, side stories, recaps — is untouched.
  List<MediaRelation> get _rest {
    if (seasons.isEmpty) return relations;
    final taken = {
      for (final s in seasons) ...[
        if (s.anilistId != null) 'a:${s.anilistId}',
        if (s.malId != null) 'm:${s.malId}',
      ],
    };
    return [
      for (final r in relations)
        if (!taken.contains('a:${r.anilistId}') &&
            !taken.contains('m:${r.malId}'))
          r,
    ];
  }

  SliverGridDelegate _grid(BuildContext context) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: posterGridColumns(context),
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: posterLayout(context) == PosterCardLayout.wide
            ? 0.95
            : 0.47,
      );

  @override
  Widget build(BuildContext context) {
    if (relations.isEmpty && seasons.isEmpty) {
      if (loading) return const _CardGridSkeleton();
      return _emptyTab(
        Icons.account_tree_outlined,
        context.l10n.noRelatedTitles,
      );
    }
    // One grid and no headings when there are no seasons — byte-identical to
    // what this tab rendered before seasons existed.
    if (seasons.isEmpty) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
        gridDelegate: _grid(context),
        itemCount: relations.length,
        itemBuilder: (_, i) => _card(context, relations[i], i),
      );
    }
    final rest = _rest;
    return CustomScrollView(
      slivers: [
        _header(context, context.l10n.seasons),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          sliver: SliverGrid(
            gridDelegate: _grid(context),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _card(context, _asRelation(context, seasons[i]), i),
              childCount: seasons.length,
            ),
          ),
        ),
        if (rest.isNotEmpty) ...[
          _header(context, context.l10n.relations),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            sliver: SliverGrid(
              gridDelegate: _grid(context),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _card(context, rest[i], seasons.length + i),
                childCount: rest.length,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Text(
        text.toUpperCase(),
        style: AppText.caption.copyWith(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    ),
  );

  Widget _card(BuildContext context, MediaRelation r, int i) {
    {
      final visual = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: posterLayout(context) == PosterCardLayout.wide
                  ? 16 / 9
                  : 2 / 3,
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
      return _PressableCard(onTap: () => onOpen(r), child: visual);
    }
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
    this.isMovie = false,
    this.embedded = false,
  });

  /// Sits inside the Overview page's own scroll view instead of scrolling itself.
  final bool embedded;

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
  final bool isMovie;

  @override
  Widget build(BuildContext context) {
    final desc = description ?? '';
    if (embedded) {
      final tags = _tagChips(context);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Column(
                  children: [
                    if (sourceName.isNotEmpty)
                      _DetailRow(
                        label: context.l10n.playerInfoSource,
                        value: sourceName,
                      ),
                    if (statusStr.isNotEmpty)
                      _DetailRow(label: context.l10n.status, value: statusStr),
                    if ((year ?? '').isNotEmpty)
                      _DetailRow(label: context.l10n.year, value: year!),
                    if (!isMovie)
                      _DetailRow(
                        label: reading
                            ? context.l10n.chapters
                            : context.l10n.episodes,
                        value: '$episodeCount',
                      ),
                    if (studios.isNotEmpty)
                      _DetailRow(
                        label: context.l10n.studio,
                        value: studios.join(', '),
                      ),
                    ..._providerRows(context),
                  ],
                ),
              ),
            ),
            if (tags.isNotEmpty) ...[const SizedBox(height: 14), ...tags],
          ],
        ),
      );
    }
    return ListView(
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        16,
        embedded ? 8 : 20,
        16,
        embedded ? 24 : 40,
      ),
      children: [
        if (sourceName.isNotEmpty)
          _DetailRow(label: context.l10n.playerInfoSource, value: sourceName),
        if (statusStr.isNotEmpty)
          _DetailRow(label: context.l10n.status, value: statusStr),
        if ((year ?? '').isNotEmpty)
          _DetailRow(label: context.l10n.year, value: year!),
        if (!isMovie)
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
        if (desc.isNotEmpty && !embedded) ...[
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
      if (d.favourites != null)
        _DetailRow(label: l10n.favourites, value: _thousands(d.favourites!)),
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
    final cell = posterGridCellWidth(context);
    final wide = posterLayout(context) == PosterCardLayout.wide;
    return _Shimmer(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: posterGridColumns(context),
          childAspectRatio: wide ? 0.95 : 0.47,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        // Enough to fill the fold and no more — rows nobody can see still
        // cost a frame to lay out.
        itemCount: 9,
        itemBuilder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bone(cell, cell * (wide ? 9 / 16 : 1.5), 12),
            const SizedBox(height: 8),
            _bone(cell * 0.75, 11),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Overview tab — Cast, Seasons/Relations and Details as one scrolling page of
// rows, in place of the separate Cast / Relations / Details tabs.
// ─────────────────────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.cast,
    required this.relations,
    required this.seasons,
    required this.onOpenRelation,
    required this.onOpenPerson,
    required this.details,
    required this.castLabel,
    required this.synopsis,
    required this.genres,
    this.onGenre,
    this.year,
    this.runtimeMins,
    this.badges,
    this.score,
    this.loading = false,
  });

  /// The facts for the top row: release year, run time, and — when found — the
  /// age tag and IMDb score. [score] (out of 100, from the anime trackers) stands
  /// in when there is no IMDb score.
  final String? year;
  final int? runtimeMins;
  final TitleBadges? badges;
  final int? score;

  final List<String> genres;

  /// Null leaves the genre chips as plain information.
  final void Function(String)? onGenre;

  final String synopsis;
  final List<CastMember> cast;
  final List<MediaRelation> relations;
  final List<SeasonEntry> seasons;
  final void Function(MediaRelation) onOpenRelation;
  final void Function(PersonRef) onOpenPerson;
  final Widget details;
  final String castLabel;

  /// Cast and relations arrive on their own request after the detail does.
  final bool loading;

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 26, 16, 12),
    child: Text(
      text.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  /// Avatar size by screen width, the way a phone and a tablet each want it.
  static double _avatarFor(double width) => width >= 600
      ? 100
      : width >= 420
      ? 88
      : 80;

  /// "AB" for "Ada Byron", "Ma" for "Madonna" — what shows when there is no photo.
  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final list = parts.toList();
    if (list.isEmpty) return '';
    if (list.length == 1) {
      final w = list.first;
      return w.length <= 2 ? w.toUpperCase() : w.substring(0, 2);
    }
    return '${list.first[0]}${list.last[0]}'.toUpperCase();
  }

  Widget _castCard(CastMember m, double avatar) {
    final card = SizedBox(
      width: avatar + 12,
      child: Column(
        children: [
          Container(
            width: avatar,
            height: avatar,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface2,
              border: Border.all(color: AppColors.hairline),
            ),
            child: ClipOval(
              child: (m.photo != null && m.photo!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: m.photo!,
                      fit: BoxFit.cover,
                      memCacheWidth: 240,
                      placeholder: (_, _) =>
                          Container(color: AppColors.surface2),
                      errorWidget: (_, _, _) =>
                          _InitialsAvatar(_initials(m.name)),
                    )
                  : _InitialsAvatar(_initials(m.name)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            m.name,
            maxLines: 1,
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
      ),
    );
    final ref = m.person;
    return ref == null
        ? card
        : _PressableCard(onTap: () => onOpenPerson(ref), child: card);
  }

  Widget _row(double height, int count, Widget Function(int) item) => SizedBox(
    height: height,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (_, i) => item(i),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // A season is a relation card with its own title, same as the Relations tab.
    final rel = _RelationsTab(
      relations: relations,
      seasons: seasons,
      onOpen: onOpenRelation,
    );
    final seasonCards = [
      for (final s in seasons) _RelationsTab._asRelation(context, s),
    ];
    final rest = rel._rest;
    // On a manga the cast holds characters AND the people who made it; keep
    // them as two labelled rows, same split the old Cast tab made.
    final staff = [
      for (final m in cast)
        if (m.person?.source == PersonSource.anilistStaff) m,
    ];
    final people = staff.isEmpty || staff.length == cast.length
        ? cast
        : [
            for (final m in cast)
              if (!staff.contains(m)) m,
          ];
    final crew = staff.isEmpty || staff.length == cast.length
        ? const <CastMember>[]
        : staff;
    final avatar = _avatarFor(MediaQuery.sizeOf(context).width);
    final castRowHeight = avatar + 62;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OverviewMeta(
            year: year,
            runtime: formatRuntime(runtimeMins),
            ageRating: badges?.ageRating,
            imdbRating: badges?.imdbRating,
            score: score,
            animate: loading,
          ),
          if (synopsis.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: _OverviewSynopsis(text: synopsis),
            ),
          if (genres.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final g in genres)
                    _FilterChip(
                      text: g,
                      onTap: onGenre == null ? null : () => onGenre!(g),
                    ),
                ],
              ),
            ),
          if (people.isNotEmpty)
            _Reveal(
              key: const ValueKey('ov-cast'),
              animate: loading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, castLabel),
                  _row(
                    castRowHeight,
                    people.length,
                    (i) => _castCard(people[i], avatar),
                  ),
                ],
              ),
            )
          else if (loading && relations.isEmpty && seasons.isEmpty)
            // Nothing has arrived yet: one centred loader, not ghost rows.
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: _AppSpinner()),
            ),
          if (crew.isNotEmpty)
            _Reveal(
              key: const ValueKey('ov-crew'),
              animate: loading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, context.l10n.creators),
                  _row(
                    castRowHeight,
                    crew.length,
                    (i) => _castCard(crew[i], avatar),
                  ),
                ],
              ),
            ),
          if (seasonCards.isNotEmpty)
            _Reveal(
              key: const ValueKey('ov-seasons'),
              animate: loading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, context.l10n.seasons),
                  _row(
                    236,
                    seasonCards.length,
                    (i) => SizedBox(
                      width: 112,
                      child: rel._card(context, seasonCards[i], i),
                    ),
                  ),
                ],
              ),
            ),
          if (rest.isNotEmpty)
            _Reveal(
              key: const ValueKey('ov-relations'),
              animate: loading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, context.l10n.relations),
                  _row(
                    236,
                    rest.length,
                    (i) => SizedBox(
                      width: 112,
                      child: rel._card(
                        context,
                        rest[i],
                        seasonCards.length + i,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _header(context, context.l10n.details),
          details,
        ],
      ),
    );
  }
}

/// The synopsis at the top of Overview: three lines, "Read more" opens it in place.
class _OverviewSynopsis extends StatefulWidget {
  const _OverviewSynopsis({required this.text});
  final String text;

  @override
  State<_OverviewSynopsis> createState() => _OverviewSynopsisState();
}

class _OverviewSynopsisState extends State<_OverviewSynopsis> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _open = !_open),
    behavior: HitTestBehavior.opaque,
    child: AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            style: AppText.body,
            maxLines: _open ? null : 4,
            overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            _open ? context.l10n.watchSeeLess : context.l10n.readMore,
            style: AppText.caption.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Fades its child in the first time it appears (350ms, long soft ease) so a
/// section that arrives after the page opened eases in instead of popping.
class _Reveal extends StatelessWidget {
  const _Reveal({super.key, required this.child, required this.animate});
  final Widget child;

  /// False when the page is coming back with everything already loaded — it
  /// should simply be there, not fade in a second time.
  final bool animate;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: animate ? 0 : 1, end: 1),
    duration: const Duration(milliseconds: 350),
    curve: const Cubic(0.5, 0, 0.14, 1),
    builder: (context, v, child) => Opacity(opacity: v, child: child),
    child: child,
  );
}

/// The letters in a coloured circle, for a cast member with no photo.
class _InitialsAvatar extends StatelessWidget {
  const _InitialsAvatar(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: AppColors.surface2,
    alignment: Alignment.center,
    child: Text(
      text,
      style: AppText.headline.copyWith(
        color: AppColors.textSecondary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// The app's own loader: a circle in the accent colour.
///
/// It stays invisible for the first moments and only fades in if the wait is
/// real — a title that loads straight away never flashes a spinner.
class _AppSpinner extends StatefulWidget {
  const _AppSpinner();

  @override
  State<_AppSpinner> createState() => _AppSpinnerState();
}

class _AppSpinnerState extends State<_AppSpinner> {
  /// How long a load may take before it is worth showing anything.
  static const _grace = Duration(milliseconds: 400);

  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_grace, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _show ? 1 : 0,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    child: SizedBox(
      width: 40,
      height: 40,
      child: CircularProgressIndicator(
        strokeWidth: 3.2,
        color: AppColors.accent,
      ),
    ),
  );
}


/// The top row of Overview: year, run time, the age tag, and a score — the IMDb
/// one when it was found, otherwise the tracker score. Shows only what exists,
/// and is not drawn at all when there is nothing.
class _OverviewMeta extends StatelessWidget {
  const _OverviewMeta({
    required this.year,
    required this.runtime,
    required this.ageRating,
    required this.imdbRating,
    required this.score,
    required this.animate,
  });

  final String? year;
  final String? runtime;
  final String? ageRating;
  final String? imdbRating;

  /// Out of 100.
  final int? score;

  /// The age tag and IMDb score arrive after the page opens; they fade in then,
  /// but not on a page that comes back with them already there.
  final bool animate;

  /// The yellow people know IMDb by, kept for the score and its label only.
  static const Color _imdb = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final strong = AppText.headline.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w700,
    );
    final items = <Widget>[
      if ((year ?? '').isNotEmpty) Text(year!, style: strong),
      if (runtime != null) Text(runtime!, style: strong),
      if (ageRating != null)
        _Reveal(
          key: const ValueKey('ov-age'),
          animate: animate,
          child: _MetaBadge(ageRating!),
        ),
      if (imdbRating != null)
        _Reveal(
          key: const ValueKey('ov-imdb'),
          animate: animate,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'IMDb',
                style: AppText.caption.copyWith(
                  color: _imdb,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 5),
              Text(imdbRating!, style: strong.copyWith(color: _imdb)),
            ],
          ),
        )
      else if (score != null && score! > 0)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, size: 17, color: AppColors.accent),
            const SizedBox(width: 3),
            Text((score! / 10).toStringAsFixed(1), style: strong),
          ],
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: Alignment.topLeft,
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: items,
        ),
      ),
    );
  }
}
