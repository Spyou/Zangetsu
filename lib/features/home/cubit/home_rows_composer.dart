/// Pure functions that turn a provider's sections + a saved arrangement into
/// the ordered row list the home screens render. No I/O, no DI — every rule
/// here is unit-testable and shared by phone, TV and the editor.
library;

import '../../../core/models/home_row.dart';
import '../../../core/models/home_section.dart';
import '../../../core/zmode/zmode_ids.dart';

/// One parsed entry of a saved layout: a row id plus whether the user hid it.
///
/// Saved entries are plain strings; a hidden row is stored with a leading `!`
/// (`'!tracker:watching'`). The mark lives only in storage — ids themselves
/// never carry it.
class HomeRowEntry {
  const HomeRowEntry(this.id, this.hidden);

  final String id;
  final bool hidden;

  @override
  bool operator ==(Object other) =>
      other is HomeRowEntry && other.id == id && other.hidden == hidden;
  @override
  int get hashCode => Object.hash(id, hidden);
  @override
  String toString() => '${hidden ? '!' : ''}$id';
}

/// Decode one stored layout string.
HomeRowEntry parseRowEntry(String stored) => stored.startsWith('!')
    ? HomeRowEntry(stored.substring(1), true)
    : HomeRowEntry(stored, false);

/// Encode one entry back to its stored form.
String encodeRowEntry(HomeRowEntry e) => e.hidden ? '!${e.id}' : e.id;

/// The storage key for the arrangement of one way Home can be composed.
///
/// Z Mode layouts are keyed by provider + browse kind (`'anilist::anime'`,
/// `'mal::manga'`, `'simkl::movie'`), because that pair decides which rows can
/// exist at all. Everything else is keyed by source id — the provider decides
/// its own sections, so one source is one layout.
///
/// [browseKind] comes from `browseKindFor`; null (or [zModeOn] false) means a
/// source-backed home. The provider prefs decide anilist-vs-mal and
/// tmdb-vs-simkl; a provider *fallback* (outage) answers with the other
/// catalogue's rows, whose titles won't match the saved section ids — they
/// sanitize to a fresh default for that one load, never corrupting the saved
/// arrangement.
String layoutKeyFor({
  required String sourceId,
  required bool zModeOn,
  ZKind? browseKind,
  bool malPreferred = false,
  bool simklPreferred = false,
}) {
  if (!zModeOn || browseKind == null) return 'source:$sourceId';
  final isVideo = browseKind == ZKind.movie || browseKind == ZKind.tv;
  final provider = isVideo
      ? (simklPreferred ? 'simkl' : 'tmdb')
      : (malPreferred ? 'mal' : 'anilist');
  return '$provider::${browseKind.name}';
}

/// Whether the streaming-services rail belongs on this layout.
///
/// TMDB only. `with_watch_providers` is a TMDB discover parameter, and the
/// rail's rows page through the ACTIVE video catalogue — so on a Simkl layout
/// the rail appeared but every logo opened an empty grid. Gating on the kind
/// alone was not enough: TMDB and Simkl share [ZKind.movie], and only the
/// layout key tells them apart.
bool streamingRailForLayout(String layoutKey) => layoutKey.startsWith('tmdb::');

/// Whether a Z Mode layout can have tracker rows. Reading works on AniList
/// and MAL; anime additionally so; movies/series only Simkl. TMDB never does
/// (there is no TMDB account in the app to read a library from), and a
/// source-backed home has no tracker rows either.
bool trackerRowsForKind(ZKind? browseKind) => browseKind != null;

/// The sections that render as rows below the hero — today's rule, moved
/// verbatim from the phone home screen.
///
/// The phone drops the first section unless the provider repeats it as a row
/// (Aniyomi/Mihon always show Popular, Z Mode always keeps Trending below the
/// banner); a single-section source keeps its only section so there's still
/// something to browse. TV never drops: every section is a rail.
List<HomeSection> providerRowSections(
  List<HomeSection> sections, {
  required bool isTv,
}) {
  if (isTv || sections.length <= 1) return sections;
  final firstId = sections.first.more?.sourceId ?? '';
  final firstRepeatsAsRow =
      firstId.startsWith('ani:') ||
      firstId.startsWith('mihon:') ||
      firstId == ZmodeIds.sourceId;
  return firstRepeatsAsRow ? sections : sections.sublist(1);
}

/// Every row id that can appear in this layout, in default order: the local
/// row first, the tracker rows (when the layout can have them), then the
/// provider's sections. This is the sanitize universe — ids outside it are
/// dropped from a saved layout.
List<String> availableRowIds(
  List<HomeSection> rowSections, {
  required bool withTrackerRows,
  ZKind? kind,
  bool withStreamingRail = false,
}) => [
  localContinueRowId,
  if (withStreamingRail) streamingServicesRowId,
  if (withTrackerRows) ...trackerRowIdsFor(kind),
  for (final s in rowSections) 'section:${s.title}',
];

/// The shipped arrangement for a layout: local row on, tracker rows present
/// but hidden, provider sections on in catalogue order. Tracker rows sit
/// above the sections so a newly-enabled one lands with "your lists", not
/// below the discover rows.
List<String> defaultLayout(
  List<String> sectionIds, {
  required bool withTrackerRows,
  ZKind? kind,
  bool withStreamingRail = false,
}) => [
  localContinueRowId,
  // Shipped ON: it is the point of the feature, and it self-hides when the
  // region lists no services.
  if (withStreamingRail) streamingServicesRowId,
  if (withTrackerRows)
    for (final id in trackerRowIdsFor(kind)) '!$id',
  ...sectionIds,
];

/// A saved layout can be wrong in every way storage gets old: name rows the
/// catalogue no longer returns, hold duplicates, or miss rows added since it
/// was saved. This resolves all of it to an arrangement that always works:
///
/// * unknown ids are dropped (renamed/removed catalogue rows),
/// * duplicates collapse to the first occurrence,
/// * missing ids re-enter at their DEFAULT visibility — a structural row in
///   the slot [available] gives it relative to the rows already there, new
///   sections at the end — so an upgrade adds rows without ever reshuffling
///   the ones the user arranged.
///
/// Structural rows used to re-enter at the very top. That was invisible while
/// every late-added one was hidden by default (the tracker rows), but a
/// VISIBLE new row landed above the row the user thinks of as first. Slotting
/// it after its predecessor puts it where [defaultLayout] says it belongs.
List<HomeRowEntry> sanitizeLayout(List<String> stored, List<String> available) {
  bool defaultHidden(String id) => isTrackerRowId(id);
  final seen = <String>{};
  final out = <HomeRowEntry>[];
  for (final raw in stored) {
    final e = parseRowEntry(raw);
    if (!available.contains(e.id) || !seen.add(e.id)) continue;
    out.add(e);
  }
  final missing = available.where((id) => !seen.contains(id)).toList();
  // Structural rows first, in `available` order, each slotted after the last
  // row already present that precedes it there. Nothing to anchor to (an empty
  // or all-sections layout) means the top, which is the old behaviour.
  for (final id in missing.where((id) => !id.startsWith('section:'))) {
    final precede = available.take(available.indexOf(id)).toSet();
    var at = 0;
    for (var i = out.length - 1; i >= 0; i--) {
      if (precede.contains(out[i].id)) {
        at = i + 1;
        break;
      }
    }
    out.insert(at, HomeRowEntry(id, defaultHidden(id)));
  }
  // New sections re-enter at the end, visible.
  for (final id in missing.where((id) => id.startsWith('section:'))) {
    out.add(HomeRowEntry(id, defaultHidden(id)));
  }
  return out;
}

/// Emit the rows a screen renders: the layout's visible entries, in order.
///
/// [trackerRows] arrive already built and already filtered to non-empty — an
/// empty tracker row (nothing watching, tracker offline) is dropped silently,
/// which also keeps the default home free of them. Provider sections are
/// looked up by title; one that vanished between sanitize and merge is
/// skipped the same way.
List<HomeRow> mergeHomeRows({
  required List<HomeRowEntry> layout,
  required List<HomeSection> rowSections,
  required List<HomeRow> trackerRows,
}) {
  final sectionsById = {for (final s in rowSections) 'section:${s.title}': s};
  final trackersById = {for (final r in trackerRows) r.id: r};
  final out = <HomeRow>[];
  for (final e in layout) {
    if (e.hidden) continue;
    if (e.id == localContinueRowId) {
      out.add(const LocalContinueHomeRow());
    } else if (e.id == streamingServicesRowId) {
      out.add(const StreamingServicesHomeRow());
    } else if (isTrackerRowId(e.id)) {
      final r = trackersById[e.id];
      if (r != null) out.add(r); // empty/offline → dropped silently
    } else {
      final s = sectionsById[e.id];
      if (s != null) out.add(ProviderHomeRow(s));
    }
  }
  return out;
}
