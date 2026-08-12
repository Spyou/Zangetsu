import 'package:flutter/material.dart';

import '../aniyomi/aniyomi_provider.dart';
import '../di/injector.dart';
import '../i18n/source_languages.dart';
import '../lnreader/lnreader_manager.dart';
import '../mihon/mihon_manager.dart';
import '../prefs/source_lang_prefs.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../playback/pinned_sources.dart';
import '../models/provider_info.dart';
import '../playback/playback_prefs.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'states.dart';

/// Installed-and-enabled sources bucketed by category, each as an `(id, label)`
/// row. Reused by the source switcher and the search source picker.
///
/// [manga]/[novel] are additive: a reading-typed JS source ALSO still lands in
/// [movies] exactly as it always has (that classification is untouched), so
/// [TvSourcePicker] — which reads only anime/movies/nsfw and has no mode
/// filter — renders exactly as it did before these two fields existed.
typedef SourceBuckets = ({
  List<({String id, String label, String? repo})> anime,
  List<({String id, String label, String? repo})> movies,
  List<({String id, String label, String? repo})> nsfw,
  List<({String id, String label, String? repo})> manga,
  List<({String id, String label, String? repo})> novel,
});

/// Short repo identifier from a manifest URL (the GitHub repo name, else the
/// owner, else the host) — shown after a source so you can tell which repo it
/// came from. Null for bundled/blank URLs → nothing is shown.
String? _repoLabelFromUrl(String? repoUrl) {
  if (repoUrl == null || repoUrl.isEmpty || repoUrl.startsWith('bundled://')) {
    return null;
  }
  try {
    final u = Uri.parse(repoUrl);
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (u.host.contains('github')) {
      if (segs.length >= 2) return segs[1]; // owner / REPO
      if (segs.isNotEmpty) return segs.first;
    }
    return u.host.isEmpty ? null : u.host;
  } catch (_) {
    return null;
  }
}

/// Buckets installed + enabled providers (JS + CloudStream) by manifest type.
/// NSFW sources are kept separate and only surfaced when the Privacy toggle is
/// on. CS rows are prefixed "CS · " and interleaved alphabetically. Each row's
/// label carries a small trailing " · repo" tag so the origin repo is visible.
SourceBuckets categorizedSources() {
  final reg = sl<ProviderRegistry>();
  final nsfwEnabled = sl<PlaybackPrefs>().nsfwSources;
  final nsfwIds = reg.nsfwSourceIds();
  // Resolved once for the whole bucketing pass — see [_typeOfFromMap]. This
  // used to be reg.typeOf(e.name) AND sourceTypeOf(e.name) called per row
  // below (two repo-manifest deserializes per row instead of one total).
  final typeMap = reg.typeMapOf();
  ({String id, String label, String? repo}) row(e) {
    final base = (e.displayName as String).isNotEmpty
        ? e.displayName as String
        : e.name as String;
    final repo = _repoLabelFromUrl(e.originRepoUrl as String?);
    return (id: e.name as String, label: base, repo: repo);
  }
  int byLabel(a, b) =>
      row(a).label.toLowerCase().compareTo(row(b).label.toLowerCase());

  final enabled = reg.getAll().where((e) => e.enabled).toList();
  final anime = <({String id, String label, String? repo})>[];
  final movies = <({String id, String label, String? repo})>[];
  final nsfw = <({String id, String label, String? repo})>[];
  final manga = <({String id, String label, String? repo})>[];
  final novel = <({String id, String label, String? repo})>[];
  for (final e in (enabled..sort(byLabel))) {
    if (nsfwIds.contains(e.name)) {
      if (nsfwEnabled) nsfw.add(row(e));
      continue; // NSFW sources live only in their own group
    }
    if (typeMap[e.name] == 'anime') {
      anime.add(row(e));
    } else {
      movies.add(row(e)); // movie / series / unknown
    }
    // Additive only — the anime/movies routing above is UNCHANGED, so a
    // manga/novel source still lands in `movies` too (TvSourcePicker keeps
    // seeing exactly what it saw before). This is just the one extra place a
    // reading-mode picker can actually find it. Same resolution sourceTypeOf
    // does (the app's one ProviderType resolver), just against the map
    // already built above instead of re-deriving the type per row.
    switch (_typeOfFromMap(e.name, typeMap)) {
      case ProviderType.manga:
        manga.add(row(e));
      case ProviderType.novel:
        novel.add(row(e));
      case ProviderType.anime:
      case ProviderType.movie:
        break;
    }
  }

  // Loaded CloudStream plugins. No NSFW flag, so they only ever land in the
  // anime or movies buckets. Sort each combined bucket by label so CS rows
  // interleave alphabetically with the JS rows rather than trailing them.
  int byRowLabel(({String id, String label, String? repo}) a, ({String id, String label, String? repo}) b) =>
      a.label.toLowerCase().compareTo(b.label.toLowerCase());
  final mgr = sl<CloudStreamManager>();
  // Map each CS source to its origin repo's name, for the repo tag.
  // Best-effort: a repo tag must NEVER stop the picker from opening.
  final csRepoById = <String, String>{};
  try {
    for (final g in mgr.repoGroups) {
      if (g.name.isEmpty) continue;
      for (final s in g.sources) {
        csRepoById[s.sourceId] = g.name;
      }
    }
  } catch (_) {/* tags are cosmetic */}
  for (final p in mgr.enabled) {
    final repo = csRepoById[p.sourceId];
    final csRow = (
      id: p.sourceId,
      label: 'CS · ${p.displayName}',
      repo: repo,
    );
    if (p.providerType == ProviderType.anime) {
      anime.add(csRow);
    } else {
      movies.add(csRow);
    }
  }
  // Aniyomi providers — always anime; keyed by their `ani:` sourceId.
  // NSFW-flagged sources are hidden when the pref is off.
  final showNsfwAni = sl<PlaybackPrefs>().showNsfwAniyomi;
  for (final p in sl<AniyomiManager>().all) {
    if (!aniyomiNsfwVisible(p, showNsfwAniyomi: showNsfwAni)) continue;
    anime.add((id: p.sourceId, label: 'Ani · ${p.displayName}', repo: 'Aniyomi'));
  }
  // Mihon providers — always manga; keyed by their `mihon:` sourceId. Only the
  // manga bucket, never anime/movies/nsfw, so TvSourcePicker (which reads
  // anime/movies/nsfw and has no mode filter) renders exactly as before.
  //
  // isRegistered-guarded because MihonManager is a newer singleton than this
  // function's other dependencies: plenty of existing tests build a GetIt with
  // ProviderRegistry + PlaybackPrefs + CloudStreamManager + AniyomiManager and
  // nothing else, and an unguarded lookup would turn every one of them into a
  // GetIt "not registered" crash. NSFW reuses the general `nsfwSources` toggle
  // (there is no Mihon-specific pref), matching SourceRepository.loadedSources.
  if (sl.isRegistered<MihonManager>()) {
    // Only surface sources in the user's enabled languages. A multi-language
    // extension (MangaDex, MANGA Plus) is a SourceFactory that yields one source
    // PER LANGUAGE, so without this the picker floods with dozens of identical
    // rows. Mirrors the Mihon sources screen's Languages filter + default
    // (English + device language).
    final langs = sl.isRegistered<MangaLangPrefs>()
        ? (sl<MangaLangPrefs>().enabled ?? defaultSourceLangs())
        : null;
    for (final p in sl<MihonManager>().all) {
      if (p.info.nsfw && !nsfwEnabled) continue;
      final lang = p.info.lang;
      if (langs != null && !sourceLangVisible(lang, langs)) continue;
      // Carry the language code in the subtitle so the ones that DO show (e.g.
      // the enabled languages of a multi-language extension) stay
      // distinguishable; it feeds the picker's search too.
      manga.add((
        id: p.sourceId,
        label: 'Mihon · ${p.displayName}',
        repo: lang.isNotEmpty ? 'Mihon · $lang' : 'Mihon',
      ));
    }
  }
  // LNReader providers — always novel; keyed by their `lnr:` sourceId. Only
  // the novel bucket, same isRegistered guard and rationale as the Mihon
  // block above (LnReaderManager is registered even later than MihonManager,
  // so plenty of existing tests still build a GetIt without it).
  // `installedSources` is SYNC and reads stored meta only — no runtime build.
  if (sl.isRegistered<LnReaderManager>()) {
    for (final p in sl<LnReaderManager>().installedSources) {
      novel.add((id: p.id, label: 'LNReader · ${p.name}', repo: 'LNReader'));
    }
  }

  anime.sort(byRowLabel);
  movies.sort(byRowLabel);
  manga.sort(byRowLabel);
  novel.sort(byRowLabel);

  return (anime: anime, movies: movies, nsfw: nsfw, manga: manga, novel: novel);
}

/// Best-effort [ProviderType] for a source [id] — used to filter the picker
/// and search by content mode. Mirrors [categorizedSources]' own anime/movie
/// bucketing default, so an id with no cached manifest type still counts as
/// anime (matching today's behavior when a mode filter isn't applied).
ProviderType sourceTypeOf(String id) {
  if (id.startsWith('cs:')) {
    final p = sl<CloudStreamManager>().get(id);
    return p is CloudStreamProvider ? p.providerType : ProviderType.anime;
  }
  // LNReader novel extensions. Same reasoning as the Mihon line right below:
  // a dedicated `lnr:` prefix, checked first, types these as novel without
  // touching the `mihon:`/`ani:` lines — no GetIt lookup needed since an
  // LNReader source is novel-only by construction.
  if (id.startsWith('lnr:')) return ProviderType.novel;
  // Mihon manga extensions. They carry their own `mihon:` prefix precisely so
  // this resolver can type them as manga WITHOUT disturbing the `ani:` line
  // below (spec Decision 1) — reusing `ani:` would have typed every manga
  // source as anime. No GetIt lookup needed: the prefix alone is authoritative,
  // since a Mihon source is manga-only by construction.
  if (id.startsWith('mihon:')) return ProviderType.manga;
  // ponytail: hardcoded to anime — wrong by construction the day manga
  // reuses the Aniyomi extension machinery (a real, planned direction; see
  // watch-app-manga-novel-support). Fix then: read the loaded extension's
  // own declared type instead of assuming video-only.
  if (id.startsWith('ani:')) return ProviderType.anime; // Aniyomi is video-only
  final t = sl<ProviderRegistry>().typeOf(id);
  if (t == null) return ProviderType.anime;
  return ProviderType.values.asNameMap()[t] ?? ProviderType.anime;
}

/// Same resolution as [sourceTypeOf], but reads a precomputed id->type map
/// (see [ProviderRegistry.typeMapOf]) instead of hitting the registry per
/// call. Used by callers that resolve many ids in one pass — the repo
/// manifests get walked once for the whole pass instead of once per id.
ProviderType _typeOfFromMap(String id, Map<String, String> typeMap) {
  if (id.startsWith('cs:')) {
    final p = sl<CloudStreamManager>().get(id);
    return p is CloudStreamProvider ? p.providerType : ProviderType.anime;
  }
  // Must stay in lockstep with [sourceTypeOf]'s branches — this twin is what
  // filterBucketsForMode uses, so without them a `lnr:`/`mihon:` row would
  // resolve to anime here and get filtered straight out of the novel/manga
  // bucket it was just put in.
  if (id.startsWith('lnr:')) return ProviderType.novel;
  if (id.startsWith('mihon:')) return ProviderType.manga;
  if (id.startsWith('ani:')) return ProviderType.anime; // Aniyomi is video-only
  final t = typeMap[id];
  if (t == null) return ProviderType.anime;
  return ProviderType.values.asNameMap()[t] ?? ProviderType.anime;
}

/// Narrows a [SourceBuckets] to the rows visible in [mode]. A no-op in anime
/// mode for today's real source sets (anime/movie are the only types in use),
/// so the picker and search show exactly what they show today.
SourceBuckets filterBucketsForMode(SourceBuckets buckets, ContentMode mode) {
  // Resolved once for the whole call, not once per row — this used to be
  // sourceTypeOf(r.id) inside the row filter below, which meant one
  // ProviderRegistry.typeOf() (and therefore one full repo-manifest
  // deserialize) per row across every bucket. That's the picker-open lag:
  // switching sources is a hot, frequent action, not a cold path.
  final typeMap = sl<ProviderRegistry>().typeMapOf();

  // A plain list filter, NOT a map-by-id round trip: the same sourceId can
  // legitimately appear twice in a bucket (installed from two different
  // repos — see ProviderRegistry's composite repoUrl+sourceId key), and a
  // map would collapse those into one row, silently dropping one from the
  // picker/search.
  List<({String id, String label, String? repo})> filter(
    List<({String id, String label, String? repo})> rows,
  ) => rows.where((r) => mode.matchesProvider(_typeOfFromMap(r.id, typeMap))).toList();

  return (
    anime: filter(buckets.anime),
    movies: filter(buckets.movies),
    nsfw: filter(buckets.nsfw),
    manga: filter(buckets.manga),
    novel: filter(buckets.novel),
  );
}

/// True if there's at least one installed+enabled source for [mode]'s own
/// reading bucket. Always false for [ContentMode.anime] (it has no reading
/// bucket of its own) — callers should already be gating on
/// [ContentModeX.isReading] before asking. The "is there anything installed
/// for this mode" check Home/Search/My List's empty states need, factored
/// out of [_SourcePickerSheetState._hasAnySources] (which needed the exact
/// same thing for the picker's pin nudge) so it's one answer, not four.
bool hasReadingSourcesFor(ContentMode mode) {
  if (!mode.isReading) return false;
  final b = categorizedSources();
  return (mode == ContentMode.manga ? b.manga : b.novel).isNotEmpty;
}

/// True if there's at least one installed source usable in [mode] — the mode's
/// own reading bucket for manga/novel, or any anime/movie source for anime.
/// Generalises [hasReadingSourcesFor] to all three modes (the app ships NO
/// built-in sources — everything comes from installed repos), so Home can show
/// a "no sources yet → install" guide for anime too, not just reading.
///
/// filterBucketsForMode drops the rows a mode can't use (the raw `movies`
/// bucket also carries manga/novel rows for the TV picker), so any non-empty
/// bucket after it is a real source for [mode].
///
/// Defensive: source enumeration touches several DI singletons, so if the graph
/// isn't fully up (early boot, minimal test harnesses) it can throw — treat that
/// as "sources exist" so a spurious "no sources" guide never flashes over a home
/// that would otherwise show content (or its own retry).
bool hasSourcesFor(ContentMode mode) {
  try {
    final b = filterBucketsForMode(categorizedSources(), mode);
    return b.anime.isNotEmpty ||
        b.movies.isNotEmpty ||
        b.nsfw.isNotEmpty ||
        b.manga.isNotEmpty ||
        b.novel.isNotEmpty;
  } catch (_) {
    return true;
  }
}

/// A compact pill button that shows the active source and opens a
/// bottom-sheet picker when tapped. The selectable list is built
/// dynamically from the installed-and-enabled providers in
/// [ProviderRegistry], so repo-installed sources become selectable here
/// as soon as they're enabled.
class SourceSwitcher extends StatelessWidget {
  const SourceSwitcher({
    super.key,
    required this.currentId,
    required this.onChanged,
    this.onInstallSources,
  });

  final String currentId;
  final void Function(String id) onChanged;

  /// Opens the install flow (Zangetsu sources → Repositories) — shown as a
  /// button on the picker's empty state when a reading mode has no sources
  /// installed yet. Null → the empty state just has no button (today's
  /// anime-mode behavior, and a safe no-op for any caller that hasn't wired
  /// this up).
  final VoidCallback? onInstallSources;

  /// Installed + enabled providers bucketed by category (shared helper).
  SourceBuckets _buckets() => categorizedSources();

  // Ecosystem signature colors for the chip tag (CS blue / Aniyomi purple /
  // Zangetsu coral).
  static const Color _csColor = Color(0xFF7EA2FF);
  static const Color _aniColor = Color(0xFFBB8CFF);
  static const Color _mihonColor = Color(0xFF6FD8A8);
  static const Color _lnrColor = Color(0xFFF6A96B); // LNReader (novel) — amber

  /// Short colored ecosystem tag + source name for the chip. The tag replaces
  /// the old "CS · " name prefix: still text (a colored dot alone was too
  /// cryptic), but tiny and tinted per ecosystem.
  (String, Color, String) get _tagAndName {
    if (currentId.startsWith('cs:')) {
      final name = sl<CloudStreamManager>().get(currentId)?.displayName;
      return (
        'CS',
        _csColor,
        (name != null && name.isNotEmpty) ? name : currentId,
      );
    }
    if (currentId.startsWith('ani:')) {
      final name = sl<AniyomiManager>().get(currentId)?.displayName;
      return (
        'ANI',
        _aniColor,
        (name != null && name.isNotEmpty) ? name : currentId,
      );
    }
    // Without this a `mihon:` active source falls through to the ZAN branch,
    // finds no ProviderRegistry entry, and the chip renders the raw id.
    if (currentId.startsWith('mihon:')) {
      final name = sl.isRegistered<MihonManager>()
          ? sl<MihonManager>().get(currentId)?.displayName
          : null;
      return (
        'MIHON',
        _mihonColor,
        (name != null && name.isNotEmpty) ? name : currentId,
      );
    }
    // Without this an `lnr:` novel source falls through to the ZAN branch,
    // which has no ProviderRegistry entry for it, so the chip showed the raw
    // id (e.g. "lnr:anf.net") instead of the plugin's name.
    if (currentId.startsWith('lnr:')) {
      final name = sl.isRegistered<LnReaderManager>()
          ? sl<LnReaderManager>().metaFor(currentId.substring(4))?.name
          : null;
      return (
        'LN',
        _lnrColor,
        (name != null && name.isNotEmpty) ? name : currentId,
      );
    }
    final entry = sl<ProviderRegistry>().entryFor(currentId);
    final name = (entry != null && entry.displayName.isNotEmpty)
        ? entry.displayName
        : (entry?.name ?? currentId);
    return ('ZAN', AppColors.accent, name);
  }

  @override
  Widget build(BuildContext context) {
    final (tag, tagColor, name) = _tagAndName;
    // Hairline micro-capsule: outline only (the hero shows through), a tiny
    // colored ecosystem tag, then the source name. Hugs the text — but capped
    // at 150px so a long name ellipsizes inside instead of growing the
    // capsule and squeezing the wordmark on the left.
    return GestureDetector(
      onTap: () => showPicker(context),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 150),
        padding: const EdgeInsets.fromLTRB(11, 4, 7, 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: tagColor,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 15,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the shared source picker (tabbed anime/movies list with CS·/Ani·
  /// labels + repo tags). Public so other screens (e.g. Settings → Active
  /// source) can present the exact same picker as the Home header.
  void showPicker(BuildContext context) {
    final mode = sl<ContentModeCubit>().state;
    final b = filterBucketsForMode(_buckets(), mode);

    // The "All" tab is the tallest; size the sheet to it (so it's compact for a
    // few sources) but cap at 85% screen — TabBarView needs a bounded height.
    // Anime mode sizes off anime/movies/nsfw exactly as before; a reading
    // mode sizes off its own single bucket instead (anime/movies/nsfw are
    // always empty there, so counting them in too would be harmless, but
    // this keeps the "what's actually shown" intent explicit).
    final screenH = MediaQuery.of(context).size.height;
    final relevant = mode.isReading
        ? [mode == ContentMode.manga ? b.manga : b.novel]
        : [b.anime, b.movies, b.nsfw];
    final headers = relevant.where((l) => l.isNotEmpty).length;
    final total = relevant.fold(0, (sum, l) => sum + l.length);
    // Search only earns its space once there's a list worth filtering.
    final showSearch = total > 6;
    final searchH = showSearch ? 56 : 0;
    final sheetH =
        (24 + 48 + searchH + (total + headers) * 52 + 24)
            .clamp(240.0, screenH * 0.85);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SourcePickerSheet(
        buckets: b,
        currentId: currentId,
        height: sheetH.toDouble(),
        showSearch: showSearch,
        mode: mode,
        onInstallSources: onInstallSources,
        onChoose: (id) {
          Navigator.of(ctx).pop();
          onChanged(id);
        },
      ),
    );
  }
}

/// True if a source [label] (or its origin [repo]) matches the search [query].
/// Case-insensitive substring; a blank query matches everything.
bool _sourcePickerMatches(String query, String label, String? repo) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (label.toLowerCase().contains(q)) return true;
  return repo != null && repo.toLowerCase().contains(q);
}

/// The source-picker bottom sheet body. Stateful so the search field can filter
/// the tab lists live. Tab set (All / Anime / Movies / NSFW) is fixed — only the
/// rows inside each tab filter, so the [DefaultTabController] length is stable.
class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({
    required this.buckets,
    required this.currentId,
    required this.height,
    required this.showSearch,
    required this.mode,
    required this.onChoose,
    this.onInstallSources,
  });

  final SourceBuckets buckets;
  final String currentId;
  final double height;
  final bool showSearch;
  final ContentMode mode;
  final void Function(String id) onChoose;
  final VoidCallback? onInstallSources;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<({String id, String label, String? repo})> _filter(
    List<({String id, String label, String? repo})> rows,
  ) =>
      [for (final s in rows) if (_sourcePickerMatches(_query, s.label, s.repo)) s];

  Widget _rowFor(({String id, String label, String? repo}) src) => _SourceRow(
        label: src.label,
        repo: src.repo,
        isActive: src.id == widget.currentId,
        isPinned: PinnedSources.isPinned(src.id),
        onTap: () => widget.onChoose(src.id),
        onLongPress: () async {
          await PinnedSources.toggle(src.id);
          if (mounted) setState(() {});
        },
      );

  Widget _empty(String message) =>
      EmptyState(icon: Icons.source_outlined, message: message);

  /// Empty state for a reading mode with literally nothing installed — the
  /// gap this task fixes. Only rendered from [_readingFlat]/[_grouped],
  /// never from the anime-mode path, so anime mode can never show a button
  /// here regardless of whether [onInstallSources] is wired.
  Widget _installCta() {
    final install = widget.onInstallSources;
    return EmptyState(
      icon: Icons.source_outlined,
      message: 'No ${widget.mode.label} sources yet',
      actionLabel: install == null ? null : 'Browse repositories',
      onAction: install == null
          ? null
          : () {
              Navigator.of(context).pop();
              install();
            },
    );
  }

  // A scrollable flat list for a single tab.
  Widget _flat(List<({String id, String label, String? repo})> all) {
    final rows = _filter(all);
    if (rows.isEmpty) {
      return _empty(_query.trim().isEmpty ? 'No sources here' : 'No matches');
    }
    // Pinned sources float to the top of the tab.
    final sorted = [
      ...rows.where((s) => PinnedSources.isPinned(s.id)),
      ...rows.where((s) => !PinnedSources.isPinned(s.id)),
    ];
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [for (final s in sorted) _rowFor(s)],
    );
  }

  // A reading mode's single-bucket tab (Manga or Novel) — same flat list as
  // [_flat], but a genuinely-empty bucket (nothing installed, not just a
  // search with no matches) gets the install CTA instead of plain text.
  Widget _readingFlat(List<({String id, String label, String? repo})> all) {
    final rows = _filter(all);
    if (rows.isEmpty) {
      if (all.isEmpty && _query.trim().isEmpty) return _installCta();
      return _empty(_query.trim().isEmpty ? 'No sources here' : 'No matches');
    }
    final sorted = [
      ...rows.where((s) => PinnedSources.isPinned(s.id)),
      ...rows.where((s) => !PinnedSources.isPinned(s.id)),
    ];
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [for (final s in sorted) _rowFor(s)],
    );
  }

  // The "All" tab: each (filtered) bucket under its own header. Anime mode
  // groups Anime/Movies & Series/NSFW exactly as before; a reading mode
  // groups its own single bucket (Manga or Novel) instead — never any of
  // anime/movies/nsfw, which are always empty there anyway.
  Widget _grouped() {
    final b = widget.buckets;
    final mode = widget.mode;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(
            t.toUpperCase(),
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
          ),
        );
    final categories = mode.isReading
        ? [(title: mode.label, rows: mode == ContentMode.manga ? b.manga : b.novel)]
        : [
            (title: 'Anime', rows: b.anime),
            (title: 'Movies & Series', rows: b.movies),
            (title: 'NSFW', rows: b.nsfw),
          ];
    // Pinned first (in pin order, from any bucket); drop them from the category
    // groups below so they aren't listed twice.
    final pinnedIds = PinnedSources.notifier.value;
    final allRows = [for (final c in categories) ...c.rows];
    final pinned = _filter([
      for (final id in pinnedIds) ...allRows.where((s) => s.id == id),
    ]);
    bool unpinned(({String id, String label, String? repo}) s) =>
        !pinnedIds.contains(s.id);
    final children = <Widget>[];
    if (pinned.isNotEmpty) {
      children.add(header('Pinned'));
      children.addAll(pinned.map(_rowFor));
    }
    for (final c in categories) {
      final rows = _filter(c.rows.where(unpinned).toList());
      if (rows.isNotEmpty) {
        children.add(header(c.title));
        children.addAll(rows.map(_rowFor));
      }
    }
    if (children.isEmpty) {
      if (mode.isReading && _query.trim().isEmpty) return _installCta();
      return _empty(_query.trim().isEmpty ? 'No enabled sources' : 'No matches');
    }
    return ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children);
  }

  /// True if there's at least one source relevant to the current mode —
  /// gates the "long-press to pin" nudge, which is nonsensical to show over
  /// a genuinely empty sheet.
  bool get _hasAnySources {
    final b = widget.buckets;
    if (widget.mode.isReading) {
      return (widget.mode == ContentMode.manga ? b.manga : b.novel).isNotEmpty;
    }
    return b.anime.isNotEmpty || b.movies.isNotEmpty || b.nsfw.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.buckets;
    final mode = widget.mode;
    // Tabs: anime mode keeps All/Anime/Movies/Series, and NSFW only when
    // there are NSFW sources to show (Privacy toggle on) — unchanged from
    // before. A reading mode shows All + its own single bucket (Manga or
    // Novel) instead; it never had an Anime/Movies/NSFW tab to show and
    // showing an empty one would be exactly the "three tabs of nothing"
    // this replaces.
    final tabs = <({String title, Widget Function() body})>[
      if (!mode.isReading) ...[
        (title: 'All', body: _grouped),
        (title: 'Anime', body: () => _flat(b.anime)),
        (title: 'Movies/Series', body: () => _flat(b.movies)),
        if (b.nsfw.isNotEmpty) (title: 'NSFW', body: () => _flat(b.nsfw)),
      ] else ...[
        (title: 'All', body: _grouped),
        (
          title: mode.label,
          body: () => _readingFlat(mode == ContentMode.manga ? b.manga : b.novel),
        ),
      ],
    ];

    return SafeArea(
      child: SizedBox(
        height: widget.height,
        child: DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (widget.showSearch)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: _PickerSearchField(
                    controller: _searchCtrl,
                    onChanged: (q) => setState(() => _query = q),
                  ),
                ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: const EdgeInsets.only(left: 16),
                labelPadding: const EdgeInsets.only(right: 24),
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.accent,
                indicatorSize: TabBarIndicatorSize.label,
                dividerColor: AppColors.hairline,
                labelStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
                tabs: [for (final t in tabs) Tab(text: t.title)],
              ),
              Expanded(
                child: TabBarView(children: [for (final t in tabs) t.body()]),
              ),
              // One-time nudge — hidden the moment the user pins anything,
              // and whenever there's nothing to pin in the first place.
              if (PinnedSources.notifier.value.isEmpty && _hasAnySources)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.push_pin_outlined,
                        size: 13,
                        color: AppColors.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Long-press a source to pin it to the top',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact search field for the picker sheet (self-contained so `core/ui` does
/// not depend on the `features/sources` search widget).
class _PickerSearchField extends StatelessWidget {
  const _PickerSearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: AppText.body,
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        hintText: 'Search sources',
        hintStyle: AppText.body.copyWith(color: AppColors.textSecondary),
        prefixIcon:
            const Icon(Icons.search, color: AppColors.textSecondary, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close,
                    color: AppColors.textSecondary, size: 18),
                tooltip: 'Clear',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        isDense: true,
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.label,
    required this.isActive,
    required this.onTap,
    this.repo,
    this.isPinned = false,
    this.onLongPress,
  });

  final String label;

  /// Origin repo, shown small + dim under the name. Null/empty → not shown.
  final String? repo;
  final bool isActive;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final hasRepo = repo != null && repo!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: AppText.headline),
                  if (hasRepo)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        repo!,
                        style: AppText.body.copyWith(
                          fontSize: 11.5,
                          height: 1.0,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isPinned)
              Padding(
                padding: EdgeInsets.only(right: isActive ? 10 : 0),
                child: Icon(
                  Icons.push_pin,
                  size: 15,
                  color: AppColors.textTertiary,
                ),
              ),
            if (isActive)
              Icon(Icons.check, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
