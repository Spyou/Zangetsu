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

  String get _label {
    if (currentId.startsWith('cs:')) {
      final cs = sl<CloudStreamManager>().get(currentId);
      final name = cs?.displayName;
      if (name != null && name.isNotEmpty) return 'CS · $name';
      return currentId;
    }
    if (currentId.startsWith('ani:')) {
      final name = sl<AniyomiManager>().get(currentId)?.displayName;
      if (name != null && name.isNotEmpty) return 'Ani · $name';
      return currentId;
    }
    final entry = sl<ProviderRegistry>().entryFor(currentId);
    if (entry != null && entry.displayName.isNotEmpty) return entry.displayName;
    return entry?.name ?? currentId;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label,
              style: AppText.body.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    final b = _buckets();

    void choose(BuildContext ctx, String id) {
      Navigator.of(ctx).pop();
      onChanged(id);
    }

    Widget rowFor(BuildContext ctx, ({String id, String label, String? repo}) src) =>
        _SourceRow(
          label: src.label,
          repo: src.repo,
          isActive: src.id == currentId,
          onTap: () => choose(ctx, src.id),
        );

    // A scrollable flat list for a single tab.
    Widget flat(BuildContext ctx, List<({String id, String label, String? repo})> rows) {
      if (rows.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No sources here', style: AppText.body),
          ),
        );
      }
      return ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [for (final s in rows) rowFor(ctx, s)],
      );
    }

    // The "All" tab: each bucket under its own header.
    Widget grouped(BuildContext ctx) {
      Widget header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(
          t.toUpperCase(),
          style: AppText.overline.copyWith(color: AppColors.textTertiary),
        ),
      );
      final children = <Widget>[];
      if (b.anime.isNotEmpty) {
        children.add(header('Anime'));
        children.addAll(b.anime.map((s) => rowFor(ctx, s)));
      }
      if (b.movies.isNotEmpty) {
        children.add(header('Movies & Series'));
        children.addAll(b.movies.map((s) => rowFor(ctx, s)));
      }
      if (b.nsfw.isNotEmpty) {
        children.add(header('NSFW'));
        children.addAll(b.nsfw.map((s) => rowFor(ctx, s)));
      }
      if (children.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No enabled sources', style: AppText.body),
          ),
        );
      }
      return ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children);
    }

    // Tabs: All, Anime, Movies/Series, and NSFW only when there are NSFW
    // sources to show (Privacy toggle on).
    final tabs = <({String title, Widget Function(BuildContext) body})>[
      (title: 'All', body: grouped),
      (title: 'Anime', body: (ctx) => flat(ctx, b.anime)),
      (title: 'Movies/Series', body: (ctx) => flat(ctx, b.movies)),
      if (b.nsfw.isNotEmpty) (title: 'NSFW', body: (ctx) => flat(ctx, b.nsfw)),
    ];

    // The "All" tab is the tallest; size the sheet to it (so it's compact for a
    // few sources) but cap at 85% screen — TabBarView needs a bounded height.
    final screenH = MediaQuery.of(context).size.height;
    final headers = [b.anime, b.movies, b.nsfw].where((l) => l.isNotEmpty).length;
    final allRows = b.anime.length + b.movies.length + b.nsfw.length + headers;
    final sheetH = (24 + 48 + allRows * 52 + 24).clamp(240.0, screenH * 0.85);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: sheetH.toDouble(),
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
                    child: TabBarView(
                      children: [for (final t in tabs) t.body(ctx)],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
