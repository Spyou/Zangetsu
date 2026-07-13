import 'package:flutter/material.dart';

import '../aniyomi/aniyomi_provider.dart';
import '../di/injector.dart';
import '../models/provider_info.dart';
import '../playback/playback_prefs.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Installed-and-enabled sources bucketed by category, each as an `(id, label)`
/// row. Reused by the source switcher and the search source picker.
typedef SourceBuckets = ({
  List<({String id, String label, String? repo})> anime,
  List<({String id, String label, String? repo})> movies,
  List<({String id, String label, String? repo})> nsfw,
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
  for (final e in (enabled..sort(byLabel))) {
    if (nsfwIds.contains(e.name)) {
      if (nsfwEnabled) nsfw.add(row(e));
      continue; // NSFW sources live only in their own group
    }
    if (reg.typeOf(e.name) == 'anime') {
      anime.add(row(e));
    } else {
      movies.add(row(e)); // movie / series / unknown
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

  anime.sort(byRowLabel);
  movies.sort(byRowLabel);

  return (anime: anime, movies: movies, nsfw: nsfw);
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
  });

  final String currentId;
  final void Function(String id) onChanged;

  /// Installed + enabled providers bucketed by category (shared helper).
  SourceBuckets _buckets() => categorizedSources();

  // Ecosystem signature colors for the chip tag (CS blue / Aniyomi purple /
  // Zangetsu coral).
  static const Color _csColor = Color(0xFF7EA2FF);
  static const Color _aniColor = Color(0xFFBB8CFF);

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
    final b = _buckets();

    // The "All" tab is the tallest; size the sheet to it (so it's compact for a
    // few sources) but cap at 85% screen — TabBarView needs a bounded height.
    final screenH = MediaQuery.of(context).size.height;
    final headers = [b.anime, b.movies, b.nsfw].where((l) => l.isNotEmpty).length;
    final total = b.anime.length + b.movies.length + b.nsfw.length;
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
    required this.onChoose,
  });

  final SourceBuckets buckets;
  final String currentId;
  final double height;
  final bool showSearch;
  final void Function(String id) onChoose;

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
        onTap: () => widget.onChoose(src.id),
      );

  Widget _empty(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, style: AppText.body, textAlign: TextAlign.center),
        ),
      );

  // A scrollable flat list for a single tab.
  Widget _flat(List<({String id, String label, String? repo})> all) {
    final rows = _filter(all);
    if (rows.isEmpty) {
      return _empty(_query.trim().isEmpty ? 'No sources here' : 'No matches');
    }
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [for (final s in rows) _rowFor(s)],
    );
  }

  // The "All" tab: each (filtered) bucket under its own header.
  Widget _grouped() {
    final b = widget.buckets;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(
            t.toUpperCase(),
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
          ),
        );
    final anime = _filter(b.anime);
    final movies = _filter(b.movies);
    final nsfw = _filter(b.nsfw);
    final children = <Widget>[];
    if (anime.isNotEmpty) {
      children.add(header('Anime'));
      children.addAll(anime.map(_rowFor));
    }
    if (movies.isNotEmpty) {
      children.add(header('Movies & Series'));
      children.addAll(movies.map(_rowFor));
    }
    if (nsfw.isNotEmpty) {
      children.add(header('NSFW'));
      children.addAll(nsfw.map(_rowFor));
    }
    if (children.isEmpty) {
      return _empty(_query.trim().isEmpty ? 'No enabled sources' : 'No matches');
    }
    return ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children);
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.buckets;
    // Tabs: All, Anime, Movies/Series, and NSFW only when there are NSFW
    // sources to show (Privacy toggle on).
    final tabs = <({String title, Widget Function() body})>[
      (title: 'All', body: _grouped),
      (title: 'Anime', body: () => _flat(b.anime)),
      (title: 'Movies/Series', body: () => _flat(b.movies)),
      if (b.nsfw.isNotEmpty) (title: 'NSFW', body: () => _flat(b.nsfw)),
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
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
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
  });

  final String label;

  /// Origin repo, shown small + dim under the name. Null/empty → not shown.
  final String? repo;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasRepo = repo != null && repo!.isNotEmpty;
    return InkWell(
      onTap: onTap,
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
            if (isActive)
              const Icon(Icons.check, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
